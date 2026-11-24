(* The circuits against the model's own transition system. *)

open Big2hw
open Common

(* Building the states of the model takes seconds, so the unchanged model's
   are built once. *)
let unchanged = lazy (Space.build (Bg.load file))
let space_of model = if model = file then Lazy.force unchanged else Space.build (Bg.load model)

(* The circuits built from [circuit], checked against the model [model]. *)
let check ?(circuit = file) ?(model = file) () =
  Conform.check (design ~file:circuit ()) (space_of model)

let space () =
  let sp = space_of file in
  Alcotest.(check int) "as many states as bigrapher full finds" 276 (Array.length sp.states);
  Alcotest.(check int) "as many transitions" 714
    (Array.fold_left (fun n next -> n + List.length next) 0 sp.next);
  Alcotest.(check bool) "the first state is not one the hazard rule fires in" false sp.urgent.(0);
  Alcotest.(check bool) "some state is" true (Array.exists (fun u -> u) sp.urgent)

let conforms () =
  let r = check () in
  List.iter (fun (f : Conform.failure) -> print_endline (Design.show f.after ^ ": " ^ f.why)) r.failures;
  Alcotest.(check int) "no cycle the model cannot do" 0 (List.length r.failures);
  Alcotest.(check int) "the states the circuits reach" 45 r.circuit_states;
  Alcotest.(check int) "each tried with 24 inputs" (45 * 24) r.cycles;
  Alcotest.(check int) "of the model's states" 276 r.model_states;
  Alcotest.(check int) "light never reaches a detector that still holds some" 0 r.clashes

(* The states that must never be reached are predicates of the model. None
   holds in a state the circuits reach. *)
let bad_states () =
  let r = check () in
  let bad = List.filter (fun (pred, _) -> String.length pred > 4 && String.sub pred 0 4 = "bad_") r.holds in
  Alcotest.(check int) "the model names eight of them, and the damaged tag" 9 (List.length bad);
  List.iter
    (fun (pred, k) ->
      if pred <> "bad_tag_waiting" then Alcotest.(check int) pred 0 k)
    bad;
  Alcotest.(check bool) "the circuits do deliver" true (List.assoc "rx_full" r.holds > 0);
  Alcotest.(check bool) "and do block" true (List.assoc "cc_blocked" r.holds > 0)

(* The model with a channel control that takes a tag while Idle. Clocked
   circuits with an honest transmitter never show a tag to an Idle channel
   control, so circuits and model can be mixed and nothing differs. *)
let difference_never_shown () =
  let other = variant idle_takes_tag in
  Alcotest.(check int) "these circuits, that model" 0
    (List.length (check ~circuit:file ~model:other ()).failures);
  Alcotest.(check int) "those circuits, this model" 0
    (List.length (check ~circuit:other ~model:file ()).failures);
  Alcotest.(check int) "those circuits, that model" 0
    (List.length (check ~circuit:other ~model:other ()).failures)

(* The small model of ../examples, and the edits its README suggests. *)
let gate = "../examples/gate.big"

let example () =
  let r = check ~circuit:gate ~model:gate () in
  Alcotest.(check int) "no cycle the model cannot do" 0 (List.length r.failures);
  Alcotest.(check int) "states of the model" 42 r.model_states;
  Alcotest.(check int) "states of the circuits" 14 r.circuit_states;
  Alcotest.(check int) "cycles" 56 r.cycles

let example_edits () =
  let failures edits =
    let m = variant ~of_:gate edits in
    List.length (check ~circuit:m ~model:m ()).failures
  in
  Alcotest.(check int) "without block_pulse the model cannot follow the circuit" 4
    (failures [ ("step_pulse, carry, block_pulse, drop", "step_pulse, carry, drop") ]);
  Alcotest.(check int) "with a pulse accepted in Open, light meets a full detector" 8
    (failures [ ("Trans.(Msg | To{c0}))", "Trans.(Msg | To{c0}) | Trans.(Pulse | To{c1}))") ]);
  match design ~file:(variant ~of_:gate [ ("Open | Drive{en} |", "Open |") ]) () with
  | _ -> Alcotest.fail "a gate nothing drives was accepted"
  | exception Bg.Error msg ->
      Alcotest.(check bool) "the refusal names the state" true (contains msg "Open has a transition")

(* ---- Circuits that do what the model cannot: the check must say so ---- *)

let caught what (r : Conform.result) part =
  if not (List.exists (fun (f : Conform.failure) -> contains (Design.show f.after ^ " " ^ f.why) part) r.failures)
  then Alcotest.failf "%s: %d failures, none with %s" what (List.length r.failures) part

(* Circuits built from a machine that opens on a tag that does not verify. *)
let accepts_bad_tag () =
  let wrong = variant [ ("Trans.(Tag | To{c2})", "Trans.(BadTag | To{c2})") ] in
  caught "opens on a bad tag" (check ~circuit:wrong ~model:file ()) "cc=Open"

(* Circuits built from a layout in which the channel control has no hazard pin. *)
let deaf_to_hazard () =
  let deaf = variant [ ("In{ctl_i} | In{dat_i} | HazIn{hz})", "In{ctl_i} | In{dat_i})") ] in
  Alcotest.(check bool) "that circuit has no hazard input" false (design ~file:deaf ()).rx.hazard;
  caught "does not block on the alarm" (check ~circuit:deaf ~model:file ()) "at once"

(* Circuits that fail to Idle, where the model fails to Blocked. *)
let fails_open () =
  let d = design () in
  let d = { d with rx = { d.rx with blocked = 0 } } in
  Alcotest.(check string) "state 0" "Idle" d.rx.machine.states.(0).name;
  caught "fails to Idle" (Conform.check d (space_of file)) "cc=Idle"

let () =
  Alcotest.run "conform"
    [ ( "model",
        [ Alcotest.test_case "the reachable states" `Quick space ] );
      ( "circuits",
        [ Alcotest.test_case "every cycle is a run of the rules" `Quick conforms;
          Alcotest.test_case "no bad state is reached" `Quick bad_states;
          Alcotest.test_case "a difference no run shows" `Quick difference_never_shown;
          Alcotest.test_case "the small example" `Quick example;
          Alcotest.test_case "the edits its README suggests" `Quick example_edits ] );
      ( "wrong circuits are caught",
        [ Alcotest.test_case "opens on a bad tag" `Quick accepts_bad_tag;
          Alcotest.test_case "deaf to the hazard line" `Quick deaf_to_hazard;
          Alcotest.test_case "fails to Idle" `Quick fails_open ] ) ]
