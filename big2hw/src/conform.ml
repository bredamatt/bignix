(* Do the circuits do only what the model does?

   Every state the two circuits can reach is tried with every input. One
   clock cycle must be a run of the model's reaction rules: from the model
   state that looks like the circuits before the cycle, to the one that looks
   like them after it.

   The run may use any rules, with these limits. What the surroundings do
   must be what they did in that cycle:

     the alarm goes up              only if the tamper input was high
     the transmit buffer fills      only with the payload on the load input
     the receive buffer empties     only if the take input was high
     light reaches a detector       only if that symbol was on that fibre

   each at most once. And the run must not stop in a state that the model
   leaves at once: one in which a rule of a class that acts first can fire. *)

type failure = {
  before : Design.obs;
  step : Sim.step;
  after : Design.obs;
  why : string;
}

type result = {
  model_states : int;
  circuit_states : int;  (** The states the circuits reach. *)
  cycles : int;  (** The cycles tried: a state and an input. *)
  clashes : int;
      (** Those in which light reached a detector that still held some. The
          model's transmit logic waits for a free detector; a circuit cannot. *)
  failures : failure list;
  holds : (string * int) list;
      (** Each predicate of the model, and the number of circuit states it holds in. *)
}

(* The longest run of rules one cycle can be. *)
let depth = 10

(* What the surroundings did between two states of the model, one reaction
   apart. *)
let events (a : Design.obs) (b : Design.obs) =
  List.filter_map
    (fun (key, was) ->
      let is = List.assoc key b in
      if was = is then None
      else if key = "alarm" && is = "1" then Some "tamper"
      else if key = "tx.buf" && was = "-" then Some ("load " ^ is)
      else if key = "rx.buf" && is = "-" then Some "take"
      else if String.length key > 3 && String.sub key 0 3 = "at." && was = "-" then
        Some (Printf.sprintf "light %s %s" key is)
      else None)
    a

(* What the surroundings did in a cycle of the circuits. *)
let allowed (step : Sim.step) (seen : Sim.seen) =
  (if step.tamper then [ "tamper" ] else [])
  @ (match step.load with Some p -> [ "load " ^ p ] | None -> [])
  @ (if step.take then [ "take" ] else [])
  @ List.filter_map
      (fun (port, s) -> if s = "-" then None else Some (Printf.sprintf "light at.%s %s" port s))
      seen.fibres

(* [left] without [used], or None if [used] has something [left] does not. *)
let rec spend left = function
  | [] -> Some left
  | e :: used -> (
      match Design.index e left with
      | Some i -> spend (List.filteri (fun j _ -> j <> i) left) used
      | None -> None)

(* Is there a run of the model from [start] to [goal] that the surroundings
   allow? *)
let run_exists (sp : Space.t) obs ~start ~goal ~allowed =
  let rec search frontier visited n =
    if List.exists (fun (i, _) -> i = goal) frontier then true
    else if n = 0 || frontier = [] then false
    else
      let reached =
        List.concat_map
          (fun (i, left) ->
            List.filter_map
              (fun j -> Option.map (fun left -> (j, left)) (spend left (events obs.(i) obs.(j))))
              sp.next.(i))
          frontier
        |> List.sort_uniq compare
        |> List.filter (fun x -> not (List.mem x visited))
      in
      search reached (reached @ visited) (n - 1)
  in
  search [ (start, allowed) ] [ (start, allowed) ] depth

let steps (d : Design.t) =
  let bools on = if on then [ false; true ] else [ false ] in
  List.concat_map
    (fun load ->
      List.concat_map
        (fun damage ->
          List.concat_map
            (fun tamper -> List.map (fun take -> { Sim.load; damage; tamper; take }) (bools true))
            (bools d.sensor))
        (bools (Hw.can_damage d)))
    (None :: List.map Option.some d.payloads)

let check (d : Design.t) (sp : Space.t) =
  let obs = Array.map (Design.observe d) sp.states in
  let n = Array.length obs in
  let state_of o = Design.index o (Array.to_list obs) in
  if List.length (List.sort_uniq compare (Array.to_list obs)) <> n then
    Bg.error "two states of the model look the same from outside";
  let sim = Sim.create d in
  (* The circuits after reset and then [path]: what the last cycle looked like. *)
  let replay path =
    Sim.reset sim;
    List.fold_left (fun _ step -> Some (Sim.cycle sim step)) None path
  in
  let try_step before path step =
    let seen = Option.get (replay (path @ [ step ])) in
    let fail why = Some { before; step; after = seen.obs; why } in
    let failure =
      match (state_of before, state_of seen.obs) with
      | None, _ -> None (* reported when this state was reached *)
      | _, None -> fail "the model has no such state"
      | Some _, Some goal when sp.urgent.(goal) ->
          fail "the model leaves this state at once: a rule that acts first can fire"
      | Some start, Some goal ->
          if run_exists sp obs ~start ~goal ~allowed:(allowed step seen) then None
          else fail "no run of the model's rules does this"
    in
    (seen.obs, failure, seen.clash)
  in
  let all_steps = steps d in
  let rec explore known queue cycles clashes failures =
    match queue with
    | [] -> (known, cycles, clashes, List.rev failures)
    | (before, path) :: rest ->
        let results = List.map (fun step -> (step, try_step before path step)) all_steps in
        let known, fresh =
          List.fold_left
            (fun (known, fresh) (step, (after, _, _)) ->
              if List.mem after known then (known, fresh)
              else (after :: known, fresh @ [ (after, path @ [ step ]) ]))
            (known, []) results
        in
        explore known (rest @ fresh)
          (cycles + List.length results)
          (clashes + List.length (List.filter (fun (_, (_, _, clash)) -> clash) results))
          (List.rev_append (List.filter_map (fun (_, (_, f, _)) -> f) results) failures)
  in
  Sim.reset sim;
  let start = Sim.observe sim in
  let first =
    if state_of start = Some 0 then []
    else
      [ { before = start; step = Sim.idle; after = start;
          why = "after reset the circuits are not in the model's first state" } ]
  in
  let known, cycles, clashes, failures = explore [ start ] [ (start, []) ] 0 0 first in
  let reached = List.filter_map state_of known in
  {
    model_states = n;
    circuit_states = List.length known;
    cycles;
    clashes;
    failures;
    holds =
      List.map
        (fun (pred, where) -> (pred, List.length (List.filter (fun i -> List.mem i where) reached)))
        sp.labels;
  }

let show_step (s : Sim.step) =
  match
    (match s.load with Some p -> [ "load " ^ p ] | None -> [])
    @ (if s.damage then [ "damage" ] else [])
    @ (if s.tamper then [ "tamper" ] else [])
    @ if s.take then [ "take" ] else []
  with
  | [] -> "nothing"
  | l -> String.concat ", " l

let text (r : result) =
  let line fmt = Printf.sprintf (fmt ^^ "\n") in
  String.concat ""
    ([ line "The model has %d states." r.model_states;
       line "The circuits reach %d states. Each was tried with every input: %d clock cycles."
         r.circuit_states r.cycles ]
    @ (match r.failures with
      | [] ->
          [ line "Every cycle is a run of the model's reaction rules.";
            line "So the circuits do nothing the model cannot do. That they do what they";
            line "should is not checked here: see the predicates below, and the tests." ]
      | fs ->
          line "%d cycles are not a run of the model's reaction rules:" (List.length fs)
          :: List.concat_map
               (fun f ->
                 [ line "  before  %s" (Design.show f.before);
                   line "  inputs  %s" (show_step f.step);
                   line "  after   %s" (Design.show f.after);
                   line "  %s" f.why ])
               fs)
    @ [ (if r.clashes = 0 then line "In no cycle did light reach a detector that still held some."
         else line "In %d cycles light reached a detector that still held some." r.clashes);
        line "Predicates of the model, and the circuit states each holds in:" ]
    @ List.map (fun (pred, k) -> line "  %-22s %s" pred (if k = 0 then "none" else string_of_int k)) r.holds)
