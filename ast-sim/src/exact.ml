open Bigraph
module Ints = Map.Make (Int)

type node = { failed : bool; edges : (Problem.step * int) list }

type graph = {
  ids : (Big.t * int) list Ints.t;  (* states by Big.key, with their ids *)
  nodes : node Ints.t;  (* by id *)
  size : int;
}

let bucket graph state =
  Option.value ~default:[] (Ints.find_opt (Big.key state) graph.ids)

(* The id of a state, adding it to the graph if it is new. *)
let intern p graph state =
  let known = bucket graph state in
  match List.find_opt (fun (s, _) -> Model.same_state s state) known with
  | Some (_, id) -> (graph, id, false)
  | None ->
      let id = graph.size in
      ( {
          ids = Ints.add (Big.key state) ((state, id) :: known) graph.ids;
          nodes =
            Ints.add id
              { failed = Problem.failed p state; edges = [] }
              graph.nodes;
          size = id + 1;
        },
        id,
        true )

(* Add the steps out of one state. Returns the states seen for the first
   time, to expand next. *)
let expand p (graph, fresh) (id, state) =
  if (Ints.find id graph.nodes).failed then (graph, fresh)
  else
    let graph, edges, fresh =
      List.fold_left
        (fun (graph, edges, fresh) (step : Problem.step) ->
          let next = step.transition.next in
          let graph, target, is_new = intern p graph next in
          ( graph,
            (step, target) :: edges,
            if is_new then (target, next) :: fresh else fresh ))
        (graph, [], fresh) (Problem.steps p state)
    in
    let node = { failed = false; edges = List.rev edges } in
    ({ graph with nodes = Ints.add id node graph.nodes }, fresh)

(* Breadth first, so a state is first seen at its least depth. States first
   seen at [max_depth] are not expanded: no run can go on from them. *)
let rec explore p ~max_states graph frontier depth =
  if graph.size > max_states then
    raise
      (Problem.Error
         (Printf.sprintf
            "the model has more than %d states: raise max_states or use mcts"
            max_states));
  if frontier = [] || depth >= Problem.max_depth p then graph
  else
    let graph, fresh = List.fold_left (expand p) (graph, []) frontier in
    explore p ~max_states graph (List.rev fresh) (depth + 1)

(* One round: extend the best known runs by one step. [best] maps a state
   id to the least cost of reaching it and the steps taken, last first. *)
let relax graph best =
  Ints.fold
    (fun id (cost, steps) acc ->
      List.fold_left
        (fun acc ((step : Problem.step), target) ->
          let cost = cost +. step.cost in
          match Ints.find_opt target acc with
          | Some (known, _) when known <= cost -> acc
          | _ -> Ints.add target (cost, step :: steps) acc)
        acc (Ints.find id graph.nodes).edges)
    best best

(* After round [d], [best] holds the least cost over runs of up to [d]
   steps. *)
let rec rounds graph best remaining =
  if remaining = 0 then best
  else
    let best' = relax graph best in
    (* A round changes [best] only by lowering a cost or adding a state. *)
    if Ints.equal (fun (c, _) (c', _) -> Float.equal c c') best best' then best
    else rounds graph best' (remaining - 1)

let solve p ~max_states =
  let state = Model.initial (Problem.model p) in
  let empty = { ids = Ints.empty; nodes = Ints.empty; size = 0 } in
  let graph, root, _ = intern p empty state in
  let graph = explore p ~max_states graph [ (root, state) ] 0 in
  let best =
    rounds graph (Ints.singleton root (0., [])) (Problem.max_depth p)
  in
  Ints.fold
    (fun id (cost, steps) found ->
      let better =
        match found with None -> true | Some (c, _) -> cost < c
      in
      if (Ints.find id graph.nodes).failed && better then Some (cost, steps)
      else found)
    best None
  |> Option.map (fun (_, steps) -> Problem.path (List.rev steps))
