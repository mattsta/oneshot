-module(oneshot_server_tests).
-include_lib("eunit/include/eunit.hrl").

-define(E(A, B), ?assertEqual(A, B)).
-define(_E(A, B), ?_assertEqual(A, B)).
-define(B(X), iolist_to_binary(X)).

%%====================================================================
%% echo_server/0 is spawned for each new connection
%%====================================================================
echo_server() ->
  receive
       {tcp, Sock, Data} -> gen_tcp:send(Sock, Data),
                            echo_server();
         {error, closed} -> ok;  % process exits here and dies
    {socket_ready, Sock} -> inet:setopts(Sock, [{active, true}]),
                            echo_server()
  end.

%%====================================================================
%% Setup/teardown for each test suite
%%====================================================================
-define(S1, {"localhost", 6651}).
-define(S2, {"localhost", 6652}).
-define(S3, {"localhost", 6653}).
setup_servers() ->
  S1 = oneshot_server:start_link("127.0.0.1", 6651, fun echo_server/0),
  S2 = oneshot_server:start_link("127.0.0.1", 6652, fun echo_server/0),
  S3 = oneshot_server:start_link("127.0.0.1", 6653, fun echo_server/0),

  [P || {ok, P} <- [S1, S2, S3]].

cleanup_servers(Ps) ->
  [exit(P, normal) || P <- Ps].

%%====================================================================
%% Send data to a server; returns {Socket, TotalDataLength}
%%====================================================================
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

%%====================================================================
%% Test concurrency of three echo servers
%%====================================================================
echo_servers_in_parallel_test_() ->
  {setup,
    fun setup_servers/0,
    fun cleanup_servers/1,
    fun(_) -> 
      {inparallel, 
        [
          [?_E(<<"hello">>, ?B(recv(send(?S1, "hello")))) ||
            _ <- lists:seq(1, 500)],
          [?_E(<<"hello">>, ?B(recv(send(?S2, "hello")))) ||
            _ <- lists:seq(1, 500)],
          [?_E(<<"hello">>, ?B(recv(send(?S3, "hello")))) ||
            _ <- lists:seq(1, 500)]
        ]
      }
    end
  }.
