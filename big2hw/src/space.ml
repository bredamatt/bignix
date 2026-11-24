(* Every state the model can reach, as bigrapher full computes them. *)

open Bigraph

type t = {
  states : Bg.t array;  (** State 0 is the initial bigraph. *)
  next : int list array;  (** The states one reaction leads to. *)
  urgent : bool array;
      (** A rule of a class that acts first can fire here, so no other rule can. *)
  labels : (string * int list) list;
      (** Each predicate of the model, and the states it holds in. *)
}

let build ?(max = 10000) (m : Bg.model) =
  let graph =
    try
      fst
        (Bg.PBRS.bfs ~s0:m.init ~priorities:m.priorities ~predicates:m.predicates ~max
           (fun _ _ -> ()))
    with Bg.PBRS.MAX _ -> Bg.error "the model has more than %d states" max
  in
  let n = Base.H_int.length graph.v in
  let numbered = Base.H_int.fold (fun _ (i, b) acc -> (i, b) :: acc) graph.v [] in
  let edges = Base.H_int.fold (fun src (dst, _, rules) acc -> (src, dst, rules) :: acc) graph.e [] in
  (* The rules of every class but the last. *)
  let first =
    match List.rev m.priorities with
    | [] -> []
    | _ :: before ->
        List.concat_map (function Bg.PBRS.P_class rs | Bg.PBRS.P_rclass rs -> rs) before
        |> List.map Bg.PBRS.name
  in
  (* An edge made by several rules is labelled "a | b". *)
  let names rules = List.map String.trim (String.split_on_char '|' rules) in
  let from i = List.filter (fun (src, _, _) -> src = i) edges in
  {
    states = Array.init n (fun i -> Bg.of_big (List.assoc i numbered));
    next = Array.init n (fun i -> List.sort_uniq compare (List.map (fun (_, dst, _) -> dst) (from i)));
    urgent =
      Array.init n (fun i ->
          List.exists (fun (_, _, rules) -> List.exists (fun r -> List.mem r first) (names rules)) (from i));
    labels =
      List.map
        (fun (pred, _) -> (fst pred, List.sort_uniq compare (Base.H_predicate.find_all graph.l pred)))
        m.predicates;
  }
