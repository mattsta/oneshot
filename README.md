oneshot: accept a tcp connection and do something with it
=========================================================

What is oneshot?
----------------
oneshot is a simple async TCP server.  When a client connects, oneshot
runs a function, sends a message to the function containing the socket, then
waits for more connections.

API
---
All you need for `oneshot` is a fun or module name and IP/Port combination.

If you pass an atom to `oneshot:start_link/3` as the module parameter, each
connection will spawn start_link on that atom (module) name.  The process must
accept a `{socket_ready, Sock}` message to get the socket descriptor.

If you pass a fun to `oneshot:start_link/3` as the module parameter, each
connection spawns that fun.  The fun must accept a `{socket_ready, Sock}`
message to get the socket descriptor.

Usage
-----
### Simple Usage
`handler/0` receives a `{socket_ready, Sock}` message then loops forever just
echoing back input to the client.  The process gets killed when the connection
closes.

```erlang
    handler() ->
        receive
            {socket_ready, Sock} -> inet:setopts(Sock, [{active, once}]),
                                    handler();
            {tcp, Sock, Bin} -> gen_tcp:send(Sock, Bin),
                                inet:setopts(Sock, [{active, once}]),
                                handler()
        end
    end.

    init() -> oneshot:start_link("127.0.0.1", 6643, fun handler/0).
```

### More Complex Usage
If we need local state information in the handler,
encapsulate a function in a local fun to provide state information
to our handler (because all handlers must have arity 0):

```erlang
   handler(ServerPid) ->
     handler(ServerPid, []).

   handler(ServerPid, Acc) ->
     receive
       {socket_ready, Socket} -> inet:setopts(Socket, [{active, once}]),
                                 handler(ServerPid, Acc);
       {tcp, Socket, Bin} -> inet:setopts(Socket, [{active, once}]),
                             NewAcc = [Bin | Acc],
                             gen_server:call(ServerPid, NewAcc),
                             handler(ServerPid, NewAcc)
     end.

   setup_server(IP, Port) ->
     ThisGenServer = self(),
     oneshot_server:start_link(IP, Port,
                               fun() ->
                                 handler(ThisGenServer)
                               end).
```

Building
--------
Build:

    rebar compile

Test
----
Automated concurrency tests:

    rebar eunit

Automated concurrency tests with timing details:

    rebar eunit -v

History
-------
The generic non-blocking/async TCP server code originated at
http://www.trapexit.org/Building_a_Non-blocking_TCP_server_using_OTP_principles
which I used in my `tt` project to spawn one FSM per connection.  I generalized
the spawn-per-connect processing into `oneshot` for use in 
`erlang-stdinout-pool`.  Hopefully other projects can find a use for a simple
TCP connection abstraction.
