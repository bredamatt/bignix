open Ast_sim

let routes = "models/routes.big"
let priorities = "models/priorities.big"
let close = Alcotest.float 1e-9
let slip p = [ ("p_slip", Model.Float p) ]
let load_priorities () = Model.load ~consts:(slip 0.2) priorities

let failure s =
  match Failure.parse s with Ok f -> f | Error msg -> Alcotest.fail msg

(* True if [f] raises an exception that [expected] accepts. *)
let raises expected f =
  match f () with
  | _ -> Alcotest.fail "expected an error"
  | exception e ->
      if not (expected e) then
        Alcotest.failf "unexpected exception: %s" (Printexc.to_string e)

let contains ~sub s =
  let n = String.length sub in
  let rec at i = i + n <= String.length s && (String.sub s i n = sub || at (i + 1)) in
  at 0

let model_error sub = function
  | Model.Error msg -> contains ~sub msg
  | _ -> false

let problem_error sub = function
  | Problem.Error msg -> contains ~sub msg
  | _ -> false

let config_error sub = function
  | Config.Error msg -> contains ~sub msg
  | _ -> false

(* (action, probability) of each transition, sorted. *)
let outcomes transitions =
  List.map (fun (t : Model.transition) -> (t.action, t.prob)) transitions
  |> List.sort compare

let outcome_list = Alcotest.(list (pair string close))

let problem ?(file = routes) ?(consts = []) ?(choice = Problem.Free 0.01)
    ?(max_depth = 10) fail =
  Problem.make
    ~model:(Model.load ~consts file)
    ~failure:(failure fail) ~choice ~max_depth ~penalty:50.

let actions (path : Problem.path) =
  List.map (fun (s : Problem.step) -> s.transition.action) path.steps

let found = function
  | Some path -> path
  | None -> Alcotest.fail "expected a failing run"

(* ---- Failure expressions ---- *)

let failure_tests =
  let open Failure in
  let expr = Alcotest.testable (fun fmt _ -> Format.fprintf fmt "<expr>") ( = ) in
  let parses name input expected =
    Alcotest.test_case name `Quick (fun () ->
        Alcotest.check expr input expected (failure input))
  in
  let rejects name input =
    Alcotest.test_case name `Quick (fun () ->
        Alcotest.(check bool) input true (Result.is_error (parse input)))
  in
  [
    parses "one predicate" "leak" (Pred "leak");
    parses "not binds tighter than and, and than or" "a | b & !c"
      (Or (Pred "a", And (Pred "b", Not (Pred "c"))));
    parses "parentheses group" "(a | b) & c"
      (And (Or (Pred "a", Pred "b"), Pred "c"));
    parses "a predicate with parameters" "near(1,2) & x"
      (And (Pred "near(1,2)", Pred "x"));
    parses "spaces inside the parameters are ignored" "near(1, 2)"
      (Pred "near(1,2)");
    rejects "empty" "";
    rejects "missing operand" "a &";
    rejects "two names in a row" "a b";
    rejects "unknown character" "a $ b";
    rejects "unclosed parenthesis" "(a | b";
    Alcotest.test_case "eval" `Quick (fun () ->
        let holds name = name = "a" in
        Alcotest.(check bool) "a & !b" true (eval holds (failure "a & !b"));
        Alcotest.(check bool) "b | !a" false (eval holds (failure "b | !a")));
    Alcotest.test_case "names" `Quick (fun () ->
        Alcotest.(check (list string))
          "names" [ "a"; "b"; "c" ]
          (names (failure "a | b & !c")));
  ]

(* ---- Model ---- *)

let model_tests =
  [
    Alcotest.test_case "the probabilities of each action sum to one" `Quick
      (fun () ->
        (* bigrapher itself gives go 1.0 and short 0.09/0.91 here: it merges
           go_miss and short_miss, which reach the same state. *)
        let m = Model.load routes in
        Alcotest.check outcome_list "from Start"
          [ ("go", 0.5); ("go", 0.5); ("short", 0.1); ("short", 0.9) ]
          (outcomes (Model.step m (Model.initial m))));
    Alcotest.test_case "actions and predicates are listed" `Quick (fun () ->
        let m = Model.load routes in
        Alcotest.(check (list string))
          "actions" [ "short"; "go"; "push" ] (Model.actions m);
        Alcotest.(check (list string))
          "predicates" [ "failed"; "dead" ] (Model.predicates m));
    Alcotest.test_case "only the first enabled priority class is used" `Quick
      (fun () ->
        let m = load_priorities () in
        Alcotest.check outcome_list "from the initial state"
          [ ("respond", 0.2); ("respond", 0.8) ]
          (outcomes (Model.step m (Model.initial m))));
    Alcotest.test_case "instantaneous rules apply to the state reached" `Quick
      (fun () ->
        let m = load_priorities () in
        let caught =
          Model.step m (Model.initial m)
          |> List.find (fun (t : Model.transition) -> t.prob > 0.5)
        in
        Alcotest.(check bool) "gone" true (Model.holds m caught.next "gone");
        Alcotest.(check int) "no way on" 0
          (List.length (Model.step m caught.next)));
    Alcotest.test_case "a lower class is used when the first is not enabled"
      `Quick (fun () ->
        let m = load_priorities () in
        let slipped =
          Model.step m (Model.initial m)
          |> List.find (fun (t : Model.transition) -> t.prob < 0.5)
        in
        Alcotest.check outcome_list "after slipping"
          [ ("enter", 1.); ("wait", 1.) ]
          (outcomes (Model.step m slipped.next)));
    Alcotest.test_case "constants can be set" `Quick (fun () ->
        let m = Model.load ~consts:(slip 0.5) priorities in
        Alcotest.check outcome_list "from the initial state"
          [ ("respond", 0.5); ("respond", 0.5) ]
          (outcomes (Model.step m (Model.initial m))));
    Alcotest.test_case "a constant that is not set is reported" `Quick
      (fun () ->
        raises (model_error "p_slip") (fun () -> Model.load priorities));
    Alcotest.test_case "a model that is not an abrs is rejected" `Quick
      (fun () ->
        raises (model_error "begin abrs") (fun () ->
            Model.load "models/plain.big"));
    Alcotest.test_case "a folder in place of a file is reported" `Quick
      (fun () -> raises (model_error "models") (fun () -> Model.load "models"));
    Alcotest.test_case "a missing file is reported" `Quick (fun () ->
        raises (model_error "nowhere.big") (fun () ->
            Model.load "models/nowhere.big"));
    Alcotest.test_case "a syntax error is reported with its place" `Quick
      (fun () ->
        raises (model_error "line") (fun () ->
            Model.load "configs/minimal.json"));
  ]

(* ---- Problem ---- *)

let step_costs p =
  let m = Problem.model p in
  Problem.steps p (Model.initial m)
  |> List.map (fun (s : Problem.step) -> (s.transition.action, s.cost))
  |> List.sort compare

let problem_tests =
  [
    Alcotest.test_case "free: the step cost plus -log p" `Quick (fun () ->
        Alcotest.check outcome_list "costs"
          [
            ("go", 0.01 -. log 0.5);
            ("go", 0.01 -. log 0.5);
            ("short", 0.01 -. log 0.9);
            ("short", 0.01 -. log 0.1);
          ]
          (step_costs (problem "failed")));
    Alcotest.test_case "uniform: each enabled action is equally likely" `Quick
      (fun () ->
        Alcotest.check outcome_list "costs"
          [
            ("go", log 2. -. log 0.5);
            ("go", log 2. -. log 0.5);
            ("short", log 2. -. log 0.9);
            ("short", log 2. -. log 0.1);
          ]
          (step_costs (problem ~choice:Problem.Uniform "failed")));
    Alcotest.test_case "weights: normalised over the enabled actions" `Quick
      (fun () ->
        let choice =
          Problem.Weights [ ("short", 3.); ("go", 1.); ("push", 100.) ]
        in
        Alcotest.check outcome_list "costs"
          [
            ("go", -.log 0.25 -. log 0.5);
            ("go", -.log 0.25 -. log 0.5);
            ("short", -.log 0.75 -. log 0.9);
            ("short", -.log 0.75 -. log 0.1);
          ]
          (step_costs (problem ~choice "failed")));
    Alcotest.test_case "a failure over an unknown predicate is rejected" `Quick
      (fun () ->
        raises (problem_error "nope") (fun () -> problem "failed | nope"));
    Alcotest.test_case "weights must cover every action" `Quick (fun () ->
        raises (problem_error "push") (fun () ->
            problem ~choice:(Problem.Weights [ ("short", 1.); ("go", 1.) ]) "failed"));
    Alcotest.test_case "a weight for an unknown action is rejected" `Quick
      (fun () ->
        let choice =
          Problem.Weights
            [ ("short", 1.); ("go", 1.); ("push", 1.); ("jump", 1.) ]
        in
        raises (problem_error "jump") (fun () -> problem ~choice "failed"));
    Alcotest.test_case "likelihood is the product of the probabilities" `Quick
      (fun () ->
        let path = found (Exact.solve (problem "failed") ~max_states:100) in
        Alcotest.check close "likelihood" 0.25 (Problem.likelihood path));
  ]

(* ---- Exact ---- *)

let exact ?file ?consts ?choice ?max_depth fail =
  Exact.solve (problem ?file ?consts ?choice ?max_depth fail) ~max_states:100

let exact_tests =
  [
    Alcotest.test_case "the long route is the likelier one" `Quick (fun () ->
        let path = found (exact "failed") in
        Alcotest.(check (list string)) "actions" [ "go"; "push" ] (actions path);
        Alcotest.check close "cost" (0.02 -. (2. *. log 0.5)) path.cost);
    Alcotest.test_case "with one step allowed, only the short route is left"
      `Quick (fun () ->
        let path = found (exact ~max_depth:1 "failed") in
        Alcotest.(check (list string)) "actions" [ "short" ] (actions path);
        Alcotest.check close "cost" (0.01 -. log 0.1) path.cost);
    Alcotest.test_case "a high step cost favours the short route" `Quick
      (fun () ->
        let path = found (exact ~choice:(Problem.Free 2.) "failed") in
        Alcotest.(check (list string)) "actions" [ "short" ] (actions path));
    Alcotest.test_case "a failure in the initial state is an empty run" `Quick
      (fun () ->
        let path = found (exact "!failed") in
        Alcotest.(check int) "steps" 0 (List.length path.steps);
        Alcotest.check close "cost" 0. path.cost);
    Alcotest.test_case "no run fails" `Quick (fun () ->
        Alcotest.(check bool) "none" true (exact "failed & dead" = None));
    Alcotest.test_case "through priority classes" `Quick (fun () ->
        let path = found (exact ~file:priorities ~consts:(slip 0.2) "inside") in
        Alcotest.(check (list string))
          "actions" [ "respond"; "enter" ] (actions path);
        Alcotest.check close "cost" (0.02 -. log 0.2) path.cost);
    Alcotest.test_case "a run may revisit a state" `Quick (fun () ->
        (* wait, respond (slip), enter is not better than respond, enter *)
        let path = found (exact ~file:priorities ~consts:(slip 0.2) ~max_depth:2 "inside") in
        Alcotest.(check int) "steps" 2 (List.length path.steps));
    Alcotest.test_case "too many states is an error" `Quick (fun () ->
        raises (problem_error "max_states") (fun () ->
            Exact.solve (problem "failed") ~max_states:2));
  ]

(* ---- MCTS ---- *)

let mcts ?(iterations = 500) ?(seed = 1) p =
  Mcts.search p { Mcts.iterations; exploration = 1.; seed }

(* MCTS finds the run that the exact search finds. *)
let agrees name p =
  Alcotest.test_case name `Quick (fun () ->
      let expected = found (Exact.solve p ~max_states:100) in
      let path = found (mcts p).best in
      Alcotest.(check (list string)) "actions" (actions expected) (actions path);
      Alcotest.check close "cost" expected.cost path.cost)

let mcts_tests =
  [
    agrees "routes, free" (problem "failed");
    agrees "routes, uniform" (problem ~choice:Problem.Uniform "failed");
    agrees "routes, one step" (problem ~max_depth:1 "failed");
    agrees "routes, high step cost" (problem ~choice:(Problem.Free 2.) "failed");
    agrees "priorities" (problem ~file:priorities ~consts:(slip 0.2) "inside");
    agrees "priorities, even slip"
      (problem ~file:priorities ~consts:(slip 0.5) "inside");
    Alcotest.test_case "the same seed gives the same result" `Quick (fun () ->
        let p = problem "failed" in
        let a = mcts ~iterations:50 ~seed:3 p
        and b = mcts ~iterations:50 ~seed:3 p in
        Alcotest.(check int) "failures" a.failures b.failures;
        Alcotest.(check (list string))
          "actions" (actions (found a.best)) (actions (found b.best)));
    Alcotest.test_case "failing runs are counted" `Quick (fun () ->
        let result = mcts ~iterations:200 (problem "failed") in
        Alcotest.(check bool) "some" true (result.failures > 0);
        Alcotest.(check bool) "not more than runs" true (result.failures <= 200));
    Alcotest.test_case "no run fails" `Quick (fun () ->
        let result = mcts ~iterations:100 (problem "failed & dead") in
        Alcotest.(check bool) "none" true (result.best = None);
        Alcotest.(check int) "failures" 0 result.failures);
    Alcotest.test_case "runs stop at the depth limit" `Quick (fun () ->
        let result =
          mcts ~iterations:100 (problem ~file:priorities ~consts:(slip 0.2) ~max_depth:1 "inside")
        in
        Alcotest.(check bool) "none" true (result.best = None));
  ]

(* ---- Config and report ---- *)

let rejected name file sub =
  Alcotest.test_case name `Quick (fun () ->
      raises (config_error sub) (fun () ->
          Config.of_file ("configs/" ^ file ^ ".json")))

let config_tests =
  [
    Alcotest.test_case "all settings are read" `Quick (fun () ->
        let c = Config.of_file "configs/routes.json" in
        Alcotest.(check string) "model" "configs/../models/routes.big" c.model;
        Alcotest.(check bool) "choice" true (c.choice = Problem.Uniform);
        Alcotest.(check int) "max_depth" 5 c.max_depth;
        Alcotest.check close "penalty" 50. c.penalty;
        Alcotest.(check bool)
          "solver" true
          (c.solver
          = Config.Mcts { iterations = 300; exploration = 0.5; seed = 7 }));
    Alcotest.test_case "defaults" `Quick (fun () ->
        let c = Config.of_file "configs/minimal.json" in
        Alcotest.(check bool) "choice" true (c.choice = Problem.Free 0.01);
        Alcotest.(check int) "max_depth" 100 c.max_depth;
        Alcotest.(check bool)
          "solver" true
          (c.solver
          = Config.Mcts { iterations = 10000; exploration = 1.; seed = 0 }));
    Alcotest.test_case "a misspelt setting is an error" `Quick (fun () ->
        raises (config_error "max_dept") (fun () ->
            Config.of_file "configs/typo.json"));
    Alcotest.test_case "an unknown solver is an error" `Quick (fun () ->
        raises (config_error "magic") (fun () ->
            Config.of_file "configs/bad_solver.json"));
    Alcotest.test_case "a bad failure expression is an error" `Quick (fun () ->
        raises (config_error "failure expression") (fun () ->
            Config.of_file "configs/bad_failure.json"));
    rejected "consts must be an object" "consts_not_object" "consts";
    rejected "weights must be an object" "weights_not_object" "weights";
    rejected "exact takes no iterations" "exact_with_iterations" "iterations";
    rejected "uniform takes no step cost" "uniform_with_step_cost" "step_cost";
    rejected "exploration is not negative" "negative_exploration" "exploration";
    rejected "max_states is at least 1" "zero_max_states" "max_states";
    rejected "numbers are finite" "infinite_cost" "step_cost";
    Alcotest.test_case "a missing file is an error" `Quick (fun () ->
        raises (config_error "nowhere.json") (fun () ->
            Config.of_file "configs/nowhere.json"));
    rejected "at least one check" "no_checks" "at least one";
    rejected "check ids differ" "same_id" "\"A\"";
    Alcotest.test_case "the checks are read in order" `Quick (fun () ->
        let c = Config.of_file "configs/table.json" in
        Alcotest.(check (list string))
          "ids" [ "L1"; "H1"; "SC1" ]
          (List.map (fun (k : Config.check) -> k.id) c.checks);
        Alcotest.(check (list string))
          "descriptions"
          [ "The run fails"; ""; "Never both" ]
          (List.map (fun (k : Config.check) -> k.description) c.checks));
  ]

(* ---- Report ---- *)

let has text sub = Alcotest.(check bool) sub true (contains ~sub text)

let report_tests =
  [
    Alcotest.test_case "one result for each check" `Quick (fun () ->
        let c = Config.of_file "configs/table.json" in
        let results = Report.run c in
        Alcotest.(check (list (list string)))
          "runs"
          [ [ "go"; "push" ]; [ "short" ]; [] ]
          (List.map
             (fun (r : Report.result) ->
               match r.best with Some path -> actions path | None -> [])
             results);
        Alcotest.(check bool)
          "SC1 has no run" true
          ((List.nth results 2).best = None));
    Alcotest.test_case "the table of an exact search" `Quick (fun () ->
        let c = Config.of_file "configs/table.json" in
        let text = Report.to_string c (Report.run c) in
        has text "id   result         likelihood  steps  description";
        has text "L1   reached        0.25        2      The run fails";
        has text "H1   reached        0.9         1";
        has text "SC1  not reachable  -           -      Never both";
        has text "L1: cost 1.40629";
        has text "   1. go -> go_hit   p = 0.5");
    Alcotest.test_case "mcts says not found, and counts failing runs" `Quick
      (fun () ->
        let c = Config.of_file "configs/table.json" in
        let c =
          {
            c with
            solver = Config.Mcts { iterations = 200; exploration = 1.; seed = 1 };
          }
        in
        let text = Report.to_string c (Report.run c) in
        has text "SC1  not found";
        has text "failed in ");
    Alcotest.test_case "an unknown predicate is reported with its check" `Quick
      (fun () ->
        let c = Config.of_file "configs/unknown_predicate.json" in
        raises (problem_error "check A") (fun () -> Report.run c));
  ]

let () =
  Alcotest.run "ast-sim"
    [
      ("failure", failure_tests);
      ("model", model_tests);
      ("problem", problem_tests);
      ("exact", exact_tests);
      ("mcts", mcts_tests);
      ("config", config_tests);
      ("report", report_tests);
    ]
