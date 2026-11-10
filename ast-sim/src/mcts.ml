type config = { iterations : int; exploration : float; seed : int }
type result = { best : Problem.path option; failures : int }

(* A state in the search tree. [children.(i)] is what is known about taking
   [steps.(i)]. *)
type node = {
  failed : bool;
  steps : Problem.step array;
  visits : int;
  children : child array;
}

and child = {
  count : int;  (* runs that took this step *)
  mean : float;  (* their mean value, from this step on *)
  sub : node option;  (* the state it leads to, once visited *)
}

(* How a run ended, seen from some state on it. [value] is minus the cost
   from that state on, with the penalty if the run did not fail. [tail] is
   the steps from that state to the failure. *)
type run = { value : float; tail : Problem.step list option }

let lost p = { value = -.Problem.penalty p; tail = None }
let won = { value = 0.; tail = Some [] }

let after (step : Problem.step) run =
  {
    value = run.value -. step.cost;
    tail = Option.map (fun steps -> step :: steps) run.tail;
  }

let make_node p state =
  let failed = Problem.failed p state in
  let steps =
    if failed then [||] else Array.of_list (Problem.steps p state)
  in
  {
    failed;
    steps;
    visits = 0;
    children =
      Array.make (Array.length steps) { count = 0; mean = 0.; sub = None };
  }

let pick rng list = List.nth list (Random.State.int rng (List.length list))

(* A random step: an action picked evenly, then one of its outcomes picked
   by probability. *)
let sample rng (steps : Problem.step list) =
  let action (s : Problem.step) = s.transition.action in
  let chosen = pick rng (List.sort_uniq compare (List.map action steps)) in
  let outcomes = List.filter (fun s -> action s = chosen) steps in
  let rec draw x = function
    | [ last ] -> last
    | (s : Problem.step) :: rest ->
        if x < s.transition.prob then s else draw (x -. s.transition.prob) rest
    | [] -> assert false
  in
  draw (Random.State.float rng 1.) outcomes

(* Finish a run with random steps. *)
let rec rollout p rng state depth =
  if Problem.failed p state then won
  else if depth >= Problem.max_depth p then lost p
  else
    match Problem.steps p state with
    | [] -> lost p
    | steps ->
        let step = sample rng steps in
        after step (rollout p rng step.transition.next (depth + 1))

(* The step to try next: one not tried yet, or else the one with the best
   upper confidence bound. *)
let select exploration node =
  let children = Array.to_list (Array.mapi (fun i c -> (i, c)) node.children) in
  match List.find_opt (fun (_, c) -> c.count = 0) children with
  | Some (i, _) -> i
  | None ->
      let means = List.map (fun (_, c) -> c.mean) children in
      let lo = List.fold_left min infinity means
      and hi = List.fold_left max neg_infinity means in
      let scaled mean = if hi > lo then (mean -. lo) /. (hi -. lo) else 0. in
      let bound c =
        scaled c.mean
        +. exploration
           *. sqrt (log (float_of_int node.visits) /. float_of_int c.count)
      in
      List.fold_left
        (fun (best, best_bound) (i, c) ->
          let b = bound c in
          if b > best_bound then (i, b) else (best, best_bound))
        (0, neg_infinity) children
      |> fst

(* One run through the tree. Returns the tree with the run recorded. *)
let rec simulate p config rng node depth =
  let visited = { node with visits = node.visits + 1 } in
  if node.failed then (visited, won)
  else if depth >= Problem.max_depth p || Array.length node.steps = 0 then
    (visited, lost p)
  else
    let i = select config.exploration node in
    let step = node.steps.(i) and child = node.children.(i) in
    let sub, rest =
      match child.sub with
      | Some sub -> simulate p config rng sub (depth + 1)
      | None ->
          let next = step.transition.next in
          ( { (make_node p next) with visits = 1 },
            rollout p rng next (depth + 1) )
    in
    let run = after step rest in
    let count = child.count + 1 in
    let mean = child.mean +. ((run.value -. child.mean) /. float_of_int count) in
    let children =
      Array.mapi
        (fun j c -> if j = i then { count; mean; sub = Some sub } else c)
        node.children
    in
    ({ visited with children }, run)

let better (path : Problem.path) = function
  | Some (best : Problem.path) when best.cost <= path.cost -> Some best
  | _ -> Some path

let search p config =
  let rng = Random.State.make [| config.seed |] in
  let root = make_node p (Model.initial (Problem.model p)) in
  let rec loop root result remaining =
    if remaining = 0 then result
    else
      let root, run = simulate p config rng root 0 in
      let result =
        match run.tail with
        | None -> result
        | Some steps ->
            {
              best = better (Problem.path steps) result.best;
              failures = result.failures + 1;
            }
      in
      loop root result (remaining - 1)
  in
  loop root { best = None; failures = 0 } config.iterations
