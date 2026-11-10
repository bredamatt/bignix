type result = {
  check : Config.check;
  best : Problem.path option;
  failures : int option;
}

let run_check (config : Config.t) model (check : Config.check) =
  let problem =
    try
      Problem.make ~model ~failure:check.failure ~choice:config.choice
        ~max_depth:config.max_depth ~penalty:config.penalty
    with Problem.Error msg ->
      raise (Problem.Error (Printf.sprintf "check %s: %s" check.id msg))
  in
  match config.solver with
  | Exact { max_states } ->
      { check; best = Exact.solve problem ~max_states; failures = None }
  | Mcts mcts ->
      let found = Mcts.search problem mcts in
      { check; best = found.best; failures = Some found.failures }

let run (config : Config.t) =
  let model = Model.load ~consts:config.consts config.model in
  List.map (run_check config model) config.checks

let solver_line = function
  | Config.Exact _ -> "exact"
  | Config.Mcts m ->
      Printf.sprintf "mcts, %d runs for each check, seed %d" m.iterations m.seed

(* The exact search proves that no run fails. mcts only did not find one. *)
let verdict (config : Config.t) result =
  match (result.best, config.solver) with
  | Some _, _ -> "reached"
  | None, Config.Exact _ -> "not reachable"
  | None, Config.Mcts _ -> "not found"

(* The cells of one row of the table. *)
let row config result =
  let likelihood, steps =
    match result.best with
    | Some path ->
        ( Printf.sprintf "%g" (Problem.likelihood path),
          string_of_int (List.length path.steps) )
    | None -> ("-", "-")
  in
  [
    result.check.id;
    verdict config result;
    likelihood;
    steps;
    result.check.description;
  ]

(* Lines with the cells of each column padded to the same width. *)
let table rows =
  let width i =
    List.fold_left (fun w row -> max w (String.length (List.nth row i))) 0 rows
  in
  let widths = List.mapi (fun i _ -> width i) (List.hd rows) in
  List.map
    (fun row ->
      List.map2 (fun w cell -> Printf.sprintf "%-*s" w cell) widths row
      |> String.concat "  " |> String.trim)
    rows

let step_line i (step : Problem.step) =
  let t = step.transition in
  Printf.sprintf "  %2d. %s -> %s   p = %g" (i + 1) t.action
    (String.concat ", " t.rules)
    t.prob

(* The run found for one check, or nothing if there is none. *)
let detail result =
  match result.best with
  | None -> []
  | Some path ->
      let failed =
        match result.failures with
        | Some n -> [ Printf.sprintf "  failed in %d of the runs tried" n ]
        | None -> []
      in
      [ ""; Printf.sprintf "%s: cost %g" result.check.id path.cost ]
      @ failed
      @ List.mapi step_line path.steps

let to_string (config : Config.t) results =
  let header =
    [
      "model:   " ^ config.model;
      "solver:  " ^ solver_line config.solver;
      "";
    ]
  in
  let rows =
    [ "id"; "result"; "likelihood"; "steps"; "description" ]
    :: List.map (row config) results
  in
  String.concat "\n" (header @ table rows @ List.concat_map detail results)
  ^ "\n"
