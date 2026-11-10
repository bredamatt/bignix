open Bigraph
open Big_frontend

(* MiniCARD is also bigrapher's default matching engine. *)
module Matcher = Solver.Make_SAT (Solver.MC)
module ABRS = Abrs.Make (Matcher)

exception Error of string

let error fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

module Store =
  Store.Make
    (ABRS)
    (struct
      let parse_react name lhs rhs ?(conds = []) label eta _loc =
        match label with
        | `P label -> ABRS.parse_react_err ~name ~lhs ~rhs ~conds label eta
        | `F _ -> Error (Printf.sprintf "rule %s is not in any action" name)
        | `E () ->
            Error (Printf.sprintf "rule %s has no weight: use -[ w ]->" name)
    end)

type const = Int of int | Float of float | String of string

type t = {
  init : Big.t;
  priorities : ABRS.p_class list;
  preds : (string * Big.t) list;
}

type transition = {
  action : string;
  prob : float;
  rules : string list;
  next : Big.t;
}

let same_state = Matcher.equal

(* ---- Loading ---- *)

let ast_const (name, value) =
  let d_exp =
    match value with
    | Int v -> Ast.ENum (Num_int_val (v, Loc.dummy_loc))
    | Float v -> Ast.ENum (Num_float_val (v, Loc.dummy_loc))
    | String v -> Ast.EStr (Str_val (v, Loc.dummy_loc))
  in
  let d = { Ast.d_id = name; d_exp; d_loc = Loc.dummy_loc } in
  match value with
  | Int _ -> Ast.Cint d
  | Float _ -> Ast.Cfloat d
  | String _ -> Ast.Cstr d

(* A message that starts with the place in the file it is about. *)
let located loc print = Format.asprintf "@[<v>%a%t@]" Loc.print_loc loc print

let parse file =
  let ch = try open_in file with Sys_error msg -> error "%s" msg in
  let lexbuf = Lexing.from_channel ch in
  Lexing.set_filename lexbuf file;
  Stdlib.Fun.protect
    ~finally:(fun () -> close_in_noerr ch)
    (fun () ->
      try Parser.model Lexer.token lexbuf with
      | Parser.Error ->
          let loc = Loc.curr lexbuf in
          error "%s"
            (located loc (fun fmt ->
                 Format.fprintf fmt "Syntax error near token `%s'"
                   (Lexing.lexeme lexbuf)))
      | Lexer.ERROR (e, loc) ->
          error "%s" (located loc (fun fmt -> Lexer.report_error fmt "" e))
      | Sys_error msg -> error "%s: %s" file msg)

let load ?(consts = []) file =
  let ast = parse file in
  (match fst ast.Ast.model_rs.dbrs_type with
  | Rs.ABRS -> ()
  | typ ->
      error "%s: this is a %s. ast-sim needs an action BRS (begin abrs)." file
        (Rs.string_of_rs_type typ));
  try
    let env = Store.init_env false (List.map ast_const consts) in
    let init, priorities, preds, _ = Store.eval_model false ast env in
    {
      init;
      priorities;
      preds = List.map (fun ((name, _reward), big) -> (name, big)) preds;
    }
  with
  | Store.ERROR (e, loc) ->
      error "%s" (located loc (fun fmt -> Store.report_error_aux fmt e))
  | Place.NOT_PRIME ->
      error "%s: the parameter of a reaction rule is not prime." file

(* ---- Stepping ---- *)

let rules_of = function ABRS.P_class rules | ABRS.P_rclass rules -> rules

let distinct names =
  List.fold_left
    (fun acc name -> if List.mem name acc then acc else name :: acc)
    [] names
  |> List.rev

let actions m =
  List.concat_map rules_of m.priorities |> List.map ABRS.action |> distinct

let predicates m = List.map fst m.preds

let holds m state name =
  Matcher.occurs ~target:state ~pattern:(List.assoc name m.preds)

let initial m = fst (ABRS.rewrite m.init m.priorities)

(* Add up the outcomes of one action that reach the same state. *)
let merge transitions =
  List.fold_left
    (fun acc t ->
      match List.partition (fun t' -> same_state t.next t'.next) acc with
      | [ same ], others ->
          { same with prob = same.prob +. t.prob; rules = same.rules @ t.rules }
          :: others
      | _ -> t :: acc)
    [] transitions
  |> List.rev

(* The outcomes of one action. ABRS.step is called with the rules of a
   single action: given several actions, it merges transitions of different
   actions that reach the same state, which gives wrong probabilities. *)
let step_action m state rules =
  let outcomes, _ = ABRS.step state rules in
  List.map
    (fun (next, (action, _reward, prob), rules) ->
      {
        action;
        prob;
        rules = List.map ABRS.name rules;
        next = fst (ABRS.rewrite next m.priorities);
      })
    outcomes
  |> merge

let step m state =
  let step_class rules =
    distinct (List.map ABRS.action rules)
    |> List.concat_map (fun action ->
           List.filter (fun r -> ABRS.action r = action) rules
           |> step_action m state)
  in
  let rec scan = function
    | [] -> []
    | ABRS.P_rclass _ :: classes -> scan classes
    | ABRS.P_class rules :: classes -> (
        match step_class rules with [] -> scan classes | found -> found)
  in
  scan m.priorities
