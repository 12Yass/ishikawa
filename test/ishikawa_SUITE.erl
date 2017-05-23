%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Christopher Meiklejohn.  All Rights Reserved.
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
%%

-module(ishikawa_SUITE).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% common_test callbacks
-export([%% suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0]).

%% tests
-compile([export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").


-include("ishikawa.hrl").

-define(CLIENT_NUMBER, 3).
-define(NODES_NUMBER, 7).
-define(MAX_MSG_NUMBER, 5).
-define(PEER_PORT, 9000).

% suite() ->
%     [{timetrap, {minutes, 2}}].

%% ===================================================================
%% common_test callbacks
%% ===================================================================

init_per_suite(_Config) ->
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(Case, _Config) ->
    ct:pal("Beginning test case ~p", [Case]),

    _Config.

end_per_testcase(Case, _Config) ->
    ct:pal("Ending test case ~p", [Case]),

    _Config.

all() ->
    [causal_delivery_test_client_server,
    causal_delivery_test_default,
    causal_delivery_test_hyparview].

%% ===================================================================
%% Tests.
%% ===================================================================

%% Not very interesting to test causal delivery with a Client/Server star topology 
causal_delivery_test_client_server(Config) ->
  %% Use the client/server peer service manager.
  Manager = partisan_client_server_peer_service_manager,

  %% Specify servers.
  Servers = node_list(1, "server"),

  %% Specify clients.
  Clients = node_list(?CLIENT_NUMBER, "client"), 
  %% Start nodes.
  Nodes = start(client_server_manager_test, Config,
                [{partisan_peer_service_manager, Manager},
                 {servers, Servers},
                 {clients, Clients}]),

  %% Pause for clustering.
  timer:sleep(1000),

  %% Verify membership.
  %%
  VerifyFun = fun({Name, Node}) ->
    {ok, Members} = rpc:call(Node, Manager, members, []),

      %% If this node is a server, it should know about all nodes.
      SortedNodes = case lists:member(Name, Servers) of
        true ->
          lists:usort([N || {_, N} <- Nodes]);
        false ->
          %% Otherwise, it should only know about the server
          %% and itself.
          lists:usort(
            lists:map(
              fun(Server) ->
                proplists:get_value(Server, Nodes)
              end,
              Servers
            ) ++ [Node]
          )
      end,

      SortedMembers = lists:usort(Members),
      case SortedMembers =:= SortedNodes of
        true ->
          ok;
        false ->
          ct:fail("Membership incorrect; node ~p should have ~p but has ~p", [Node, Nodes, Members])
      end
  end,

  %% Verify the membership is correct.
  lists:foreach(VerifyFun, Nodes),

  %% Get the first node in the list.
  [{_ServerName, ServerNode} | ClientNodes] = Nodes,

  %% Configure the delivery function on each node to send the messages
  %% back to the test runner in delivery order.
  Self = self(),

  lists:foreach(fun({_ClientName, ClientNode}) ->
    DeliveryFun = fun({_VV, Msg}) ->
      Self ! {delivery, ClientNode, Msg},
      ok
    end,
    ok = rpc:call(ClientNode, ishikawa, tcbdelivery, [DeliveryFun])
  end,
  ClientNodes),

  %% Send a series of messages.
  {ok, _} = rpc:call(ServerNode, ishikawa, tcbcast, [1]),
  
  
  %% Ensure each node receives a message.
  lists:foreach(fun({_ClientName, ClientNode}) ->
    receive
      {delivery, ClientNode, 1} ->
        ok;
      {delivery, ClientNode, Message} ->
        ct:fail("Client ~p received incorrect message: ~p", [ClientNode, Message])
    after
      1000 ->
        ct:fail("Client ~p didn't receive message!", [ClientNode])
    end
  end, ClientNodes),

  %% Stop nodes.
  stop(Nodes),

  ok.

%% Test with full membership
causal_delivery_test_default(Config) ->

  %% Use the default peer service manager.
  Manager = partisan_default_peer_service_manager,

  %% Specify clients.
  Clients = node_list(?NODES_NUMBER, "client"),

  %% Start nodes.
  Nodes = start(default_manager_test, Config,
                [{partisan_peer_service_manager, Manager},
                 {clients, Clients}]),

  %% Pause for clustering.
  timer:sleep(1000),

  %% Verify membership.
  %%
  VerifyFun = fun({_Name, Node}) ->
    {ok, Members} = rpc:call(Node, Manager, members, []),

    %% If this node is a server, it should know about all nodes.
    SortedNodes = lists:usort([N || {_, N} <- Nodes]) -- [Node],
    SortedMembers = lists:usort(Members) -- [Node],
    case SortedMembers =:= SortedNodes of
      true ->
        ok;
      false ->
        ct:fail("Membership incorrect; node ~p should have ~p but has ~p", [Node, SortedNodes, SortedMembers])
    end
  end,

  %% Verify the membership is correct.
  lists:foreach(VerifyFun, Nodes),

  %% start causal delivery test
  fun_causal_test(Nodes),

  %% Stop nodes.
  stop(Nodes),

  ok.

%% Test with hyparview overlay
causal_delivery_test_hyparview(Config) ->

  %% Use the hyparview peer service manager.
  Manager = partisan_hyparview_peer_service_manager,

  %% Specify servers.
  Servers = node_list(1, "server"),

  %% Specify clients.
  Clients = node_list(?NODES_NUMBER, "client"),

  %% Start nodes.
  Nodes = start(hyparview_manager_test, Config,
                [{partisan_peer_service_manager, Manager},
                 {servers, Servers},
                 {clients, Clients}]),

  %% Pause for clustering.
  timer:sleep(10000),

  %% Create new digraph.
  Graph = digraph:new(),

  %% Verify connectedness.
  %%
  ConnectFun = fun({_, Node}) ->
    {ok, ActiveSet} = rpc:call(Node, Manager, active, []),
    Active = sets:to_list(ActiveSet),

    %% Add vertexes and edges.
    [connect(Graph, Node, N) || {N, _, _} <- Active]
  end,

  %% Build the graph.
  lists:foreach(ConnectFun, Nodes),

  %% Verify connectedness.
  ConnectedFun = fun({_Name, Node}=Myself) ->
    lists:foreach(fun({_, N}) ->
      Path = digraph:get_short_path(Graph, Node, N),
        case Path of
          false ->
            ct:fail("Graph is not connected!");
          _ ->
            ok
        end
      end, Nodes -- [Myself])
    end,

  lists:foreach(ConnectedFun, Nodes),

  %% Verify symmetry.
  SymmetryFun = fun({_, Node1}) ->
    %% Get first nodes active set.
    {ok, ActiveSet1} = rpc:call(Node1, Manager, active, []),
    Active1 = sets:to_list(ActiveSet1),

    lists:foreach(fun({Node2, _, _}) ->
      %% Get second nodes active set.
      {ok, ActiveSet2} = rpc:call(Node2, Manager, active, []),
      Active2 = sets:to_list(ActiveSet2),

      case lists:member(Node1, [N || {N, _, _} <- Active2]) of
        true ->
          ok;
        false ->
          ct:fail("~p has ~p in it's view but ~p does not have ~p in its view",
              [Node1, Node2, Node2, Node1])
      end
    end, Active1)
  end,

  lists:foreach(SymmetryFun, Nodes),

  %% start causal delivery test
  fun_causal_test(Nodes),

  %% Stop nodes.
  stop(Nodes),

  ok.

%% ===================================================================
%% Internal functions.
%% ===================================================================

%% @private
start(_Case, _Config, Options) ->
    %% Launch distribution for the test runner.
    ct:pal("Launching Erlang distribution..."),

    os:cmd(os:find_executable("epmd") ++ " -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner@" ++ Hostname), shortnames]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end,

    %% Load sasl.
    application:load(sasl),
    ok = application:set_env(sasl,
                             sasl_error_logger,
                             false),
    application:start(sasl),

    %% Load lager.
    {ok, _} = application:ensure_all_started(lager),

    Servers = proplists:get_value(servers, Options, []),
    Clients = proplists:get_value(clients, Options, []),

    NodeNames = lists:flatten(Servers ++ Clients),
    
    %% Start all nodes.
    InitializerFun = fun(Name) ->
      ct:pal("Starting node: ~p", [Name]),

      NodeConfig = [{monitor_master, true}, {startup_functions, [{code, set_path, [codepath()]}]}],

      case ct_slave:start(Name, NodeConfig) of
          {ok, Node} ->
              {Name, Node};
          Error ->
              ct:fail(Error)
      end
     end,
    Nodes = lists:map(InitializerFun, NodeNames),

    %% Load applications on all of the nodes.
    LoaderFun = fun({_Name, Node}) ->
      ct:pal("Loading applications on node: ~p", [Node]),

      PrivDir = code:priv_dir(?APP),

      NodeDir = filename:join([PrivDir, "lager", Node]),

      %% Manually force sasl loading, and disable the logger.   
      ct:pal("P ~p N ~p", [PrivDir, NodeDir]),
  
      ok = rpc:call(Node, application, load, [sasl]),   

      ok = rpc:call(Node, application, set_env, [sasl, sasl_error_logger, false]),    

      ok = rpc:call(Node, application, start, [sasl]),    

      ok = rpc:call(Node, application, load, [partisan]),   

      ok = rpc:call(Node, application, load, [ishikawa]),    

      ok = rpc:call(Node, application, load, [lager]),   

      ok = rpc:call(Node, application, set_env, [sasl, sasl_error_logger, false]),

      ok = rpc:call(Node, application, set_env, [lager, log_root, NodeDir]),

      ok = rpc:call(Node, ishikawa_config, set, [deliver_locally, true])
   end,
  
  lists:map(LoaderFun, Nodes),

    %% Configure settings.
    ConfigureFun = fun({Name, Node}) ->
      %% Configure the peer service.
      PeerService = proplists:get_value(partisan_peer_service_manager, Options),
      ct:pal("Setting peer service manager on node ~p to ~p", [Node, PeerService]),
      ok = rpc:call(Node, partisan_config, set,
        [partisan_peer_service_manager, PeerService]),

      MaxActiveSize = proplists:get_value(max_active_size, Options, 5),
      ok = rpc:call(Node, partisan_config, set,
        [max_active_size, MaxActiveSize]),

      Servers = proplists:get_value(servers, Options, []),
      Clients = proplists:get_value(clients, Options, []),

      %% Configure servers.
      case lists:member(Name, Servers) of
        true ->
          ok = rpc:call(Node, partisan_config, set, [tag, server]);
        false ->
          ok
      end,

      %% Configure clients.
      case lists:member(Name, Clients) of
        true ->
          ok = rpc:call(Node, partisan_config, set, [tag, client]);
        false ->
          ok
      end
    end,
    lists:map(ConfigureFun, Nodes),

    ct:pal("Starting nodes."),

    StartFun = fun({_Name, Node}) ->
      %% Start partisan.
      {ok, _} = rpc:call(Node, application, ensure_all_started, [ishikawa])
    end,
    lists:map(StartFun, Nodes),

    ct:pal("Clustering nodes."),
    lists:map(fun(Node) -> cluster(Node, Nodes, Options) end, Nodes),

    ct:pal("Partisan fully initialized."),

    Nodes.

%% @private
codepath() ->
    lists:filter(fun filelib:is_dir/1, code:get_path()).

%% @private
omit(OmitNameList, Nodes0) ->
  FoldFun = fun({Name, _Node} = N, Nodes) ->
    case lists:member(Name, OmitNameList) of
      true ->
        Nodes;
      false ->
        Nodes ++ [N]
    end
  end,
  lists:foldl(FoldFun, [], Nodes0).

%% @private
%%
%% We have to cluster each node with all other nodes to compute the
%% correct overlay: for instance, sometimes you'll want to establish a
%% client/server topology, which requires all nodes talk to every other
%% node to correctly compute the overlay.
%%
cluster({Name, _Node} = Myself, Nodes, Options) when is_list(Nodes) ->
  
  Manager = proplists:get_value(partisan_peer_service_manager, Options),

  Servers = proplists:get_value(servers, Options, []),
  Clients = proplists:get_value(clients, Options, []),

  AmIServer = lists:member(Name, Servers),
  AmIClient = lists:member(Name, Clients),

  OtherNodes = case Manager of
    partisan_default_peer_service_manager ->
      %% Omit just ourselves.
      omit([Name], Nodes);
    partisan_client_server_peer_service_manager ->
      case {AmIServer, AmIClient} of
        {true, false} ->
          %% If I'm a server, I connect to both
          %% clients and servers!
          omit([Name], Nodes);
        {false, true} ->
          %% I'm a client, pick servers.
          omit(Clients, Nodes);
        {_, _} ->
          omit([Name], Nodes)
      end;
    partisan_hyparview_peer_service_manager ->

      case {AmIServer, AmIClient} of
        %% If I'm a server, I connect to both
        %% clients and servers!
        {true, false} ->
          [];
        %% I'm a client, pick servers.
        {false, true} ->
          omit(Clients, Nodes)
      end
  end,
  lists:map(fun(OtherNode) -> join(Myself, OtherNode) end, OtherNodes).

join({_, Node}, {_, OtherNode}) ->
  PeerPort = rpc:call(OtherNode,
    partisan_config,
    get,
    [peer_port, ?PEER_PORT]),
  ct:pal("Joining node: ~p to ~p at port ~p", [Node, OtherNode, PeerPort]),
  ok = rpc:call(Node,
    partisan_peer_service,
    join,
    [{OtherNode, {127, 0, 0, 1}, PeerPort}]).

%% @private
stop(Nodes) ->
  StopFun = fun({Name, _Node}) ->
    case ct_slave:stop(Name) of
      {ok, _} ->
        ok;
      Error ->
        ct:fail(Error)
    end
  end,
  lists:map(StopFun, Nodes),
  ok.

%% @private
node_list(0, _Name) -> [];
node_list(N, Name) ->
  [list_to_atom(string:join([Name, integer_to_list(X)], "_")) || X <- lists:seq(1, N) ].

%% @private
connect(G, N1, N2) ->
  %% Add vertex for neighboring node.
  digraph:add_vertex(G, N1),
  % ct:pal("Adding vertex: ~p", [N1]),

  %% Add vertex for neighboring node.
  digraph:add_vertex(G, N2),
  % ct:pal("Adding vertex: ~p", [N2]),

  %% Add edge to that node.
  digraph:add_edge(G, N1, N2),
  % ct:pal("Adding edge from ~p to ~p", [N1, N2]),

  ok.

%% private
%% Initialize Map containing, per each node, with a generated number of random messages to be sent
%% and an emoty list that will store delivered Messages (VV only) in delivery order
fun_intialize_Msg_Info_Map(Nodes) ->
  lists:foldl(
  fun({_Name, Node}, Acc) ->
    orddict:store(Node, {rand:uniform(?MAX_MSG_NUMBER), []}, Acc)
  end,
  orddict:new(),
  Nodes).

%% @private
fun_send(_Node, 0) ->
  ok;
fun_send(Node, Times) ->
  timer:sleep(1000),
  {ok, _} = rpc:call(Node, ishikawa, tcbcast, [msg]),
  fun_send(Node, Times - 1).

%% @private
fun_receive(NodeMsgInfoMap, Nodes, TotalMessages, TotalReceived, Runner) ->
  receive
    {delivery, Node, VV} ->
      {MsgNumToSend, DelMsgQ} = orddict:fetch(Node, NodeMsgInfoMap),
      NodeMsgInfoMap1 = orddict:store(Node, {MsgNumToSend, DelMsgQ ++ [VV]}, NodeMsgInfoMap),
      %% For each node, update the number of delivered messages on every node
      TotalReceived1 = TotalReceived + 1,
      ct:pal("~p of ~p", [TotalReceived1, TotalMessages]),
      %% check if all msgs were delivered on all the nodes
      case TotalMessages =:= TotalReceived1 of
        true ->
          Runner ! {done, NodeMsgInfoMap1};
        false ->
          fun_receive(NodeMsgInfoMap1, Nodes, TotalMessages, TotalReceived1, Runner)
      end;
    M ->
      ct:fail("UNKWONN ~p", [M])
    end.

%% @private
fun_check_delivery(Nodes, NodeMsgInfoMap) ->
  
  ct:pal("fun_check_delivery"),
  lists:foreach(
    fun({_Name, Node}) ->
      {_, DelMsgQ} = orddict:fetch(Node, NodeMsgInfoMap),
      lists:foldl(
        fun(I, AccI) ->
          lists:foldl(
            fun(J, AccJ) ->
              AccJ andalso not vclock:descends(lists:nth(I, DelMsgQ), lists:nth(J, DelMsgQ))
            end,
            AccI,
          lists:seq(I+1, length(DelMsgQ))) 
        end,
        true,
      lists:seq(1, length(DelMsgQ)-1))
    end,
  Nodes).

%% @private
fun_ready_to_check(Nodes) ->
  receive
    {done, NodeMsgInfoMap} ->
      fun_check_delivery(Nodes, NodeMsgInfoMap);
    M ->
      ct:fail("received incorrect message: ~p", [M])
  end.

fun_causal_test(Nodes) ->
  NodeMsgInfoMap = fun_intialize_Msg_Info_Map(Nodes),

  %% Calculate the number of Messages that will be delivered by each node
  %% result = sum of msgs sent per node * number of nodes (Broadcast)
  TotNumMsgToRecv = lists:sum([V || {_, {V, _}} <- NodeMsgInfoMap]) * ?NODES_NUMBER,

  Self = self(),

  %% Spawn a receiver process to collect all delivered msgs VVs per node
  Receiver = spawn(?MODULE, fun_receive, [NodeMsgInfoMap, Nodes, TotNumMsgToRecv, 0, Self]),

  %% define a delivery function that notifies the Receiver upon delivery
  lists:foreach(fun({_Name, Node}) ->
    DeliveryFun = fun({VV, _Msg}) ->
      Receiver ! {delivery, Node, VV},
      ok
    end,
    ok = rpc:call(Node,
                  ishikawa,
                  tcbdelivery,
                  [DeliveryFun])
  end,
  Nodes),

  %% Sending random messages and recording on delivery the VV of the messages in delivery order per Node
  lists:foreach(fun({_Name, Node}) ->
    {MsgNumToSend, _} = orddict:fetch(Node, NodeMsgInfoMap),
    spawn(?MODULE, fun_send, [Node, MsgNumToSend])
  end, Nodes),

  %% check if all messages where delivered
  %% if ready check causal delivery order, if not loop again
  fun_ready_to_check(Nodes).
