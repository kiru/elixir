-module(elixir_fn).
-export([translate/3, capture/3, expand/3]).
-import(elixir_errors, [compile_error/3, compile_error/4]).
-include("elixir.hrl").

translate(Meta, Clauses, S) ->
  Transformer = fun({ '->', CMeta, [ArgsWithGuards, Expr] }, Acc) ->
    { Args, Guards } = elixir_clauses:extract_splat_guards(ArgsWithGuards),
    elixir_clauses:clause(?line(CMeta), fun translate_fn_match/2, Args,
                          Expr, Guards, elixir_scope:mergec(S, Acc))
  end,

  { TClauses, NS } = lists:mapfoldl(Transformer, S, Clauses),
  Arities = [length(Args) || { clause, _Line, Args, _Guards, _Exprs } <- TClauses],

  case length(lists:usort(Arities)) of
    1 ->
      { { 'fun', ?line(Meta), { clauses, TClauses } }, elixir_scope:mergec(S, NS) };
    _ ->
      compile_error(Meta, S#elixir_scope.file,
                    "cannot mix clauses with different arities in function definition")
  end.

translate_fn_match(Arg, S) ->
  { TArg, TS } = elixir_translator:translate_many(Arg, S#elixir_scope{extra=fn_match}),
  { TArg, TS#elixir_scope{extra=S#elixir_scope.extra} }.

%% Expansion

expand(Meta, Clauses, E) when is_list(Clauses) ->
  Transformer = fun(Clause, Acc) ->
    { EClause, EC } =
      elixir_exp_clauses:clause(Meta, fn, fun elixir_exp:expand_many/2, Clause, Acc),
    { EClause, elixir_env:mergec(E, EC) }
  end,
  { EClauses, _ } = lists:mapfoldl(Transformer, E, Clauses),
  { { fn, Meta, EClauses }, E }.

%% Capture

capture(Meta, { '/', _, [{ { '.', _, [_, F] } = Dot, RequireMeta , [] }, A] }, E) when is_atom(F), is_integer(A) ->
  Args = [{ '&', [], [X] } || X <- lists:seq(1, A)],
  capture_require(Meta, { Dot, RequireMeta, Args }, E, true);

capture(Meta, { '/', _, [{ F, _, C }, A] }, E) when is_atom(F), is_integer(A), is_atom(C) ->
  ImportMeta =
    case lists:keyfind(import_fa, 1, Meta) of
      { import_fa, { Receiver, Context } } ->
        lists:keystore(context, 1,
          lists:keystore(import, 1, Meta, { import, Receiver }),
          { context, Context }
        );
      false -> Meta
    end,
  Args = [{ '&', [], [X] } || X <- lists:seq(1, A)],
  capture_import(Meta, { F, ImportMeta, Args }, E, true);

capture(Meta, { { '.', _, [_, Fun] }, _, Args } = Expr, E) when is_atom(Fun), is_list(Args) ->
  capture_require(Meta, Expr, E, is_sequential_and_not_empty(Args));

capture(Meta, { { '.', _, [_] }, _, Args } = Expr, E) when is_list(Args) ->
  do_capture(Meta, Expr, E, false);

capture(Meta, { '__block__', _, [Expr] }, E) ->
  capture(Meta, Expr, E);

capture(Meta, { '__block__', _, _ } = Expr, E) ->
  Message = "invalid args for &, block expressions are not allowed, got: ~ts",
  compile_error(Meta, E#elixir_env.file, Message, ['Elixir.Macro':to_string(Expr)]);

capture(Meta, { Atom, _, Args } = Expr, E) when is_atom(Atom), is_list(Args) ->
  capture_import(Meta, Expr, E, is_sequential_and_not_empty(Args));

capture(Meta, { Left, Right }, E) ->
  capture(Meta, { '{}', Meta, [Left, Right] }, E);

capture(Meta, List, E) when is_list(List) ->
  do_capture(Meta, List, E, is_sequential_and_not_empty(List));

capture(Meta, Arg, E) ->
  invalid_capture(Meta, Arg, E).

capture_import(Meta, { Atom, ImportMeta, Args } = Expr, E, Sequential) ->
  Res = Sequential andalso
        elixir_dispatch:import_function(ImportMeta, Atom, length(Args), E),
  handle_capture(Res, Meta, Expr, E, Sequential).

capture_require(Meta, { { '.', _, [Left, Right] }, RequireMeta, Args } = Expr, E, Sequential) ->
  { Mod, EE } = elixir_exp:expand(Left, E),
  Res = Sequential andalso is_atom(Mod) andalso
        elixir_dispatch:require_function(RequireMeta, Mod, Right, length(Args), EE),
  handle_capture(Res, Meta, Expr, EE, Sequential).

handle_capture({ local, Fun, Arity }, _Meta, _Expr, _E, _Sequential) ->
  { local, Fun, Arity };
handle_capture({ remote, Receiver, Fun, Arity }, Meta, _Expr, E, _Sequential) ->
  Tree = { { '.', [], [erlang, make_fun] }, Meta, [Receiver, Fun, Arity] },
  { expanded, Tree, E };
handle_capture(false, Meta, Expr, E, Sequential) ->
  do_capture(Meta, Expr, E, Sequential).

do_capture(Meta, Expr, E, Sequential) ->
  case do_escape(Expr, E, []) of
    { _, [] } when not Sequential ->
      invalid_capture(Meta, Expr, E);
    { EExpr, EDict } ->
      EVars = validate(Meta, EDict, 1, E),
      Fn = { fn, Meta, [{ '->', Meta, [EVars, EExpr]}]},
      { expanded, Fn, E#elixir_env{macro_counter=E#elixir_env.macro_counter+1} }
  end.

invalid_capture(Meta, Arg, E) ->
  Message = "invalid args for &, expected an expression in the format of &Mod.fun/arity, "
            "&local/arity or a capture containing at least one argument as &1, got: ~ts",
  compile_error(Meta, E#elixir_env.file, Message, ['Elixir.Macro':to_string(Arg)]).

validate(Meta, [{ Pos, Var }|T], Pos, E) ->
  [Var|validate(Meta, T, Pos + 1, E)];

validate(Meta, [{ Pos, _ }|_], Expected, E) ->
  compile_error(Meta, E#elixir_env.file, "capture &~B cannot be defined without &~B", [Pos, Expected]);

validate(_Meta, [], _Pos, _E) ->
  [].

do_escape({ '&', _, [Pos] }, #elixir_env{macro_counter=Counter}, Dict) when is_integer(Pos), Pos > 0 ->
  Var = { list_to_atom([$x, $@+Pos]), [{ counter, Counter }], elixir_fn },
  { Var, orddict:store(Pos, Var, Dict) };

do_escape({ '&', Meta, [Pos] }, E, _Dict) when is_integer(Pos) ->
  compile_error(Meta, E#elixir_env.file, "capture &~B is not allowed", [Pos]);

do_escape({ '&', Meta, _ } = Arg, E, _Dict) ->
  Message = "nested captures via & are not allowed: ~ts",
  compile_error(Meta, E#elixir_env.file, Message, ['Elixir.Macro':to_string(Arg)]);

do_escape({ Left, Meta, Right }, E, Dict0) ->
  { TLeft, Dict1 }  = do_escape(Left, E, Dict0),
  { TRight, Dict2 } = do_escape(Right, E, Dict1),
  { { TLeft, Meta, TRight }, Dict2 };

do_escape({ Left, Right }, E, Dict0) ->
  { TLeft, Dict1 }  = do_escape(Left, E, Dict0),
  { TRight, Dict2 } = do_escape(Right, E, Dict1),
  { { TLeft, TRight }, Dict2 };

do_escape(List, E, Dict) when is_list(List) ->
  do_escape_list(List, E, Dict, []);

do_escape(Other, _E, Dict) ->
  { Other, Dict }.

do_escape_list([H|T], E, Dict, Acc) ->
  { TH, TDict } = do_escape(H, E, Dict),
  do_escape_list(T, E, TDict, [TH|Acc]);

do_escape_list([], _E, Dict, Acc) ->
  { lists:reverse(Acc), Dict }.

is_sequential_and_not_empty([])   -> false;
is_sequential_and_not_empty(List) -> is_sequential(List, 1).

is_sequential([{ '&', _, [Int] }|T], Int) ->
  is_sequential(T, Int + 1);
is_sequential([], _Int) -> true;
is_sequential(_, _Int) -> false.
