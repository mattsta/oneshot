-module(oneshot_sup).

-behaviour(supervisor).

%% External exports
-export([start_link/0, start_oneshot/3, start_oneshot/4, start_oneshot/5]).
-export([stop_oneshot/1]).

%% supervisor callbacks
-export([init/1]).

start_oneshot(IP, Port, FunOrModule) when is_integer(Port) ->
  supervisor:start_child(?MODULE, [IP, Port, FunOrModule]).

start_oneshot(IP, Port, Module, Function) when is_integer(Port) ->
  supervisor:start_child(?MODULE, [IP, Port, Module, Function]).

start_oneshot(IP, Port, Module, Function, Args) when is_integer(Port) ->
  supervisor:start_child(?MODULE, [IP, Port, Module, Function, Args]).

stop_oneshot(Pid) ->
  supervisor:terminate_child(?MODULE, Pid).  % R14B03+


start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
  Oneshot = {oneshot_server,
             {oneshot_server, start_link, []},
              transient, 5000, worker, dynamic},

  Processes = [Oneshot],

  Strategy = {simple_one_for_one, 10, 10},
  {ok,
   {Strategy, Processes}}.
