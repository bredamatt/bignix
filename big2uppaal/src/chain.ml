(* A system with probabilistic reaction rules (begin pbrs), as the Markov
   chain it defines: one state for each bigraph the system can reach. *)

open Bigraph
open Big_frontend

module PBRS = Pbrs.Make (Topo.Matcher)

module Store =
  Store.Make
    (PBRS)
    (struct
      let parse_react name lhs rhs ?(conds = []) label eta _ =
        match label with
        | `F p -> PBRS.parse_react_err ~name ~lhs ~rhs ~conds p eta
        | `E () | `P _ -> Error (Printf.sprintf "rule %s has no probability: write -[p]->" name)
    end)

type t = {
  name : string;  (** The initial bigraph: big NAME = ... *)
  states : int;  (** State 0 is the initial bigraph. *)
  trans : (int * int * float) list;
      (** From, to, probability. Sorted; those that leave one state sum to 1. *)
  labels : (string * int list) list;
      (** For each predicate of the model, in the order of the file, the
          states in which it holds. *)
}

(* [load ~consts ~max file ~init] is the chain of the system in [file]
   started from [big init = ...] instead of the bigraph the file names, with
   the numeric declarations in [consts] replaced. *)
let load ?(consts = []) ?(max = 10000) file ~init =
  let ast = Topo.parse file in
  let rs = ast.Ast.model_rs in
  (match fst rs.dbrs_type with
  | Rs.PBRS -> ()
  | _ ->
      Topo.error
        "%s is not a pbrs: only a system with probabilities (begin pbrs) becomes a Markov chain"
        file);
  let decs, loc = ast.model_decs and init_loc = snd rs.dbrs_init in
  let ast =
    { ast with
      model_decs = (Topo.override consts decs, loc);
      model_rs = { rs with dbrs_init = (Ast.Init (init, init_loc), init_loc) } }
  in
  let env = Store.init_env false [] in
  let s0, priorities, predicates, _ =
    try Store.eval_model false ast env
    with Store.ERROR (e, loc) ->
      Topo.error "%s" (Topo.located loc (fun fmt -> Store.report_error_aux fmt e))
  in
  let graph =
    try fst (PBRS.bfs ~s0 ~priorities ~predicates ~max (fun _ _ -> ()))
    with PBRS.MAX _ -> Topo.error "%s has more than %d states (--max-states)" init max
  in
  {
    name = init;
    states = Base.H_int.length graph.v;
    trans =
      Base.H_int.fold (fun src (dst, p, _) acc -> (src, dst, p) :: acc) graph.e []
      |> List.sort compare;
    labels =
      List.map
        (fun (pred, _) ->
          (fst pred, List.sort_uniq compare (Base.H_predicate.find_all graph.l pred)))
        predicates;
  }

(* The states that one step from [s] can reach. *)
let next t s = List.filter_map (fun (src, dst, _) -> if src = s then Some dst else None) t.trans

(* The number of steps of the longest run, or None if a run can go on for
   ever: some state can be reached from itself. *)
let longest t =
  let exception Cycle in
  let known = Hashtbl.create t.states in
  let rec depth path s =
    match Hashtbl.find_opt known s with
    | Some d -> d
    | None ->
        if List.mem s path then raise Cycle;
        let d = List.fold_left (fun acc n -> Stdlib.max acc (1 + depth (s :: path) n)) 0 (next t s) in
        Hashtbl.replace known s d;
        d
  in
  try Some (depth [] 0) with Cycle -> None
