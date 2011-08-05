-module(oneshot_server).
-behaviour(gen_server).

-export([start_link/3, start_link/4, start_link/5]).
-export([init/1]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).

-record(state, {listener  :: pid(),
                 acceptor :: any(), % opaque identifier
                 module   :: atom() | fun(),
                 function :: atom(),
                 args     :: list()}).

start_link(IP, Port, ModuleOrFun) ->
  % We default to start_link so the previous API that defaulted to using
  % Module:start_link(Args)
  gen_server:start_link(?MODULE, [IP, Port, ModuleOrFun, start_link, []], []).

start_link(IP, Port, Module, Function) ->
  % User can override Function here so we don't unnecessarily start_link.
  gen_server:start_link(?MODULE, [IP, Port, Module, Function, []], []).

start_link(IP, Port, M, F, A) ->
  gen_server:start_link(?MODULE, [IP, Port, M, F, A], []).


init([PreIP, Port, ModuleOrFun, Function, Args]) when
    (is_list(PreIP) orelse is_tuple(PreIP)) andalso is_atom(Function) ->
%  process_flag(trap_exit, true),

  {ok, IP} = inet:getaddr(PreIP, inet),

  %% The socket options will be set on the acceptor socket automatically
  Listen = gen_tcp:listen(Port, [binary, {packet, raw}, {reuseaddr, true},
                                 {ip, IP}, {keepalive, true}, {backlog, 4096},
                                 {active, false}]),
  case  Listen of
    {ok, Socket} -> % Create first accepting process
                    {ok, Ref} = prim_inet:async_accept(Socket, -1),
                    {ok, #state{listener        = Socket,
                                acceptor        = Ref,
                                module          = ModuleOrFun,
                                function        = Function,
                                args            = Args}};
    {error, Reason} -> {stop, Reason}
  end.

handle_call(oneshot_shutdown, _From, State) ->
  {stop, normal, shutdown_complete, State}.

handle_cast(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

handle_info({inet_async, ListenSock, Ref, {ok, CliSock}},
             #state{listener=ListenSock, acceptor=Ref,
             module=ModuleOrFun,
             function=F,
             args=A} = State) ->
  case set_sockopt(ListenSock, CliSock) of
    ok -> Launch = launch_client(CliSock, ModuleOrFun, F, A),
          Launched = spawn(Launch),
          gen_tcp:controlling_process(CliSock, Launched),
          Launched ! socket_assigned,
          {ok, NewRef} = prim_inet:async_accept(ListenSock, -1),
          {noreply, State#state{acceptor=NewRef}};
    {error, Reason} ->
        error_logger:error_msg("Error setting socket options: ~p.\n", [Reason]),
        {stop, Reason, State}
  end;

handle_info({inet_async, ListenSock, Ref, Error},
            #state{listener=ListenSock, acceptor=Ref} = State) ->
  error_logger:error_msg("Error in socket acceptor: ~p.\n", [Error]),
  {stop, exceeded_accept_retry_count, State};

%handle_info({'EXIT', _, _} = Exit, State) ->
%  error_logger:error_msg("Caught exit of: ~p~n", [Exit]),
  % something exited.  Ignore it.  (from a linked process)
%  {noreply, State};

handle_info(Other, State) ->
  error_logger:error_msg("oneshot_server: unexpected info of ~p~n", [Other]),
  {noreply, State}.

set_sockopt(ListenSock, CliSock) ->
  true = inet_db:register_socket(CliSock, inet_tcp),
  case prim_inet:getopts(ListenSock, [active, nodelay,
                                      keepalive, delay_send, priority, tos]) of
    {ok, Opts} -> case prim_inet:setopts(CliSock, Opts) of
                    ok    -> ok;
                    Error -> gen_tcp:close(CliSock),
                             Error
                  end;
     Error -> gen_tcp:close(CliSock), Error
  end.

-spec launch_client(port(), atom() | function(), atom(), list()) -> function().
launch_client(CliSock, ModuleOrFun, F, A) ->
  fun() ->
    ClientPid = case ModuleOrFun of
                  M when is_function(M) -> spawn(M);
                  M when is_atom(M)     -> case apply(M, F, A) of
                                             {ok, Pid} -> unlink(Pid), Pid;
                                                     _ -> failure
                                           end
                end,
    % Block until we receive socket_assigned from oneshot.
    % We can only set controlling_process after this process
    % is given control itself by the async handle_info.
    receive
      socket_assigned -> case ClientPid of
                           failure -> gen_tcp:close(CliSock);
                                 P -> gen_tcp:controlling_process(CliSock, P),
                                      P ! {socket_ready, CliSock}
                         end
    end
  end.
