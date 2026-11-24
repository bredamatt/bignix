(* The circuits, simulated: what the properties of the model say must and must
   not happen, tried on the hardware. *)

open Big2hw
open Common

let idle = Sim.idle
let load p = { idle with load = Some p }
let take = { idle with take = true }
let damage = { idle with damage = true }
let tamper = { idle with tamper = true }

(* What is seen in each cycle of a run from reset. *)
let run ?(d = design ()) steps =
  let sim = Sim.create d in
  Sim.reset sim;
  List.map (Sim.cycle sim) steps

let last l = List.nth l (List.length l - 1)
let get key (seen : Sim.seen) = List.assoc key seen.obs
let after steps key = get key (last (run steps))
let str = Alcotest.string

(* One transfer: load, then the pulse, the tag and the payload, a cycle each. *)
let transfer p = [ load p; idle; idle; idle ]

let honest () =
  let seen = run (transfer "Response") in
  Alcotest.(check (list (list (pair string string)))) "one symbol on one fibre per cycle"
    [ [ ("ctl_i", "-"); ("dat_i", "-") ];
      [ ("ctl_i", "Pulse"); ("dat_i", "-") ];
      [ ("ctl_i", "-"); ("dat_i", "Tag") ];
      [ ("ctl_i", "-"); ("dat_i", "Response") ] ]
    (List.map (fun (s : Sim.seen) -> s.fibres) seen);
  Alcotest.(check (list string)) "the channel control follows its machine"
    [ "Idle"; "Armed"; "Open"; "Idle" ] (List.map (get "cc") seen);
  Alcotest.check str "the response is in the receive buffer" "Response" (get "rx.buf" (last seen));
  Alcotest.check str "the transmit machine is back at the start" "TxIdle" (get "tx" (last seen))

(* 02: the weights never reach the receive buffer. *)
let weights () =
  let seen = run (transfer "Weights" @ transfer "Response") in
  Alcotest.(check bool) "the receive buffer stays empty" true
    (List.for_all (fun s -> get "rx.buf" s = "-") seen);
  Alcotest.check str "the channel control has failed secure" "Blocked" (get "cc" (last seen))

(* 03: the gate's enable wire is high only while the state is Open. *)
let enable () =
  let seen = run (transfer "Response" @ [ take ] @ transfer "Weights") in
  Alcotest.(check (list bool)) "high in the two cycles a payload arrives in Open"
    [ false; false; false; true; false; false; false; false; true ]
    (List.map (fun (s : Sim.seen) -> s.enable) seen)

(* 07: after a tag that does not verify, nothing is carried again. *)
let bad_tag () =
  let seen = run ([ load "Response"; idle; damage; idle ] @ transfer "Response") in
  Alcotest.check str "the damaged tag is what arrives" "BadTag"
    (List.assoc "dat_i" (List.nth seen 2).fibres);
  Alcotest.(check bool) "nothing is carried" true
    (List.for_all (fun s -> get "rx.buf" s = "-") seen);
  Alcotest.check str "blocked" "Blocked" (get "cc" (last seen))

(* 08: once blocked, it stays blocked. *)
let stays_blocked () =
  let seen = run (transfer "Weights" @ transfer "Response" @ transfer "Response") in
  let from_block = List.filteri (fun i _ -> i >= 3) seen in
  Alcotest.(check bool) "every later cycle" true
    (List.for_all (fun s -> get "cc" s = "Blocked") from_block)

(* 09: the hazard line blocks in the same cycle, even with a response at the gate. *)
let hazard () =
  let seen = run [ load "Response"; idle; idle; tamper ] in
  Alcotest.check str "the response was on the fibre" "Response"
    (List.assoc "dat_i" (last seen).fibres);
  Alcotest.(check bool) "the gate did not open for it" false (last seen).enable;
  Alcotest.check str "it was not carried" "-" (get "rx.buf" (last seen));
  Alcotest.check str "blocked" "Blocked" (get "cc" (last seen));
  Alcotest.check str "the alarm stays up" "1" (after [ tamper; idle; idle ] "alarm")

(* 11: a response is carried, taken, and a second one carried. *)
let twice () =
  let seen = run (transfer "Response" @ [ take ] @ transfer "Response") in
  Alcotest.(check (list string)) "the receive buffer"
    [ "-"; "-"; "-"; "Response"; "-"; "-"; "-"; "-"; "Response" ]
    (List.map (get "rx.buf") seen);
  Alcotest.check str "not blocked" "Idle" (get "cc" (last seen))

(* A response that arrives while the receive buffer is full waits at the
   detector, as it does in the model, and is carried once the buffer is taken. *)
let waits () =
  let seen = run (transfer "Response" @ transfer "Response") in
  Alcotest.check str "it waits at the data detector" "Response" (get "at.dat_i" (last seen));
  Alcotest.check str "the channel control is still Open" "Open" (get "cc" (last seen));
  let seen = run (transfer "Response" @ transfer "Response" @ [ take ]) in
  Alcotest.check str "then it is carried" "Response" (get "rx.buf" (last seen));
  Alcotest.check str "the detector is free" "-" (get "at.dat_i" (last seen));
  Alcotest.check str "the path is closed" "Idle" (get "cc" (last seen))

(* 12b: the pulse of the next transfer, while that response still waits, blocks. *)
let next_pulse_blocks () =
  let seen = run (transfer "Response" @ transfer "Response" @ [ load "Response"; idle ]) in
  Alcotest.check str "blocked" "Blocked" (get "cc" (last seen));
  Alcotest.check str "the waiting response is discarded" "-" (get "at.dat_i" (last seen))

(* ---- One board alone, with anything on its pins ---- *)

open Hardcaml

(* One board from reset. Each cycle lists the pins that are not 0 in it.
   The result reads an output after the last cycle. *)
let board circuit cycles =
  let sim = Cyclesim.create circuit in
  List.iter
    (fun pins ->
      List.iter
        (fun (name, port) ->
          let value = Option.value (List.assoc_opt name pins) ~default:0 in
          port := Bits.of_int ~width:(Bits.width !port) value)
        (Cyclesim.in_ports sim);
      Cyclesim.cycle sim)
    cycles;
  fun name -> Bits.to_int !(Cyclesim.out_port sim name)

let cc_state (d : Design.t) name =
  Option.get (Design.index name (List.map (fun (s : Design.state) -> s.name)
                                   (Array.to_list d.rx.machine.states)))

let unknown_symbol () =
  let d = design () in
  let out = board (Hw.receiver_circuit d) [ [ ("dat_i", 7) ] ] in
  Alcotest.(check int) "a code that is no symbol blocks" (cc_state d "Blocked") (out "cc_state")

let both_fibres () =
  let d = design () in
  let out =
    board (Hw.receiver_circuit d) [ [ ("ctl_i", Hw.code d "Pulse"); ("dat_i", Hw.code d "Tag") ] ]
  in
  Alcotest.(check int) "the control fibre is read first, then the data fibre"
    (cc_state d "Open") (out "cc_state")

let tag_while_idle () =
  let pins d = [ [ ("dat_i", Hw.code d "Tag") ] ] in
  let d = design () in
  Alcotest.(check int) "as modelled: a tag while Idle blocks" (cc_state d "Blocked")
    (board (Hw.receiver_circuit d) (pins d) "cc_state");
  let d = design ~file:(variant idle_takes_tag) () in
  Alcotest.(check int) "with the machine edited in the bigraph: it opens" (cc_state d "Open")
    (board (Hw.receiver_circuit d) (pins d) "cc_state")

(* The cycles that bring the channel control to Open: a pulse, then a tag. *)
let opened d = [ [ ("ctl_i", Hw.code d "Pulse") ]; [ ("dat_i", Hw.code d "Tag") ] ]

let payload_on_control_fibre () =
  let d = design () in
  let out = board (Hw.receiver_circuit d) (opened d @ [ [ ("ctl_i", Hw.code d "Response") ] ]) in
  Alcotest.(check int) "a response on the fibre with no gate blocks" (cc_state d "Blocked")
    (out "cc_state");
  Alcotest.(check int) "and is not carried" 0 (out "rx_buf")

let light_on_a_full_detector () =
  let d = design () in
  let response = [ ("dat_i", Hw.code d "Response") ] in
  (* One response is carried and not taken. The next one waits at the detector. *)
  let waiting = opened d @ [ response ] @ opened d @ [ response ] in
  let out = board (Hw.receiver_circuit d) waiting in
  Alcotest.(check int) "the second response waits" (Hw.code d "Response") (out "dat_held");
  let out = board (Hw.receiver_circuit d) (waiting @ [ [ ("dat_i", Hw.code d "Tag") ] ]) in
  Alcotest.(check int) "more light on that fibre blocks" (cc_state d "Blocked") (out "cc_state");
  Alcotest.(check int) "what waited is discarded" 0 (out "dat_held");
  Alcotest.(check int) "the first response is still in the buffer" (Hw.code d "Response")
    (out "rx_buf")

let load_must_be_a_payload () =
  let d = design () in
  let out = board (Hw.sender_circuit d) [ [ ("load", Hw.code d "Pulse") ] ] in
  Alcotest.(check int) "the transmit machine has not moved" 0 (out "tx_state");
  Alcotest.(check int) "and has stored nothing" 0 (out "tx_buf");
  let out = board (Hw.sender_circuit d) [ [ ("load", Hw.code d "Response") ] ] in
  Alcotest.(check int) "a payload is stored" (Hw.code d "Response") (out "tx_buf")

let hazard_pin () =
  let d = design () in
  let out = board (Hw.receiver_circuit d) [ [ ("haz_i", 1) ] ] in
  Alcotest.(check int) "the hazard pin alone blocks" (cc_state d "Blocked") (out "cc_state")

let pulse_on_data_fibre () =
  let d = design () in
  let out = board (Hw.receiver_circuit d) [ [ ("dat_i", Hw.code d "Pulse") ] ] in
  Alcotest.(check int) "the machine reads a pulse on either fibre, as the In pins do"
    (cc_state d "Armed") (out "cc_state")

let waits_then_taken () =
  let d = design () in
  let response = [ ("dat_i", Hw.code d "Response") ] in
  let out =
    board (Hw.receiver_circuit d)
      (opened d @ [ response ] @ opened d @ [ response; [ ("rx_take", 1) ] ])
  in
  Alcotest.(check int) "the response that waited is carried" (Hw.code d "Response") (out "rx_buf");
  Alcotest.(check int) "the detector is free" 0 (out "dat_held");
  Alcotest.(check int) "the path is closed" (cc_state d "Idle") (out "cc_state")

(* A machine with no Load transition leaves the load input unused, and
   Hardcaml then drops the port. The simulator must still run. *)
let never_loads () =
  let d = design ~file:(variant [ ("State{t0}.(TxIdle      | Trans.(Load        | To{t1}))", "State{t0}.TxIdle") ]) () in
  let seen = run ~d [ load "Response"; idle ] in
  Alcotest.check str "the transmit machine stays where it is" "TxIdle" (get "tx" (last seen))

let script () =
  let d = design () in
  Alcotest.(check int) "cycles are separated by commas" 4
    (List.length (Sim.parse d "load Response, -, damage + take, tamper"));
  Alcotest.(check bool) "what a cycle says" true
    (List.nth (Sim.parse d "load Response, -, damage + take, tamper") 2
    = { idle with damage = true; take = true });
  List.iter
    (fun (text, part) ->
      match Sim.parse d text with
      | _ -> Alcotest.failf "%s was accepted" text
      | exception Bg.Error msg ->
          if not (contains msg part) then Alcotest.failf "%s: the message was: %s" text msg)
    [ ("load Pulse", "not a payload"); ("load", "load PAYLOAD"); ("jump", "jump") ]

(* The names a hand-written property file uses for the codes. *)
let codes () =
  let text = Report.codes ~source:"crs.big" (design ()) in
  List.iter
    (fun part -> if not (contains text part) then Alcotest.failf "the codes have no: %s" part)
    [ "localparam [2:0] SYM_NONE = 3'd0;"; "localparam [2:0] SYM_BAD_TAG = 3'd3;";
      "localparam [2:0] SYM_WEIGHTS = 3'd5;"; "localparam [1:0] TX_IDLE = 2'd0;";
      "localparam [1:0] CC_OPEN = 2'd2;"; "localparam [1:0] CC_BLOCKED = 2'd3;" ]

let verilog () =
  let d = design () in
  let tx = Hw.verilog (Hw.sender_circuit d) and rx = Hw.verilog (Hw.receiver_circuit d) in
  List.iter
    (fun (text, part) ->
      if not (contains text part) then Alcotest.failf "the Verilog has no %s" part)
    [ (tx, "module crs_server_room"); (tx, "ctl_o"); (tx, "dat_o"); (tx, "load");
      (rx, "module crs_interface"); (rx, "ctl_i"); (rx, "dat_i"); (rx, "haz_i");
      (rx, "gate_net"); (Hw.verilog (Hw.system_circuit d), "module crs ") ]

let () =
  Alcotest.run "hw"
    [ ( "both boards",
        [ Alcotest.test_case "an honest transfer" `Quick honest;
          Alcotest.test_case "02 weights stay in" `Quick weights;
          Alcotest.test_case "03 only Open enables the gate" `Quick enable;
          Alcotest.test_case "07 a bad tag never delivers" `Quick bad_tag;
          Alcotest.test_case "08 blocked is final" `Quick stays_blocked;
          Alcotest.test_case "09 the hazard line blocks at once" `Quick hazard;
          Alcotest.test_case "11 it can deliver twice" `Quick twice;
          Alcotest.test_case "a response waits for the buffer" `Quick waits;
          Alcotest.test_case "12b the next pulse blocks" `Quick next_pulse_blocks;
          Alcotest.test_case "a machine that never loads" `Quick never_loads;
          Alcotest.test_case "the --run script" `Quick script ] );
      ( "one board",
        [ Alcotest.test_case "an unknown symbol" `Quick unknown_symbol;
          Alcotest.test_case "both fibres in one cycle" `Quick both_fibres;
          Alcotest.test_case "a tag while Idle" `Quick tag_while_idle;
          Alcotest.test_case "a payload on the control fibre" `Quick payload_on_control_fibre;
          Alcotest.test_case "light on a full detector" `Quick light_on_a_full_detector;
          Alcotest.test_case "load takes only a payload" `Quick load_must_be_a_payload;
          Alcotest.test_case "the hazard pin" `Quick hazard_pin;
          Alcotest.test_case "a pulse on the data fibre" `Quick pulse_on_data_fibre;
          Alcotest.test_case "a response waits, then is taken" `Quick waits_then_taken;
          Alcotest.test_case "Verilog" `Quick verilog;
          Alcotest.test_case "the codes, by name" `Quick codes ] ) ]
