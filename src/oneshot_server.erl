-module(oneshot_server).
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).

-record(state, {listener, acceptor, module}).

start_link(IP, Port, ModuleOrFun) -> 
  gen_server:start_link(?MODULE, [IP, Port, ModuleOrFun], []).

init([PreIP, Port, ModuleOrFun]) ->
  process_flag(trap_exit, true),

  % Be nice and let people specify IPs as strings or tuples.
  IP = case PreIP of
         I when is_list(I) -> Toks = string:tokens(I, "."),
                              Ints = [list_to_integer(T) || T <- Toks],
                              list_to_tuple(Ints);
         I when is_tuple(I) -> I
       end,

  %% The socket options will be set on the acceptor socket automatically
  Listen = gen_tcp:listen(Port, [binary, {packet, raw}, {reuseaddr, true},
                                 {ip, IP}, {keepalive, true}, {backlog, 4096},
                                 {active, false}]),
  case  Listen of
    {ok, Socket} -> % Create first accepting process
                    {ok, Ref} = prim_inet:async_accept(Socket, -1),
                    {ok, #state{listener        = Socket,
                                acceptor        = Ref,
                                module          = ModuleOrFun}};
    {error, Reason} -> {stop, Reason}
  end.

handle_call(_Msg, _From, State) -> {noreply, State}.
handle_cast(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

handle_info({inet_async, ListSock, Ref, {ok, CliSocket}}, 
             #state{listener=ListSock, acceptor=Ref,
             module=ModuleOrFun} = State) ->
  case set_sockopt(ListSock, CliSocket) of
    ok -> 
          case ModuleOrFun of
            M when is_function(M) -> ClientPid = spawn_link(M);
            M when is_atom(M)     -> {ok, ClientPid} = M:start_link()
          end,
          gen_tcp:controlling_process(CliSocket, ClientPid),
          %% Tell the spawned process it owns the socket.
          ClientPid ! {socket_ready, CliSocket},
          {ok, NewRef} = prim_inet:async_accept(ListSock, -1),
          {noreply, State#state{acceptor=NewRef}};
    {error, Reason} -> 
        error_logger:error_msg("Error setting socket options: ~p.\n", [Reason]),
        {stop, Reason, State}
  end;

handle_info({inet_async, ListSock, Ref, Error}, 
            #state{listener=ListSock, acceptor=Ref} = State) ->
  error_logger:error_msg("Error in socket acceptor: ~p.\n", [Error]),
  {stop, exceeded_accept_retry_count, State};

handle_info({'EXIT', Pid, no_socket}, State) ->
  % The back end didn't have any usable sockets left.
  % It cleaned up its connections and there is nothing else to do.
  % Let's log it.
  error_logger:error_msg("Pid ~p ran out of sockets!~n", [Pid]),
  {noreply, State};

handle_info({'EXIT', _Pid, normal}, State) ->
  {noreply, State};

handle_info({'EXIT', _, _}, State) ->
  % something else exited.  Ignore it.  (from a linked process)
  {noreply, State}.

set_sockopt(ListSock, CliSocket) ->
  true = inet_db:register_socket(CliSocket, inet_tcp),
  case prim_inet:getopts(ListSock, [active, nodelay, 
                                    keepalive, delay_send, priority, tos]) of
    {ok, Opts} -> case prim_inet:setopts(CliSocket, Opts) of
                    ok    -> ok;
                    Error -> gen_tcp:close(CliSocket),
                             Error
                  end;
     Error -> gen_tcp:close(CliSocket), Error
  end.
