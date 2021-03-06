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

-module(ishikawa_backend).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_server).
-behaviour(trcb).

%% API
-export([start_link/0,
         update/1]).

%% trcb callbacks
-export([tcbdelivery/1,
         tcbcast/1,
         tcbstable/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("ishikawa.hrl").

-define(PEER_SERVICE, partisan_peer_service).
-define(WAIT_TIME_BEFORE_CHECK_RESEND, 5000).
-define(WAIT_TIME_BEFORE_RESEND, 10000).

-record(state, {actor :: node(),
                vv :: timestamp(),
                members :: [node()],
                svv :: timestamp(),
                rtm :: timestamp_matrix(),
                to_be_delivered_queue :: [{actor(), message(), timestamp()}],
                to_be_ack_queue :: [{timestamp(), actor(), message(), integer(), [node()]}],
                delivery_function :: fun()}).

-type state_t() :: #state{}.

%%%===================================================================
%%% trcb callbacks
%%%===================================================================

%% Configure the delivery function.
-spec tcbdelivery(function()) -> ok.
tcbdelivery(DeliveryFunction) ->
    gen_server:call(?MODULE, {tcbdelivery, DeliveryFunction}, infinity).

%% Broadcast message.
-spec tcbcast(message()) -> {ok, timestamp()}.
tcbcast(MessageBody) ->
    gen_server:call(?MODULE, {tcbcast, MessageBody}, infinity).

%% Receives a list of timestamps and returns a list of the stable ones.
-spec tcbstable([timestamp()]) -> [timestamp()].
tcbstable(Timestamps) ->
    gen_server:call(?MODULE, {tcbstable, Timestamps}, infinity).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Update membership.
-spec update(term()) -> ok.
update(State) ->
    Members = ?PEER_SERVICE:decode(State),
    lager:info("Membership changed ~p", [Members]),
    gen_server:cast(?MODULE, {membership, without_me(Members)}).

%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init(list()) -> {ok, state_t()}.
init([]) ->
    DeliveryFun = fun(Msg) ->
        lager:warning("Message delivered: ~p", [Msg]),
        ok
    end,
    init([DeliveryFun]);

init([DeliveryFun]) ->
    %% Seed the process at initialization.
    rand_compat:seed(erlang:phash2([node()]),
                     erlang:monotonic_time(),
                     erlang:unique_integer()),

    %% Generate actor identifier.
    Actor = myself(),

    %% Generate local version vector.
    VClock = vclock:fresh(),

    %% Generate local stable version vector.
    SVV = vclock:fresh(),

    %% Generate local recent timestamp matrix.
    RTM = mclock:fresh(),

    %% Generate local to be delivered messages queue.
    ToBeDeliveredQueue = [],

    %% Generate local to be acknowledged messages queue.
    ToBeAckQueue = [],

    %% Add membership callback.
    ?PEER_SERVICE:add_sup_callback(fun ?MODULE:update/1),

    %% Add initial members.
    {ok, Members} = ?PEER_SERVICE:members(),

    schedule_resend(),

    {ok, #state{actor=Actor,
                vv=VClock,
                members=without_me(Members),
                svv=SVV,
                rtm=RTM,
                to_be_delivered_queue=ToBeDeliveredQueue,
                to_be_ack_queue=ToBeAckQueue,
                delivery_function=DeliveryFun}}.

%% @private
-spec handle_call(term(), {pid(), term()}, state_t()) ->
    {reply, term(), state_t()}.

handle_call({tcbdelivery, DeliveryFunction}, _From, State) ->
    {reply, ok, State#state{delivery_function=DeliveryFunction}};

handle_call({tcbcast, MessageBody},
            _From,
            #state{actor=Actor,
                   members=Members,
                   vv=VClock0,
                   to_be_ack_queue=ToBeAckQueue0,
                   delivery_function=DeliveryFun}=State) ->
    %% Node sending the message.
    Sender = Actor,

    %% Increment vclock.
    MessageVClock = vclock:increment(Actor, VClock0),
    lager:info("Sending ~p to ~p", [MessageVClock, Members]),

    case ishikawa_config:get(deliver_locally, ?DELIVER_LOCALLY_DEFAULT) of
        true ->
            %% Deliver locally.
            DeliveryFun({MessageVClock, MessageBody});
        false ->
            ok
    end,

    %% Generate message.
    Msg = {tcbcast, Actor, MessageBody, MessageVClock, Sender},

    %% Transmit to membership.
    [send(Msg, Peer) || Peer <- Members],

    %% Get current time in milliseconds.
    CurrentTime = get_timestamp(),

    %% Add members to the queue of not ack messages and increment the vector clock.
    ToBeAckQueue = ToBeAckQueue0 ++ [{MessageVClock, Actor, MessageBody, CurrentTime, Members}],

    {reply, {ok, MessageVClock}, State#state{to_be_ack_queue=ToBeAckQueue, vv=MessageVClock}};

handle_call({tcbstable, Timestamps}, _From, #state{svv=SVV}=State) ->
    %% check if Timestamp is stable
    StableTimestamps = lists:filter(fun(T) -> vclock:descends(SVV, T) end, Timestamps),
    {reply, StableTimestamps, State}.

%% @private
-spec handle_cast(term(), state_t()) -> {noreply, state_t()}.
handle_cast({tcbcast, MessageActor, MessageBody, MessageVClock, Sender} = Msg0,
            #state{actor=Actor,
                   to_be_ack_queue=ToBeAckQueue0,
                   to_be_delivered_queue=ToBeDeliveredQueue0,
                   vv=VClock,
                   members=Members} = State) ->
    lager:info("Received message: ~p from ~p", [Msg0, Sender]),

    case already_seen_message(MessageVClock, VClock, ToBeDeliveredQueue0) of
        true ->
            %% Already seen, do nothing.
            lager:info("Ignoring duplicate message from cycle."),
            {noreply, State};
        false ->
            %% Generate list of peers that need the message.
            ToMembers = Members -- lists:flatten([Sender, MessageActor]),
            lager:info("Broadcasting message to peers: ~p", [ToMembers]),

            %% Generate message.
            Msg = {tcbcast, MessageActor, MessageBody, MessageVClock, Actor},

            %% Transmit to peers that need the message.
            [send(Msg, Peer) || Peer <- ToMembers],

            %% Get current time in milliseconds.
            CurrentTime = get_timestamp(),

            %% add message to delivery queue
            ToBeDeliveredQueue = ToBeDeliveredQueue0  ++ [{MessageActor, MessageBody, MessageVClock}],

            %% Generate message.
            MessageAck = {tcbcast_ack, MessageVClock, Actor},

            %% Send ack back to message sender.
            send(MessageAck, Sender),

            %% Attempt to deliver locally if we received it on the wire.
            gen_server:cast(?MODULE, {deliver, MessageActor, MessageBody, MessageVClock}),

            %% Add members to the queue of not ack messages and increment the vector clock.
            ToBeAckQueue = ToBeAckQueue0 ++ [{MessageVClock, MessageActor, MessageBody, CurrentTime, ToMembers}],

            {noreply, State#state{to_be_ack_queue=ToBeAckQueue, to_be_delivered_queue=ToBeDeliveredQueue}}
    end;

handle_cast({tcbcast_ack, MessageVClock, Sender},
            #state{to_be_ack_queue=ToBeAckQueue0} = State) ->
    lager:info("Received ack message: ~p from ~p", [MessageVClock, Sender]),

    %% Get list of waiting ackwnoledgements.
    {_, MessageActor, MessageBody, Timestamp, Members0} = lists:keyfind(MessageVClock,
                                             1,
                                             ToBeAckQueue0),

    %% Remove this member as an outstanding member.
    Members = lists:delete(Sender, Members0),

    ToBeAckQueue = case length(Members) of
        0 ->
            %% None left, remove from ack queue.
            lists:keydelete(MessageVClock, 1, ToBeAckQueue0);
        _ ->
            %% Still some left, preserve.
            lists:keyreplace(MessageVClock,
                             1,
                             ToBeAckQueue0, {MessageVClock, MessageActor, MessageBody, Timestamp, Members})
    end,

    {noreply, State#state{to_be_ack_queue=ToBeAckQueue}};

handle_cast({deliver, MessageActor, MessageBody, MessageVClock} = Msg,
            #state{vv=VClock0,
                   actor=Actor,
                   rtm=RTM0,
                   to_be_delivered_queue=Queue0,
                   delivery_function=DeliveryFun} = State) ->
    lager:info("Attempting to deliver message: ~p at ~p", [Msg, Actor]),

    %% Check if the message should be delivered and delivers it or not.
    {VClock, Queue} = trcb:causal_delivery({MessageActor, MessageBody, MessageVClock},
                                           VClock0,
                                           Queue0,
                                           DeliveryFun),

    lager:info("VClock before merge: ~p", [VClock0]),
    lager:info("VClock after merge: ~p", [VClock]),

    %% Update the Recent Timestamp Matrix.
    RTM = mclock:update_rtm(RTM0, MessageActor, MessageVClock),

    lager:info("RTM before: ~p", [RTM0]),
    lager:info("RTM after: ~p", [RTM]),

    %% Update the Stable Version Vector.
    SVV = mclock:update_stablevv(RTM),

    lager:info("Stable vector now: ~p", [SVV]),

    {noreply, State#state{vv=VClock, to_be_delivered_queue=Queue, svv=SVV, rtm=RTM}};

handle_cast({membership, Members}, State) ->
    {noreply, State#state{members=Members}};

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), state_t()) -> {noreply, state_t()}.
handle_info(check_resend, #state{actor=Actor, to_be_ack_queue=ToBeAckQueue0} = State) ->
    Now = get_timestamp(),
    ToBeAckQueue1 = lists:foldl(
        fun({MessageVClock, MessageActor, MessageBody, Timestamp0, MembersList}, ToBeAckQueue) ->
            case (Now - Timestamp0) > ?WAIT_TIME_BEFORE_RESEND of
                true ->
                    Message1 = {tcbcast, MessageActor, MessageBody, MessageVClock, Actor},
                    %% Retransmit to membership.
                    %% TODO: Only retransmit where it's needed.
                    [send(Message1, Peer) || Peer <- MembersList],
                    lists:keyreplace(MessageVClock,
                                     1,
                                     ToBeAckQueue,
                                     {MessageVClock, MessageActor, MessageBody, get_timestamp(), MembersList});
                false ->
                    %% Do nothing.
                    ToBeAckQueue
            end
        end,
        ToBeAckQueue0,
        ToBeAckQueue0
    ),

    schedule_resend(),

    {noreply, State#state{to_be_ack_queue=ToBeAckQueue1}};

handle_info(Msg, State) ->
    lager:warning("Unhandled info messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), state_t()) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, state_t(), term()) -> {ok, state_t()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
send(Msg, Peer) ->
    lager:info("Sending message: ~p to peer: ~p", [Msg, Peer]),
    PeerServiceManager = ?PEER_SERVICE:manager(),
    PeerServiceManager:forward_message(Peer, ?MODULE, Msg).

%% @private get current time in milliseconds
-spec get_timestamp() -> integer().
get_timestamp() ->
  {Mega, Sec, Micro} = os:timestamp(),
  (Mega*1000000 + Sec)*1000 + round(Micro/1000).

%% @private
myself() ->
    node().

%% @private
already_seen_message(MessageVC, NodeVC, ToBeDeliveredQueue) ->
    vclock:descends(NodeVC, MessageVC) orelse
    in_to_be_delivered_queue(MessageVC, ToBeDeliveredQueue).

%% @private
in_to_be_delivered_queue(MsgVC, ToBeDeliveredQueue) ->
    lists:keymember(MsgVC, 3, ToBeDeliveredQueue).

%% @private
schedule_resend() ->
    timer:send_after(?WAIT_TIME_BEFORE_CHECK_RESEND, check_resend).

%% @private
without_me(Members) ->
    Members -- [myself()].
