-module(oneshot_protocol).

% Used by oneshot
-export([run/1, run/2]).

% Used for testing
-export([eval/3, format_response/1]).

-import(lists, [filter/2]).

-define(RN, <<"\r\n">>).
%%--------------------------------------------------------------------
%%% Oneshot Handler
%%--------------------------------------------------------------------
% Parse client command.
run(ServicesTable) ->
  run(ServicesTable, fun(_) -> [] end, []).

run(ServicesTable, Bundler) ->
  run(ServicesTable, Bundler, []).

run(S, Bundler, Acc) ->
    receive
        {socket_ready, Socket} -> inet:setopts(Socket, [{active, once}, {packet, line}]),
                                  run(S, Bundler, Acc);
           {tcp, Socket, Line} -> case Line of
                                     % If first char is *, this is a redis protocol.  Parse then respond.
                                     % NOTE: Inbound Redis protocol is *only* multibulk *ARGC\r\n{$SZ\r\nARGV\r\n}
                                     <<"*", CountNL/binary>> ->
                                        Count = list_to_integer(binary_to_list(strip_nl(CountNL))),
                                        RedisLine = redis_input(Socket, Count),
                                        respond(Socket, S, Bundler, RedisLine);
                                     % Else, plain text protocol.  Respond normally.
                                     _ -> respond(Socket, S, Bundler, Line)
                                   end;
         {tcp_closed, _Socket} -> exit(self(), normal)
    after
        30000 -> exit(self(), normal)  % 30 second command timeout
    end.

redis_input(Socket, Count) ->
    redis_input(Socket, Count, []).

redis_input(_, 0, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
redis_input(Socket, Count, Acc) when Count > 0 ->
    inet:setopts(Socket, [{active, once}, {packet, line}]),
    receive
        {tcp, Socket, Line} ->
            case Line of
                <<"$", SizeNL/binary>> ->
                    Size = list_to_integer(binary_to_list(strip_nl(SizeNL))),
                    inet:setopts(Socket, [{packet, raw}]),
                    {ok, Data} = gen_tcp:recv(Socket, Size),
                    gen_tcp:recv(Socket, 2), % throw away \r\n
                    % Poor way of doing join(Input, " ") below, but the
                    % extraneous " " will get tokenized away.
                    redis_input(Socket, Count-1, [<<" ">>, Data | Acc]);
                     % Note: this error will *not* return an error to
                     % the client.  Client errors only get generated once
                     % we are in the `try` of repond/4.
                O -> {error, unsupported_input_found, O}
            end;
        {tcp_closed, _Socket} -> exit(self(), normal)
    after
        30000 -> exit(self(), normal)  % stop a too-high Count from lingering
    end.

respond(Socket, ServicesTable, Bundler, Input) ->
    Response =
    try
        process_request(ServicesTable, Bundler, iolist_to_binary(Input))
    catch
        throw:Err -> {error, protocol, iolist_to_binary(
                       re:replace(
                        io_lib:format("~p", [Err]),
                        % Remove: long lines of double spaces and newlines
                        % generated by ~p
                        "  |\n", "", [global]))}

    end,
    send_reply(Socket, Response),
    exit(normal).

send_reply(Socket, Response) ->
    FormattedResponse = format_response(Response),
    gen_tcp:send(Socket, FormattedResponse),
    gen_tcp:close(Socket).

format_response(Response) when is_list(Response) ->
    ["*", integer_to_list(length(Response)), ?RN,
     [format_response(X) || X <- Response]];
format_response(Response) when is_integer(Response) ->
    [":", integer_to_list(Response), ?RN];
format_response(Response) when is_binary(Response) ->
    ["$", integer_to_list(size(Response)), ?RN,
     Response, ?RN];
format_response(Response) when
  Response =:=  null orelse Response =:= undefined ->
    <<"$-1\r\n">>;
format_response(Response) when is_atom(Response) ->
    ["+", string:to_upper(atom_to_list(Response)), ?RN];
format_response({error, Type, Err}) when is_atom(Type) andalso is_binary(Err) ->
    ["-", string:to_upper(atom_to_list(Type)), " ", Err, ?RN].

strip_nl(B) when is_binary(B) ->
  S = size(B) - 2,  % 2 = size(<<"\r\n">>)
  <<B1:S/binary, _/binary>> = B,
  B1.
%%--------------------------------------------------------------------
%%% Protocol Handler
%%--------------------------------------------------------------------
% The default protocol here is just space separated commands terminated by a newline.
% Convert user input to lowercase tokenized list of strings.
process_request(ServiceTable, Bundler, Request) when is_binary(Request) ->
    Str = binary_to_list(Request),
    Lower = string:to_lower(Str),
    [Service | Command] = string:tokens(Lower, " \r\n"),
    case Service of
        "ping" -> pong;
             _ -> try
                    eval_command(ServiceTable, Bundler, list_to_existing_atom(Service), Command)
                  catch
                    error:badarg -> throw({no_service, Service, for, Command})
                  end
    end.

eval_command(ServiceTable, Bundler, Service, Command) when
  (is_atom(ServiceTable) orelse is_integer(ServiceTable)) andalso
  is_atom(Service) andalso is_list(Command) ->
    case ets:lookup(ServiceTable, Service) of
        [{Service, ServiceModule}] -> eval(Command, ServiceModule:describe_service(), Bundler(Service));
                                [] -> throw({no_service, Service, for, Command})
    end.

%%--------------------------------------------------------------------
%%% Command Tree Parser and Runner
%%--------------------------------------------------------------------
% Sample service tree/DAG/DFA:
%describe_service() ->
%    [{"create", [{"standalone", fun create_standalone/0},
%                 {"master-replica", [fun create_master_replica/0,
%                                     {"replicas", str, fun create_master_replica/1}]},
%                 {"cluster", [{"total-nodes", str, fun create_cluster_total/1},
%                              {"masters", str, "replicas", str, fun create_cluster_mr/2}]}]}].
%
% If we are on the last input command, see if the matching
% command set is a tuple of {Cmd, Fun}:
eval([Cmd], [{Cmd, {Mod, Fun}}|_], ExtraArgs) ->
    apply(Mod, Fun, ExtraArgs);
% If we are on the last input command, iterate over the
% command set to find the one function to run.
% (The fun has zero arity by definition of having no args)
eval([Cmd], [{Cmd, CmdOpts}|_], ExtraArgs) when is_list(CmdOpts) ->
    case filter(fun({_ ,_}) -> true; (_) -> false end, CmdOpts) of
        [{Mod, Fun}] -> apply(Mod, Fun, ExtraArgs);
                    _ -> throw({nomatch, {need_more_commands_after, Cmd}})
    end;
% If we find a match for the current input command level,
% (on a tuple of two elements)
% use the matching argument list and move on to the next
% input command.
eval([Cmd|T], [{Cmd, Fields}|_], ExtraArgs) when is_list(Fields) ->
    eval(T, Fields, ExtraArgs);
% If we find a match for the current input command level,
% (on a tuple of unknown arity at the moment),
% this means we found a sub-command taking arguments we
% need to accumulate then apply to the action fun at
% the end of the command list.
% Dive into parsing out position-based parameters
% from the arguments then apply them to the action
% function with fun_with_args/2.
eval([Cmd|T], [CmdWithArgs|_], ExtraArgs) when is_tuple(CmdWithArgs) andalso element(1, CmdWithArgs) =:= Cmd ->
    fun_with_args(T, tl(tuple_to_list(CmdWithArgs)), ExtraArgs);
% If we haven't found a command match yet, recurse
% on the command definitions.
eval(Args, [_|T], ExtraArgs) ->
    eval(Args, T, ExtraArgs);
% If nothing matches, error out.
eval(Args, _, _) ->
    throw({nomatch, command_not_found, {remaining_args, Args}}).

fun_with_args(CmdParts, SpecParts, ExtraArgs) ->
    fun_with_args(CmdParts, SpecParts, ExtraArgs,  []).

% If we ran out of command input and there is one remaining
% item on the command set is a function, we successfully
% mathed the input. Send the found arguments to the function.
fun_with_args([], [{Mod, Fun}], ExtraArgs, Acc) ->
    apply(Mod, Fun, ExtraArgs ++ lists:reverse(Acc));
% If we ran out of command input, but have more than
% one element in the command set list left over, then we
% didn't get enough input to run our function.  Abort.
fun_with_args([], _MultipleThingsLeftOver, _, Acc) ->
    throw({nomatch, need_more_args, {processed_args, lists:reverse(Acc)}});
% If the command input matches the level of the command set,
% just recurse on both.
fun_with_args([Arg|T], [Arg|SpecT], EA, Acc) ->
    fun_with_args(T, SpecT, EA, Acc);
% If the command input matches the location of a variable atom
% in the command set, add the command input to our
% accumulator for future application.
% Allow auto-converted types of: string, integer, atom, eatom, binary
fun_with_args([Arg|T], [str|SpecT], EA, Acc) ->
    fun_with_args(T, SpecT, EA, [Arg | Acc]);
fun_with_args([Arg|T], [int|SpecT], EA, Acc) ->
    fun_with_args(T, SpecT, EA, [list_to_integer(Arg) | Acc]);
fun_with_args([Arg|T], [atom|SpecT], EA, Acc) ->
    fun_with_args(T, SpecT, EA, [list_to_atom(Arg) | Acc]);
fun_with_args([Arg|T], [eatom|SpecT], EA, Acc) ->
    fun_with_args(T, SpecT, EA, [list_to_existing_atom(Arg) | Acc]);
fun_with_args([Arg|T], [bin|SpecT], EA, Acc) ->
    fun_with_args(T, SpecT, EA, [list_to_binary(Arg) | Acc]);
% If the input command didn't match a positional
% command set argument OR a positional command set
% variable indicator, then the user entered an
% incorrect command.  Abort.
fun_with_args(ArgNoMatch, _NoMatchSpec, _, Acc) ->
    throw({nomatch, too_many_arguments,
           {extra_args, ArgNoMatch},
           {processed_args, lists:reverse(Acc)}}).
