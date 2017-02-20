%%%-------------------------------------------------------------------
%%% @author Juan Jose Comellas <juanjo@comellas.org>
%%% @author Mahesh Paolini-Subramanya <mahesh@aptela.com>
%%% @copyright (C) 2011 Juan Jose Comellas, Mahesh Paolini-Subramanya
%%%
%%% @doc Parse transform that automaticaly generates and exports accessors for
%%%      all records declared within a module.
%%% <p>It generates and exports the following functions:</p>
%%%
%%% <pre>
%%% get_value(field_name, Record) ->
%%%     Record#record_name.field_name.
%%%
%% set_value(field_name, Value, Record) ->
%%     Record#record_name{field_name = Value}.
%%
%%% records() ->
%%%     [record_name1, record_name2, ...].
%%%
%%% fields(record_name) ->
%%%     [field_name1, field_name2, ...].
%%%
%%% new_record(record_name) ->
%%%     #record_name{}.
%%% </pre>
%%%
%%% <p>It runs at compile time using following preprocessor directive:</p>
%%%
%%% <pre>
%%% -compile({parse_transform, dynarec}).
%%% </pre>
%%%
%%% <p>All those functions are added to the module that uses the directive.</p>
%%% <p>Be aware that dynarec.erl must be compiled before any module that uses it.</p>
%%% @end
%%%
%%% This source file is subject to the New BSD License. You should have received
%%% a copy of the New BSD license with this software. If not, it can be
%%% retrieved from: http://www.opensource.org/licenses/bsd-license.php
%%-------------------------------------------------------------------
-module(dynarec).
-author('Juan Jose Comellas <juanjo@comellas.org>').
-author('Mahesh Paolini-Subramanya <mahesh@aptela.com>').

-export([parse_transform/2]).

parse_transform(Forms, _Options) ->
    Records = [Record || {attribute, _, record, _} = Record <- Forms],
    Tuples = lists:flatten(lists:map(fun get_tuples/1, Records)),
    NewForms = lists:reverse([gen_new_record(Tuples)  |
                             [gen_records(Tuples)     |
                             [gen_field_names(Tuples) |
                             [gen_field_types(Tuples) |
                             [gen_field_getter(Tuples)|
                             [gen_setter(Tuples)      | lists:reverse(Forms)]]]]]]),
    add_exports(NewForms).


%% @doc Returns a list of pairs <code>{record_name, field_name}</code> for each
%%      <code>field_name</code> in the record.
get_tuples({attribute,_,record, {Name, Fields}}) ->
    [{Name, get_field_name(Field)} || Field <- Fields].

get_field_name({record_field, _, {atom, _, FieldName}, _Default}) ->
    FieldName;
get_field_name({record_field, _, {atom, _, FieldName}}) ->
    FieldName;
get_field_name({typed_record_field, RecordField, _Typed}) ->
    %io:format("~p ~p~n",[RecordField, _Typed]),
    {get_field_name(RecordField), get_type(_Typed)}.

get_type({type,_,tuple,L})     -> {tuple,tuple(L)};
get_type({type,_,Type,[]})     -> Type;
get_type({user_type,_,Type,[]})-> Type;
get_type({type,_,union,Union}) -> {union, union(Union)}.

union(L) ->
    lists:foldr(fun({K,_,V},A)      -> [{K,V}|A];
                   ({type,_,T,[]},A) -> [T|A];
                   ({user_type,_,T,[]},A) -> [T|A] 
                end,[],L).

list(L) -> lists:foldr(fun({type,_,range,R},A) -> [range(R)|A]end,[],L).
tuple(L) -> lists:foldr(fun({type,_,range,R},A) -> [range(R)|A]end,[],L).

range([{integer,_,Start},{integer,_,End}]) -> {range,integer,{Start,End}}.

%% @doc Generates the field_getter function for all {record, field} tuples.
%% <p>It returns code in the syntactic tree form. You can use
%% <code>erl_scan:tokens/3</code> and <code>erl_parse:parse_form/1</code> to
%% see how it parses different strings.</p>
gen_field_getter(Tuples) ->
    List = lists:foldl(fun({Record, {Field,_}}, Acc) ->
                               [gen_field_getter_clause(Record, Field) | Acc];
                          ({Record, Field}, Acc) ->
                               [gen_field_getter_clause(Record, Field) | Acc]                            
                       end, [], Tuples),
    {function, 0, get_value, 2, lists:reverse(List)}.

%%  erl_parse:parse_form(element(2,element(2,
%%      erl_scan:tokens([],"get_position(field_name, Record) -> #record_name.field_name.\n",0)))).

%% @doc Generates each clause of the field_getter function with the form:
%% <pre>
%% get_value(field_name, Record) ->
%%     Record#record_name.field_name.
%% </pre>
%% <p>It returns code in the syntactic tree form. I obtained the form of the
%% clause with the following expression on the Erlang shell:</p>
%% <pre>
%%  erl_parse:parse_form(element(2,element(2,
%%      erl_scan:tokens([],"get_value(field_name, Record) -> Record#record_name.field_name.\n",0)))).
%% </pre>
%% <p>It first tokenizes the string as code, and then builds the syntactic tree.</p>

% {ok,{function,0,get_value,2,
%               [{clause,0,
%                        [{atom,0,field_name},{var,0,'Record'}],
%                        [],
%                        [{record_field,0,
%                                       {var,0,'Record'},
%                                       record_name,
%                                       {atom,0,field_name}}]}]}}
gen_field_getter_clause(RecordName, FieldName) ->
    {clause, 0,
     %% (field_name, Record)
     [{atom, 0, FieldName}, {match, 0, {var, 0, 'Record'}, {record, 0, RecordName, []}}],
     %% guard
     [],
     %% Record#record_name.field_name
     [{record_field, 0, {var, 0, 'Record'}, RecordName, {atom, 0, FieldName}}]}.

%% @doc Generates the setter function for all {record,field} tuples.
%% <p>It returns code in the syntactic tree form. You can use
%% <code>erl_scan:tokens/3</code> and <code>erl_parse:parse_form/1</code> to
%% see how it parses different strings.</p>
gen_setter(Tuples) ->
    List = lists:foldl(fun({Record, {Field,_}}, Acc) ->
                               [gen_setter_clause(Record, Field) | Acc];
                          ({Record, Field}, Acc) ->
                               [gen_setter_clause(Record, Field) | Acc]
                       end, [], Tuples),
    {function, 0, set_value, 3, lists:reverse(List)}.


%% @doc Generates each clause of the setter function with the form:
%% <pre>
%% set_value(field_name, Value, Record)  ->
%%     Record#record_name{field_name = Value}.
%% </pre>
%% <p>It returns code in the syntactic tree form. I obtained the form of the
%% clause with the following expression on the Erlang shell:</p>
%% <pre>
%%  erl_parse:parse_form(element(2,element(2,
%%      erl_scan:tokens([],"set_value(field_name, Value, Record) -> "
%%                         "Record#record_name{field_name = Value}.\n",0)))).
%% </pre>
%% <p>It first tokenizes the string as code, and then builds the syntactic tree.</p>
gen_setter_clause(RecordName, FieldName) ->
    {clause, 0,
     %% (field_name, Value, Record)
     [{atom, 0, FieldName}, {var, 0, 'Value'}, {match, 0, {var, 0, 'Record'}, {record, 0, RecordName, []}}],
     %% guard
     [],
     %% Record#record_name{field_name = Value}
     [{record, 0, {var, 0, 'Record'}, RecordName, [{record_field, 0, {atom, 0, FieldName}, {var, 0, 'Value'}}]}]}.


%% @doc Generates the <code>records/0</code> function
%% <p>It returns code in the syntactic tree form, but we generate it using
%% <code>erl_parse:parse_form/1</code> over the generated list of tokens.</p>
%% <p>It is a bit cryptic because of the Erlang token format, but you can try
%% the following expression in the Erlang shell to see what it generates and
%% and how to build the token list manually:</p>
%% <pre>
%% erl_scan:tokens([], "records() -> [record_name_1, record_name_2, ...].\n", 0).
%% </pre>
gen_records(Tuples) ->
    ReversedPrefix = [{'->', 0}, {')', 0}, {'(', 0}, {atom, 0, records}],
    %% Keep only unique names.
    Records = sets:to_list(sets:from_list([Name || {Name, _} <- Tuples])),
    %% We're generating the expression backwards and then reverse it.
    {ok, Result} = erl_parse:parse_form(lists:reverse([{dot, 0} | gen_reversed_atom_list(Records, ReversedPrefix)])),
    Result.



%% @doc Generates the <code>fields/1</code> function that returns the list of
%%      field names corresponding to a record.
%% <p>It returns code in the syntactic tree form, but we generate it using
%% <code>erl_parse:parse_form/1</code> over the generated list of tokens.</p>
%% <p>It is a bit cryptic because of the Erlang token format, but you can try
%% the following expression in the Erlang shell to see what it generates and
%% and how to build the token list manually:</p>
%% <pre>
%% erl_scan:tokens([], "fields(Record) -> [value, othervalue, etc].\n", 0).
%% </pre>
gen_field_types(Tuples) ->
    %% Group fields by record
    %% e.g. [{site, id}, {site, country}, {item, id}, {item, price}] --> [{site, [id, country]}, {item, [id, price]}]
    Grouped = dict:to_list(lists:foldl(fun({Name, X}, Dict) -> 
                                            dict:append(Name, X, Dict)                                          
                                       end, dict:new(), Tuples)),

    List = [{dot, 0} | tl(lists:foldl(fun({Record, Fields}, Acc) -> 
                                        gen_reversed_field_types_tokens(Record, Fields) ++ Acc 
                                      end, [], Grouped))],
    {ok, Result} = erl_parse:parse_form(lists:reverse(List)),
    Result.

gen_reversed_field_types_tokens(Record, Fields) ->
    %% Reversed tokens for the expression: fields(Record) ->
    ReversedPrefix = [{'->', 0}, {')', 0}, {atom, 0, Record}, {'(', 0}, {atom, 0, field_types}],
    [{';', 0} | gen_reversed_atom_list(Fields, ReversedPrefix)].


gen_field_names(Tuples) ->
    %% Group fields by record
    %% e.g. [{site, id}, {site, country}, {item, id}, {item, price}] --> [{site, [id, country]}, {item, [id, price]}]
    Grouped = dict:to_list(lists:foldl(fun({Name, {Field,_}}, Dict) -> 
                                            dict:append(Name, Field, Dict);
                                          ({Name, Field}, Dict) -> 
                                            dict:append(Name, Field, Dict)  
                                       end, dict:new(), Tuples)),

    List = [{dot, 0} | tl(lists:foldl(fun({Record, Fields}, Acc) -> 
                                        gen_reversed_field_names_tokens(Record, Fields) ++ Acc 
                                      end, [], Grouped))],
    {ok, Result} = erl_parse:parse_form(lists:reverse(List)),
    Result.

gen_reversed_field_names_tokens(Record, Fields) ->
    %% Reversed tokens for the expression: fields(Record) ->
    ReversedPrefix = [{'->', 0}, {')', 0}, {atom, 0, Record}, {'(', 0}, {atom, 0, field_names}],
    [{';', 0} | gen_reversed_atom_list(Fields, ReversedPrefix)].

%% @doc Generates the new_record function
%%
%% <p>It returns code in the syntactic tree form, but we generate it using
%% <code>erl_parse:parse_form/1</code> over the generated list of tokens.</p>
%% <p>It is a bit cryptic because of the Erlang token format, but you can try
%% the following expression in the Erlang shell to see what it generates and
%% and how to build the token list manually:</p>
%% <pre>
%%  > erl_scan:tokens([],"new_record(record_name) -> #record_name{}.\n",0).
%% </pre>
gen_new_record(Tuples) ->
    Names = sets:to_list(sets:from_list([Name || {Name, _} <- Tuples])),
    List = lists:foldl(fun(RecordName, Acc) -> [gen_new_record_clause(RecordName) | Acc] end, [], Names),
    {function, 0, new_record, 1, lists:reverse(List)}.

gen_new_record_clause(RecordName) ->
    {clause, 0, [{atom, 0, RecordName}], [], [{record, 0, RecordName, []}]}.

%% @doc Adds the getter and setter functions to the list of exported functions
add_exports(Forms) ->
    case lists:keysearch(export, 3, Forms) of
        {value, {attribute, N, export, Exports}} ->
            lists:keyreplace(export, 3, Forms,
                {attribute, N, export, [{records, 0}, {field_names, 1}, {field_types, 1},
                {new_record, 1}, {get_value, 2}, {set_value, 3} | Exports]});
        false -> Forms
    end.

%% gen_atom_list(Names, Acc) ->
%%     lists:reverse(gen_reversed_atom_list(Names, Acc)).

gen_reversed_atom_list([Head | Tail], Acc) ->
    gen_reversed_atom_list('[', [Head | Tail], Acc).

gen_reversed_atom_list(Terminator, [Head | Tail], Acc) ->
    gen_reversed_atom_list(',', Tail, [{atom, 0, Head}, {Terminator, 0} | Acc]);
gen_reversed_atom_list(_Terminator, [], Acc) ->
    [{']', 0} | Acc].

