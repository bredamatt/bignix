type choice = Free of float | Uniform | Weights of (string * float) list

type t = {
  model : Model.t;
  failure : Failure.t;
  choice : choice;
  max_depth : int;
  penalty : float;
}

type step = { transition : Model.transition; cost : float }
type path = { steps : step list; cost : float }

exception Error of string

let error fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

let check_choice model = function
  | Free cost -> if cost < 0. then error "step_cost must not be negative"
  | Uniform -> ()
  | Weights weights ->
      List.iter
        (fun (action, _) ->
          if not (List.mem action (Model.actions model)) then
            error "a weight is given for `%s', which is not an action of the model" action)
        weights;
      List.iter
        (fun action ->
          match List.assoc_opt action weights with
          | None -> error "no weight is given for action `%s'" action
          | Some w when w <= 0. ->
              error "the weight of action `%s' must be positive" action
          | Some _ -> ())
        (Model.actions model)

let make ~model ~failure ~choice ~max_depth ~penalty =
  List.iter
    (fun name ->
      if not (List.mem name (Model.predicates model)) then
        error "the failure expression uses `%s', which is not a predicate of the model (it has: %s)"
          name
          (String.concat ", " (Model.predicates model)))
    (Failure.names failure);
  check_choice model choice;
  if max_depth < 1 then error "max_depth must be at least 1";
  if penalty < 0. then error "penalty must not be negative";
  { model; failure; choice; max_depth; penalty }

let model p = p.model
let max_depth p = p.max_depth
let penalty p = p.penalty
let failed p state = Failure.eval (Model.holds p.model state) p.failure

(* The cost of choosing [action] among the actions [enabled]. *)
let choice_cost choice enabled action =
  match choice with
  | Free cost -> cost
  | Uniform -> log (float_of_int (List.length enabled))
  | Weights weights ->
      let weight a = List.assoc a weights in
      let total = List.fold_left (fun sum a -> sum +. weight a) 0. enabled in
      -.log (weight action /. total)

let steps p state =
  let transitions =
    Model.step p.model state
    |> List.filter (fun (t : Model.transition) -> t.prob > 0.)
  in
  let enabled =
    List.sort_uniq compare
      (List.map (fun (t : Model.transition) -> t.action) transitions)
  in
  List.map
    (fun (t : Model.transition) ->
      {
        transition = t;
        cost = choice_cost p.choice enabled t.action -. log t.prob;
      })
    transitions

let path steps =
  { steps; cost = List.fold_left (fun sum (s : step) -> sum +. s.cost) 0. steps }

let likelihood path =
  List.fold_left (fun l s -> l *. s.transition.prob) 1. path.steps
