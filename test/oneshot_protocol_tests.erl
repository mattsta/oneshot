-module(oneshot_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

-define(S1, {"localhost", 6651}).
-define(S2, {"localhost", 6652}).
-define(S3, {"localhost", 6653}).

-define(E(A, B), ?assertEqual(A, B)).
-define(EM(A, B), ?E(match, match(rs(?S1, A), B))).
-define(_E(A, B), ?_assertEqual(A, B)).
-define(B(X), iolist_to_binary(X)).
-define(F(X), error_logger:error_msg("~p~n", [X])).

-compile(export_all).
-export([describe_service/0]).

%%====================================================================
%% Test concurrency of three echo servers
%%====================================================================
protocol_test_() ->
  {setup,
    fun setup_servers/0,
    fun teardown_servers/1,
    [
     {"Format Response (RESP) Tests",
      fun responses/0},
     {"Test non-service-table entry failure",
      fun non_entry/0},
     {"Test non-existing top level command failure",
      fun non_command/0},
     {"Test CREATE failure",
      fun create_fail/0},
     {"Test CREATE STANDALONE success",
      fun create_success/0},
     {"Test CREATE MASTER-REPLICA success",
      fun create_mr_success/0},
     {"Test CREATE MASTER-REPLICA REPLICAS failure",
      fun create_mr_replicas_failure/0},
     {"Test CREATE MASTER-REPLICA REPLICAS N success",
      fun create_mr_replicas_success/0},
     {"Test CREATE CLUSTER failure",
      fun create_cluster_failure/0},
     {"Test CREATE CLUSTER TOTAL-NODES failure",
      fun create_cluster_nodes_failure/0},
     {"Test CREATE CLUSTER TOTAL-NODES N success",
      fun create_cluster_nodes_success/0},
     {"Test CREATE CLUSTER MASTERS failure",
      fun create_cluster_masters_failure/0},
     {"Test CREATE CLUSTER MASTERS N failure",
      fun create_cluster_masters_N_failure/0},
     {"Test CREATE CLUSTER MASTERS N REPLICAS failure",
      fun create_cluster_masters_N_replicas_failure/0},
     {"Test CREATE CLUSTER MASTERS N REPLICAS N success",
      fun create_cluster_masters_replicas_success/0},
     {"Test Inbound Redis Protocol",
      fun redis_inbound_protocol_success/0},
     {"Test Ping",
      fun ping/0}
    ]
  }.

%%====================================================================
%% Tests
%%====================================================================
% format_response/1 returns a deep list of stuff, so flatten here for matching.
-define(FR(Input), iolist_to_binary(oneshot_protocol:format_response(Input))).
responses() ->
    ?E(<<"+OK\r\n">>, ?FR(ok)),
    ?E(<<"$-1\r\n">>, ?FR(null)),
    ?E(<<"$-1\r\n">>, ?FR(undefined)),
    ?E(<<":3000\r\n">>, ?FR(3000)),
    ?E(<<"$4\r\n3000\r\n">>, ?FR(<<"3000">>)),
    ?E(<<"*3\r\n+OK\r\n$5\r\nhello\r\n:600\r\n">>,
        ?FR([ok, <<"hello">>, 600])),
    % nested multibulk
    ?E(<<"*3\r\n+OK\r\n$5\r\nhello\r\n*3\r\n$4\r\nmore\r\n:512\r\n+NOGO\r\n">>,
        ?FR([ok, <<"hello">>, [<<"more">>, 512, nogo]])),
    ?E(<<"-PROTOCOL bad send\r\n">>, ?FR({error, protocol, <<"bad send">>})),
    ?E(<<"-ERR other BAD thing\r\n">>, ?FR({error, err, <<"other BAD thing">>})).


% Note: the ?EM wrapper calls rs/2 which adds the command newline
% The ?EM macro does three compound operations to minimize repetitiveness below.
non_entry() ->
    ?EM("noservice run me", "no_service"),  % dies at list_to_existing_atom
    ?EM("non_entry run me", "no_service").  % dies on table lookup for non_entry service

non_command() ->
    ?EM("rEdIs bumble me no more", "command_not_found").

create_fail() ->
    ?EM("redis create", "need_more_commands_after").

create_success() ->
%    ?F(rs(?S1, "redis create standalone")),
    ?EM("redis create StanDaLonE", "CREATED[.\r\n+]*STANDALONE"),
    ?EM("redis create standalone but with extra", "too_many_arguments").

create_mr_success() ->
    ?EM("redis create master-replica", "CREATED_MASTER_REPLICA").

create_mr_replicas_failure() ->
    ?EM("redis create master-replica replicas", "need_more_args").

create_mr_replicas_success() ->
%    ?F(rs(?S1, "redis create master-replica replicas 64")),
    ?EM("redis create master-replica replicas 64", "mr_count_64").

create_cluster_failure() ->
    ?EM("redis create cluster", "need_more_commands_after").

create_cluster_nodes_failure() ->
    ?EM("redis create cluster nodes", "command_not_found"),
    ?EM("redis create cluster total-nodes", "need_more_args").

create_cluster_nodes_success() ->
    ?EM("redis create cluster total-nodes 32", "node_count_32").

create_cluster_masters_failure() ->
    ?EM("redis create cluster masters", "need_more_args").

create_cluster_masters_N_failure() ->
    ?EM("redis create cluster masters 500", "need_more_args").

create_cluster_masters_N_replicas_failure() ->
    ?EM("redis create cluster masters 500 replicas", "need_more_args").

create_cluster_masters_replicas_success() ->
    ?EM("redis create cluster masters 500 replicas 6000", "MC_RPMC_500_6000"),
    ?EM("redis create cluster masters 500 replicas 6000 and even more", "too_many_arguments").

redis_inbound_protocol_success() ->
    ?EM("*3\r\n$5\r\nredis\r\n$6\r\ncreate\r\n$10\r\nstandalone\r\n", "CREATED[.\r\n+]*STANDALONE").

ping() ->
    ?EM("ping", "PONG"),
    ?EM("PING", "PONG"),
    ?EM("PinG", "PONG").

%%====================================================================
%% Test Setup
%%====================================================================
%%====================================================================
%% protocol descriptor table for tests
%%====================================================================
describe_service() ->
    [{"create", [{"standalone", {?MODULE, create_standalone}},
                 {"master-replica", [{?MODULE, create_master_replica},
                                     {"replicas", str, {?MODULE, create_master_replica}}]},
                 {"cluster", [{"total-nodes", str, {?MODULE, create_cluster_total}},
                              {"masters", str, "replicas", str, {?MODULE, create_cluster_mr}}]}]}].

create_standalone() -> [created, standalone].
create_master_replica() -> created_master_replica.
create_master_replica(ReplicaCount) ->
    iolist_to_binary(io_lib:format("mr_count_~s", [ReplicaCount])).
create_cluster_total(NodeCount) ->
    iolist_to_binary(io_lib:format("node_count_~s", [NodeCount])).
create_cluster_mr(MasterCount, ReplicaPerMasterCount) ->
    iolist_to_binary(
     io_lib:format("MC_RPMC_~s_~s", [MasterCount, ReplicaPerMasterCount])).

%%====================================================================
%% Setup/teardown for each test suite
%%====================================================================
setup_servers() ->
  oneshot_sup:start_link(),
  service = ets:new(service, [public, named_table]),
  ets:insert(service, {redis, ?MODULE}),

  S1 = oneshot_server:protocol_start_link("127.0.0.1", 6651, service),
  S2 = oneshot_server:start_link("127.0.0.1", 6652, service),
  S3 = oneshot_server:start_link("127.0.0.1", 6653, service),

  [P || {ok, P} <- [S1, S2, S3]].

teardown_servers(Ps) ->
    [exit(P, normal) || P <- Ps],
    ets:delete(service).

%%====================================================================
%% Network data goodness finders
%%====================================================================
match(Output, LookForStr) ->
    case re:run(Output, LookForStr) of
           nomatch -> nomatch;
        {match, _} -> match
    end.

%%====================================================================
%% Send data to a server; returns {Socket, TotalDataLength}
%%====================================================================
rs(A, B) ->
    recv(send(A, [B, "\n"])).

send({Host, Port}, Data) ->
  send(Host, Port, Data).

send(Host, Port, Data) ->
  {ok, Sock} = gen_tcp:connect(Host, Port, [binary, {active, false}]),
  gen_tcp:send(Sock, Data),
  {Sock, iolist_size(Data)}.

%%====================================================================
%% Receive data from a socket we already have open
%%====================================================================
recv({Sock, TotalSize}) ->
  recv_loop(Sock, TotalSize, []).

recv_loop(Sock, TotalSize, Acc) ->
  case gen_tcp:recv(Sock, 0) of
         {ok, Data} -> Total = [Data | Acc],
                       case iolist_size(Total) of
                         TotalSize -> gen_tcp:close(Sock);
                                 _ -> ok
                       end,
                       recv_loop(Sock, TotalSize, [Data | Acc]);
    {error, closed} -> lists:reverse(Acc)
  end.
