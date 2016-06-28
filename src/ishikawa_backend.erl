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
-export([tcbcast/1,
         tcbdeliver/2,
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

-record(state, {actor :: actor(),
                vv :: timestamp(),
                members :: [term()],
                svv :: timestamp(),
                rtm :: timestamp_matrix(),
                to_be_delivered_queue :: [{timestamp(), message()}]}).

%%%===================================================================
%%% trcb callbacks
%%%===================================================================

%% Broadcast message.
-spec tcbcast(message()) -> ok.
tcbcast(Message) ->
    gen_server:call(?MODULE, {tcbcast, Message}, infinity).

%% Deliver a message.
-spec tcbdeliver(message(), timestamp()) -> ok.
tcbdeliver(Message, Timestamp) ->
    gen_server:call(?MODULE, {tcbdeliver, Message, Timestamp}, infinity).

%% Determine if a timestamp is stable.
-spec tcbstable(timestamp()) -> {ok, boolean()}.
tcbstable(Timestamp) ->
    gen_server:call(?MODULE, {tcbstable, Timestamp}, infinity).

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
    gen_server:cast(?MODULE, {membership, Members}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    %% Seed the process at initialization.
    random:seed(erlang:phash2([node()]),
                erlang:monotonic_time(),
                erlang:unique_integer()),

    %% Generate actor identifier.
    Actor = gen_actor(),

    %% Generate local version vector.
    VClock = vclock:fresh(),

    %% Generate local version vector.
    SVV = vclock:fresh(),

    %% Generate local version vector.
    RTM = mclock:fresh(),

    %% Generate local version vector.
    ToBeDeliveredQueue = [],

    %% Add membership callback.
    ?PEER_SERVICE:add_sup_callback(fun ?MODULE:update/1),

    %% Add initial members.
    {ok, Members} = ?PEER_SERVICE:members(),
    lager:info("Initial membership: ~p", [Members]),

    {ok, #state{actor=Actor, vv=VClock, members=Members, svv=SVV, rtm=RTM, to_be_delivered_queue=ToBeDeliveredQueue}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.
handle_call({tcbcast, Message}, _From, #state{actor=Actor,
                                              vv=VClock0,
                                              members=Members} = State) ->
    %% First, increment the vector.
    VClock = vclock:increment(Actor, VClock0),

    %% Generate message.
    Message = {tcbcast, Actor, encode(Message), VClock},

    %% Transmit to membership.
    [send(Message, Peer) || Peer <- Members],

    {reply, ok, State#state{vv=VClock}};
handle_call({tcbdeliver, Message, Timestamp}, From, #state{vv=VClock0,
                                              rtm=RTM0,
                                              to_be_delivered_queue=Queue0} = State) ->
    %% Check if the message should be delivered
    {VClock, Queue} = trcb:check_causal_delivery({Message, Timestamp}, From, VClock0, Queue0),

    %% Update the Recent Timestamp Matrix
    RTM = mclock:update_rtm(RTM0, From, Timestamp),

    %% Update the Stable Version Vector
    SVV = mclock:update_stablevv(RTM),

    {reply, ok, State#state{vv=VClock, to_be_delivered_queue=Queue, svv=SVV, rtm=RTM}};
handle_call({tcbstable, _Timestamp}, _From, State) ->
    %% TODO: Implement me.
    {reply, {ok, false}, State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({membership, Members}, State) ->
    {noreply, State#state{members=Members}};
handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
gen_actor() ->
    Node = atom_to_list(node()),
    Unique = time_compat:unique_integer([positive]),
    TS = integer_to_list(Unique),
    Term = Node ++ TS,
    crypto:hash(sha, Term).

%% @private
send(Msg, Peer) ->
    PeerServiceManager = ?PEER_SERVICE:manager(),
    PeerServiceManager:forward_message(Peer, ?MODULE, Msg).

%% @private
encode(Message) ->
    term_to_binary(Message).
