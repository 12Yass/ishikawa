%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Christopher S. Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(trcb).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-include("ishikawa.hrl").

-export([causal_delivery/4, try_to_deliever/3]).

%% Broadcast message.
-callback tcbcast(message()) -> ok.

%% Deliver a message.
-callback tcbdeliver(actor(), message(), timestamp()) -> ok.

%% Determine if a timestamp is stable.
-callback tcbstable(timestamp()) -> {ok, boolean()}.

%% @doc check if a message should be deliver and deliver it, if not add it to the queue
-spec causal_delivery({actor(), message(), timestamp()}, timestamp(), [{actor(), message(), timestamp()}], fun()) -> {timestamp(), [{actor(), message(), timestamp()}]}.
causal_delivery({Origin, MessageBody, MessageVClock}, VV, Queue, Function) ->
    lager:info("Our Clock: ~p", [VV]),
    lager:info("Incoming Clock: ~p", [MessageVClock]),
    case vclock:dominates(MessageVClock, VV) of
        true ->
            %% TODO: Why is this increment operation here?
            NewVV = vclock:increment(Origin, VV),
            case Function(MessageBody) of
                {error, Reason} ->
                    lager:warning("Failed to handle message: ~p", Reason),
                    {VV, Queue ++ [{Origin, MessageBody, MessageVClock}]};
                ok ->
                    try_to_deliever(Queue, {NewVV, Queue}, Function)
            end;
        false ->
            lager:info("Message shouldn't be delivered: queueing."),
            {VV, Queue ++ [{Origin, MessageBody, MessageVClock}]}
    end.

%% @doc Check for all messages in the queue to be delivered
%% Called upon delievery of a new message that could affect the delivery of messages in the queue
-spec try_to_deliever([{actor(), message(), timestamp()}], {timestamp(), [{actor(), message(), timestamp()}]}, fun()) -> {timestamp(), [{actor(), message(), timestamp()}]}.
try_to_deliever([], {VV, Queue}, _) -> {VV, Queue};
try_to_deliever([{Origin, MessageVClock, MessageBody}=El | RQueue], {VV, Queue}=V, Function) ->
    case vclock:dominates(MessageVClock, VV) of
        true ->
            NewVV = vclock:increment(Origin, VV),
            case Function({NewVV, MessageBody}) of
                {error, Reason} ->
                    lager:warning("Failed to handle message: ~p", Reason),
                    try_to_deliever(RQueue, V, Function);
                ok ->
                    Queue1 = lists:delete(El, Queue),
                    try_to_deliever(Queue1, {NewVV, Queue1}, Function)
            end;
        false ->
            try_to_deliever(RQueue, V, Function)
    end.
