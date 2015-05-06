%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_templater).

-export(['create-app'/2,
         'create-lib'/2,
         'create-node'/2,
         'list-templates'/2,
         create/2]).

%% API for other utilities that need templating functionality
-export([resolve_variables/2,
         render/2]).

%% for internal use only
-export([info/2]).

-include("rebar.hrl").

-define(TEMPLATE_RE, "^[^._].*\\.template\$").

%% ===================================================================
%% Public API
%% ===================================================================

'create-app'(Config, _File) ->
    %% Alias for create w/ template=simpleapp
    create1(Config, "simpleapp").

'create-lib'(Config, _File) ->
    %% Alias for create w/ template=simplelib
    create1(Config, "simplelib").

'create-node'(Config, _File) ->
    %% Alias for create w/ template=simplenode
    create1(Config, "simplenode").

'list-templates'(Config, _File) ->
    {AvailTemplates, Files} = find_templates(Config),
    ?DEBUG("Available templates: ~p\n", [AvailTemplates]),

    lists:foreach(
      fun({Type, F}) ->
              BaseName = filename:basename(F, ".template"),
              % TemplateTerms = consult(load_file(Files, Type, F)),
              case consult(load_file(Files, Type, F)) of
                  {error, Error} ->
                      ?CONSOLE("~n!!Error occurs while processing file ~p: ~n~p~n~n",
                               [F, Error]);
                  TemplateTerms ->
                      {_, VarList} = lists:keyfind(variables, 1, TemplateTerms),
                      Vars = lists:foldl(fun({V,_}, Acc) ->
                                                 [atom_to_list(V) | Acc]
                                         end, [], VarList),
                      ?CONSOLE(" * ~s: \n    ~p: ~s\n    variables: ~p\n",
                               [BaseName, Type, F, string:join(Vars, ", ")])
              end
      end, AvailTemplates),
    ok.

create(Config, _) ->
    TemplateId = template_id(Config),
    create1(Config, TemplateId).

%%
%% Given a list of key value pairs, for each string value attempt to
%% render it using Dict as the context. Storing the result in Dict as Key.
%%
resolve_variables([], Dict) ->
    Dict;
resolve_variables([{Key, Value0} | Rest], Dict) when is_list(Value0) ->
    Value = render(list_to_binary(Value0), Dict),
    resolve_variables(Rest, dict:store(Key, Value, Dict));
resolve_variables([{Key, {list, Dicts}} | Rest], Dict) when is_list(Dicts) ->
    %% just un-tag it so mustache can use it
    resolve_variables(Rest, dict:store(Key, Dicts, Dict));
resolve_variables([_Pair | Rest], Dict) ->
    resolve_variables(Rest, Dict).

%%
%% Render a binary to a string, using mustache and the specified context
%%
render(Bin, Context) ->
    %% Be sure to escape any double-quotes before rendering...
    ReOpts = [global, {return, list}],
    Str0 = re:replace(Bin, "\\\\", "\\\\\\", ReOpts),
    Str1 = re:replace(Str0, "\"", "\\\\\"", ReOpts),
    rebar_mustache:render(Str1, Context).

%% ===================================================================
%% Internal functions
%% ===================================================================

info(help, create) ->
    ?CONSOLE(
       "Create skel based on template and vars.~n"
       "~n"
       "Valid command line options:~n"
       "  template= [var=foo,...]~n", []);
info(help, 'create-app') ->
    ?CONSOLE(
       "Create simple app skel.~n"
       "~n"
       "Valid command line options:~n"
       "  [appid=myapp]~n", []);
info(help, 'create-lib') ->
    ?CONSOLE(
       "Create simple lib skel.~n"
       "~n"
       "Valid command line options:~n"
       "  [libid=mylib]~n", []);
info(help, 'create-node') ->
    ?CONSOLE(
       "Create simple node skel.~n"
       "~n"
       "Valid command line options:~n"
       "  [nodeid=mynode]~n", []);
info(help, 'list-templates') ->
    ?CONSOLE("List available templates.~n", []).

create1(Config, TemplateId) ->
    {AvailTemplates, Files} = find_templates(Config),
    ?DEBUG("Available templates: ~p\n", [AvailTemplates]),

    %% Using the specified template id, find the matching template file/type.
    %% Note that if you define the same template in both ~/.rebar/templates
    %% that is also present in the escript, the one on the file system will
    %% be preferred.
    {Type, Template} = select_template(AvailTemplates, TemplateId),

    %% Load the template definition as is and get the list of variables the
    %% template requires.
    TemplateTerms = consult(load_file(Files, Type, Template)),
    case lists:keyfind(variables, 1, TemplateTerms) of
        {variables, Vars} ->
            case parse_vars(Vars, dict:new()) of
                {error, Entry} ->
                    NContext0 = undefined,
                    ?ABORT("Failed while processing variables from template ~p."
                           "Variable definitions must follow form of "
                           "[{atom(), term()}]. Failed at: ~p\n",
                           [TemplateId, Entry]);
                NContext0 ->
                    ok
            end;
        false ->
            ?WARN("No variables section found in template ~p; "
                  "using empty context.\n", [TemplateId]),
            NContext0 = dict:new()
    end,

    %% Add some built-in variables
    Context0 = dict:store(now_ts, format_time(erlang:localtime()), NContext0),

    %% Load global variables from disk file, if provided
    %% I don't like the original "global" idea (template_var option passing through command line) in rebar (#476)
    %% SO HERE GOES WARNING:
    %% ** the branch break backwards compatibility! ***
    GVarsFile = filename:join([os:getenv("HOME"), ".rebar", "global.vars"]),
    Context1 = case consult(load_file([], file, GVarsFile)) of
                   {error,enoent} -> % no such file
                       Context0;
                   {error, Reason} ->
                       ?ABORT("Unable to load template variables from ~s: ~p\n",
                              [GVarsFile, Reason]);
                   Terms ->
                       %% TODO: Cleanup/merge with similar code in rebar_reltool
                       M = fun(_Key, _Base, Override) -> Override end,
                       dict:merge(M, Context0, dict:from_list(Terms))
    end,


    %% Load variables that defined in rebar config file
    TemplateVars = rebar_config:get(Config, template_vars, []),
    Context2 = case lists:keyfind(TemplateId, 1, TemplateVars) of
                   false       -> Context1;
                   {_, Terms2} ->
                       M2 = fun(_Key, _Base, Override) -> Override end,
                       dict:merge(M2, Context1, dict:from_list(Terms2))
               end,


    %% For each variable, see if it's defined in global vars -- if it is,
    %% prefer that value over the defaults
    Context3 = update_vars(Config, dict:fetch_keys(Context2), Context2),
    ?DEBUG("Template ~p context: ~p\n", [TemplateId, dict:to_list(Context2)]),

    %% Handle variables that possibly include other variables in their
    %% definition
    Context = resolve_variables(dict:to_list(Context3), Context3),

    ?DEBUG("Resolved Template ~p context: ~p\n",
           [TemplateId, dict:to_list(Context)]),

    %% Now, use our context to process the template definition -- this
    %% permits us to use variables within the definition for filenames.
    FinalTemplate = consult(render(load_file(Files, Type, Template), Context)),
    ?DEBUG("Final template def ~p: ~p\n", [TemplateId, FinalTemplate]),

    %% Execute the instructions in the finalized template
    Force = rebar_config:get_global(Config, force, "0"),
    execute_template(Files, FinalTemplate, Type, Template, Context, Force, []).

find_templates(Config) ->
    %% Load a list of all the files in the escript -- cache them since
    %% we'll potentially need to walk it several times over the course of
    %% a run.
    Files = cache_escript_files(Config),

    %% Build a list of available templates
    AvailTemplates = find_disk_templates(Config)
        ++ find_escript_templates(Files),

    {AvailTemplates, Files}.

%%
%% Scan the current escript for available files
%%
cache_escript_files(Config) ->
    {ok, Files} = rebar_utils:escript_foldl(
                    fun(Name, _, GetBin, Acc) ->
                            [{Name, GetBin()} | Acc]
                    end,
                    [], rebar_config:get_xconf(Config, escript)),
    Files.

template_id(Config) ->
    case rebar_config:get_global(Config, template, undefined) of
        undefined ->
            ?ABORT("No template specified.\n", []);
        TemplateId ->
            TemplateId
    end.

find_escript_templates(Files) ->
    [{escript, Name}
     || {Name, _Bin} <- Files,
        re:run(Name, ?TEMPLATE_RE, [{capture, none}]) == match].

find_disk_templates(Config) ->
    OtherTemplates = find_other_templates(Config),
    HomeTemplates = filename:join([os:getenv("HOME"), ".rebar", "templates"]),
    HomeFiles = rebar_utils:find_files_by_ext(HomeTemplates, ".template"),
    Recursive = rebar_config:is_recursive(Config),
    LocalFiles = rebar_utils:find_files_by_ext(".", ".template", Recursive),
    [{file, F} || F <- OtherTemplates ++ HomeFiles ++ LocalFiles].

find_other_templates(Config) ->
    case rebar_config:get_global(Config, template_dir, undefined) of
        undefined ->
            [];
        TemplateDir ->
            rebar_utils:find_files_by_ext(TemplateDir, ".template")
    end.

select_template([], Template) ->
    ?ABORT("Template ~s not found.\n", [Template]);
select_template([{Type, Avail} | Rest], Template) ->
    case filename:basename(Avail, ".template") == Template of
        true ->
            {Type, Avail};
        false ->
            select_template(Rest, Template)
    end.

%%
%% Read the contents of a file from the appropriate source
%%
load_file(Files, escript, Name) ->
    {Name, Bin} = lists:keyfind(Name, 1, Files),
    Bin;
load_file(_Files, file, Name) ->
    {ok, Bin} = file:read_file(Name),
    Bin.

%%
%% Parse/validate variables out from the template definition
%%
parse_vars([], Dict) ->
    Dict;
parse_vars([{Key, Value} | Rest], Dict) when is_atom(Key) ->
    parse_vars(Rest, dict:store(Key, Value, Dict));
parse_vars([Other | _Rest], _Dict) ->
    {error, Other};
parse_vars(Other, _Dict) ->
    {error, Other}.

%%
%% Given a list of keys in Dict, see if there is a corresponding value defined
%% in the global config; if there is, update the key in Dict with it
%%
update_vars(_Config, [], Dict) ->
    Dict;
update_vars(Config, [Key | Rest], Dict) ->
    Value = rebar_config:get_global(Config, Key, dict:fetch(Key, Dict)),
    update_vars(Config, Rest, dict:store(Key, Value, Dict)).


%%
%% Given a string or binary, parse it into a list of terms, ala file:consult/1
%%
consult(Str) when is_list(Str) ->
    consult([], Str, []);
consult(Bin) when is_binary(Bin)->
    consult([], binary_to_list(Bin), []).

consult(Cont, Str, Acc) ->
    case erl_scan:tokens(Cont, Str, 0) of
        {done, Result, Remaining} ->
            case Result of
                {ok, Tokens, _} ->
                    % {ok, Term} = erl_parse:parse_term(Tokens),
                    case erl_parse:parse_term(Tokens) of
                        {ok, Term} ->
                            consult([], Remaining, [maybe_dict(Term) | Acc]);
                        {error, ErrorInfo} ->
                            {error, ErrorInfo}
                    end;
                {eof, _Other} ->
                    lists:reverse(Acc);
                {error, Info, _} ->
                    {error, Info}
            end;
        {more, Cont1} ->
            consult(Cont1, eof, Acc)
    end.


maybe_dict({Key, {list, Dicts}}) ->
    %% this is a 'list' element; a list of lists representing dicts
    {Key, {list, [dict:from_list(D) || D <- Dicts]}};
maybe_dict(Term) ->
    Term.


write_file(Output, Data, Force) ->
    %% determine if the target file already exists
    FileExists = filelib:is_regular(Output),

    %% perform the function if we're allowed,
    %% otherwise just process the next template
    case Force =:= "1" orelse FileExists =:= false of
        true ->
            ok = filelib:ensure_dir(Output),
            case {Force, FileExists} of
                {"1", true} ->
                    ?CONSOLE("Writing ~s (forcibly overwriting)~n",
                             [Output]);
                _ ->
                    ?CONSOLE("Writing ~s~n", [Output])
            end,
            case file:write_file(Output, Data) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?ABORT("Failed to write output file ~p: ~p\n",
                           [Output, Reason])
            end;
        false ->
            {error, exists}
    end.

prepend_instructions(Instructions, Rest) when is_list(Instructions) ->
    Instructions ++ Rest;
prepend_instructions(Instruction, Rest) ->
    [Instruction|Rest].

%%
%% Execute each instruction in a template definition file.
%%
execute_template(_Files, [], _TemplateType, _TemplateName,
                 _Context, _Force, ExistingFiles) ->
    case ExistingFiles of
        [] ->
            ok;
        _ ->
            Msg = lists:flatten([io_lib:format("\t* ~p~n", [F]) ||
                                    F <- lists:reverse(ExistingFiles)]),
            Help = "To force overwriting, specify -f/--force/force=1"
                " on the command line.\n",
            ?ERROR("One or more files already exist on disk and "
                   "were not generated:~n~s~s", [Msg , Help])
    end;
execute_template(Files, [{'if', Cond, True} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    execute_template(Files, [{'if', Cond, True, []}|Rest], TemplateType,
                     TemplateName, Context, Force, ExistingFiles);
execute_template(Files, [{'if', Cond, True, False} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    Instructions = case dict:find(Cond, Context) of
                       {ok, true} ->
                           True;
                       {ok, "true"} ->
                           True;
                       _ ->
                           False
                   end,
    execute_template(Files, prepend_instructions(Instructions, Rest),
                     TemplateType, TemplateName, Context, Force,
                     ExistingFiles);
execute_template(Files, [{'case', Variable, Values, Instructions} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    {ok, Value} = dict:find(Variable, Context),
    Instructions2 = case lists:member(Value, Values) of
                       true ->
                           Instructions;
                       _ ->
                           []
                   end,
    execute_template(Files, prepend_instructions(Instructions2, Rest),
                     TemplateType, TemplateName, Context, Force,
                     ExistingFiles);
execute_template(Files, [{template, Input, Output} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    InputName = filename:join(filename:dirname(TemplateName), Input),
    File = load_file(Files, TemplateType, InputName),
    case write_file(Output, render(File, Context), Force) of
        ok ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, ExistingFiles);
        {error, exists} ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, [Output|ExistingFiles])
    end;
execute_template(Files, [{file, Input, Output} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    InputName = filename:join(filename:dirname(TemplateName), Input),
    File = load_file(Files, TemplateType, InputName),
    case write_file(Output, File, Force) of
        ok ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, ExistingFiles);
        {error, exists} ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, [Output|ExistingFiles])
    end;
execute_template(Files, [{dir, Name} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    case filelib:ensure_dir(filename:join(Name, "dummy")) of
        ok ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, ExistingFiles);
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction "
                   "{dir, ~s}: ~p\n", [Name, Reason])
    end;
execute_template(Files, [{copy, Input, Output} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    InputName = filename:join(filename:dirname(TemplateName), Input),
    try rebar_file_utils:cp_r([InputName ++ "/*"], Output) of
        ok ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, ExistingFiles)
    catch _:_ ->
            ?ABORT("Failed while processing template instruction "
                   "{copy, ~s, ~s}~n", [Input, Output])
    end;
execute_template(Files, [{chmod, Mod, File} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles)
  when is_integer(Mod) ->
    case file:change_mode(File, Mod) of
        ok ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, ExistingFiles);
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction "
                   "{chmod, ~b, ~s}: ~p~n", [Mod, File, Reason])
    end;
execute_template(Files, [{symlink, Existing, New} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    case file:make_symlink(Existing, New) of
        ok ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, ExistingFiles);
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction "
                   "{symlink, ~s, ~s}: ~p~n", [Existing, New, Reason])
    end;
execute_template(Files, [{cwd, Dir} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    CwdAbsPath = filename:absname(Dir),
    case filelib:ensure_dir(CwdAbsPath) of
        ok ->
            NContext = dict:store('cwd', CwdAbsPath, Context),
            ?CONSOLE("cd ~ts\n", [Dir]),
            execute_template(Files, Rest, TemplateType, TemplateName,
                             NContext, Force, ExistingFiles);
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction "
                   "{dir, ~s}: ~p\n", [Dir, Reason])
    end;
execute_template(Files, [{cmd, Commands} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    CwdDir = case dict:find(cwd, Context) of
                 error -> "";
                 {ok, Dir} -> Dir
             end,
    ?CONSOLE("~ts\n", [Commands]),
    case command(Commands, CwdDir) of
        {0, _Output} ->
            execute_template(Files, Rest, TemplateType, TemplateName,
                             Context, Force, ExistingFiles);
        {_, Error} ->
            ?ABORT("Failed while processing template instruction "
                   "{cmd, ~s}: ~p~n", [Commands, Error])
    end;
execute_template(Files, [{variables, _} | Rest], TemplateType,
                 TemplateName, Context, Force, ExistingFiles) ->
    execute_template(Files, Rest, TemplateType, TemplateName,
                     Context, Force, ExistingFiles);
execute_template(Files, [Other | Rest], TemplateType, TemplateName,
                 Context, Force, ExistingFiles) ->
    ?WARN("Skipping unknown template instruction: ~p\n", [Other]),
    execute_template(Files, Rest, TemplateType, TemplateName, Context,
                     Force, ExistingFiles).


format_time({{Y, M, D}, {HH, MM, SS}}) ->
    lists:flatten(io_lib:format("~4.10.0B-~2.10.0B-~2.10.0B ~2.10.0B:~2.10.0B:~2.10.0B",
                                [Y, M, D, HH, MM, SS])).

%% https://github.com/richcarl/eunit/blob/master/src/eunit_lib.erl
%% Replacement for os:cmd

%% TODO: Better cmd support, especially on Windows (not much tested)
%% TODO: Can we capture stderr separately somehow?

command(Cmd) ->
    command(Cmd, "").

command(Cmd, Dir) ->
    command(Cmd, Dir, []).

command(Cmd, Dir, Env) ->
    CD = if Dir =:= "" -> [];
            true -> [{cd, Dir}]
         end,
    SetEnv = if Env =:= [] -> [];
                true -> [{env, Env}]
             end,
    Opt = CD ++ SetEnv ++ [stream, exit_status, use_stdio,
                           stderr_to_stdout, in, eof],
    P = open_port({spawn, Cmd}, Opt),
    get_data(P, []).

get_data(P, D) ->
    receive
        {P, {data, D1}} ->
            get_data(P, [D1|D]);
        {P, eof} ->
            port_close(P),
            receive
                {P, {exit_status, N}} ->
                    {N, normalize(lists:flatten(lists:reverse(D)))}
            end
    end.

normalize([$\r, $\n | Cs]) ->
    [$\n | normalize(Cs)];
normalize([$\r | Cs]) ->
    [$\n | normalize(Cs)];
normalize([C | Cs]) ->
    [C | normalize(Cs)];
normalize([]) ->
    [].
