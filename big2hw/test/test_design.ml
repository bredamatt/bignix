(* What big2hw reads from the model: symbols, machines, pins and fibres. *)

open Big2hw
open Common

let names (m : Design.machine) =
  Array.to_list m.states |> List.map (fun (s : Design.state) -> s.name)

(* The transitions of a machine, as (from, label, to). *)
let table (m : Design.machine) =
  Array.to_list m.states
  |> List.concat_map (fun (s : Design.state) ->
         List.map (fun (label, t) -> (s.name, label, m.states.(t).name)) s.trans)
  |> List.sort compare

let triple = Alcotest.(list (triple string string string))

let symbols () =
  let d = design () in
  Alcotest.(check (list string)) "what light can carry, from the rules"
    [ "Pulse"; "Tag"; "BadTag"; "Response"; "Weights" ] d.symbols;
  Alcotest.(check (list string)) "what a buffer can hold, from the rules"
    [ "Response"; "Weights" ] d.payloads

let transmit () =
  let d = design () in
  Alcotest.(check string) "its board is named after the realm" "server_room" d.tx.board;
  Alcotest.(check (list string)) "the state the token is on comes first"
    [ "TxIdle"; "TxLoaded"; "TxRequested"; "TxTagged" ] (names d.tx.machine);
  Alcotest.check triple "transitions"
    [ ("TxIdle", "Load", "TxLoaded"); ("TxLoaded", "SendPulse", "TxRequested");
      ("TxRequested", "SendTag", "TxTagged"); ("TxTagged", "SendPayload", "TxIdle") ]
    (table d.tx.machine);
  Alcotest.(check (option string)) "control pin" (Some "ctl_o") d.tx.ctl;
  Alcotest.(check (option string)) "data pin" (Some "dat_o") d.tx.dat

let control () =
  let d = design () in
  Alcotest.(check string) "board" "interface" d.rx.board;
  Alcotest.(check (list string)) "states" [ "Idle"; "Armed"; "Open"; "Blocked" ]
    (names d.rx.machine);
  Alcotest.check triple "transitions"
    [ ("Armed", "Tag", "Open"); ("Idle", "Pulse", "Armed"); ("Open", "Response", "Idle") ]
    (table d.rx.machine);
  Alcotest.(check (list string)) "only Open drives the gate's enable wire" [ "Open" ]
    (List.map (fun i -> d.rx.machine.states.(i).name) d.rx.enable);
  Alcotest.(check string) "the state it fails to" "Blocked"
    d.rx.machine.states.(d.rx.blocked).name;
  Alcotest.(check bool) "it reads the hazard line" true d.rx.hazard

let wiring () =
  let d = design () in
  Alcotest.(check (list (pair string bool))) "inputs: the one on the gate is last"
    [ ("ctl_i", false); ("dat_i", true) ]
    (List.map (fun (i : Design.input) -> (i.port, i.gated)) d.rx.inputs);
  Alcotest.(check (list (pair string string))) "fibres: transmit pin to receive pin"
    [ ("ctl_o", "ctl_i"); ("dat_o", "dat_i") ]
    (List.sort compare d.fibres)

let edited_machine () =
  let d = design ~file:(variant idle_takes_tag) () in
  Alcotest.check triple "the machine is read from the bigraph, not from the rules"
    [ ("Armed", "Tag", "Open"); ("Idle", "Pulse", "Armed"); ("Idle", "Tag", "Open");
      ("Open", "Response", "Idle") ]
    (table d.rx.machine)

let observe () =
  let m = Bg.load file in
  let d = Design.of_model ~name:"crs" m in
  Alcotest.(check (list (pair string string))) "the first state of the model"
    [ ("alarm", "0"); ("at.ctl_i", "-"); ("at.dat_i", "-"); ("cc", "Idle");
      ("rx.buf", "-"); ("tx", "TxIdle"); ("tx.buf", "-") ]
    (Design.observe d (Bg.of_big m.init))

(* ---- Models big2hw does not build ---- *)

let refuses what edits part () =
  let msg = refusal edits in
  if not (contains msg part) then Alcotest.failf "%s: the message was: %s" what msg

let refusals =
  [ ( "Blocked with a way out",
      [ ("State{c3}.Blocked", "State{c3}.(Blocked | Trans.(Pulse | To{c0}))") ],
      "Blocked" );
    ( "no Blocked state",
      [ ("State{c3}.Blocked", "State{c3}.TxIdle") ],
      "Blocked" );
    ( "two transitions with one label",
      [ ("State{c0}.(Idle  | Trans.(Pulse | To{c1}))",
         "State{c0}.(Idle  | Trans.(Pulse | To{c1}) | Trans.(Pulse | To{c2}))") ],
      "two transitions labelled Pulse" );
    ( "a payload accepted while the gate is closed",
      [ ("State{c1}.(Armed | Trans.(Tag | To{c2}))",
         "State{c1}.(Armed | Trans.(Tag | To{c2}) | Trans.(Response | To{c0}))") ],
      "Response" );
    ( "a transmit state with a choice",
      [ ("State{t1}.(TxLoaded    | Trans.(SendPulse   | To{t2}))",
         "State{t1}.(TxLoaded    | Trans.(SendPulse   | To{t2}) | Trans.(SendTag | To{t3}))") ],
      "two transitions" );
    ( "a tag with no credential",
      [ ("CtlOut{ctl_o} | DatOut{dat_o} | Buf.1 | Cred)", "CtlOut{ctl_o} | DatOut{dat_o} | Buf.1)") ],
      "Cred" );
    ( "two state registers for one block",
      [ ("| Now{c0, r_cc} );", "| Now{c0, r_cc} | Now{c1, r_cc} );") ],
      "state registers" );
    ( "a first state with a full buffer",
      [ ("| Rx.(NetIn{net} | Buf.1) ) );", "| Rx.(NetIn{net} | Buf.Response) ) );") ],
      "rx.buf=Response" );
    ( "both boards in one realm",
      [ ("ServerRoom.FPGA{b_tx}.(Laser{ctl_o, ctl_f}", "Interface.FPGA{b_tx}.(Laser{ctl_o, ctl_f}") ],
      "both boards" );
    ( "a fibre that nothing reads",
      [ ("CC{r_cc}.(In{ctl_i} | In{dat_i} | HazIn{hz})", "CC{r_cc}.(In{dat_i} | HazIn{hz})") ],
      "no In pin" );
    ( "light that carries two things at once",
      [ ("Detector{f, i}.Light.Pulse || Tx{r}.(CtlOut{o} | id)",
         "Detector{f, i}.Light.(Pulse | Tag) || Tx{r}.(CtlOut{o} | id)") ],
      "one symbol" ) ]

let identifier () =
  Alcotest.(check string) "a file name that is no Verilog name" "my_model_v2"
    (Design.identifier "my-model.v2");
  Alcotest.(check string) "a leading digit" "m_2nd" (Design.identifier "2nd");
  Alcotest.(check string) "a good name is kept" "crs" (Design.identifier "crs")

let () =
  Alcotest.run "design"
    [ ( "read",
        [ Alcotest.test_case "symbols" `Quick symbols;
          Alcotest.test_case "transmit machine" `Quick transmit;
          Alcotest.test_case "channel control" `Quick control;
          Alcotest.test_case "wiring" `Quick wiring;
          Alcotest.test_case "an edited machine" `Quick edited_machine;
          Alcotest.test_case "observation" `Quick observe;
          Alcotest.test_case "design names" `Quick identifier ] );
      ( "refuse",
        List.map
          (fun (what, edits, part) -> Alcotest.test_case what `Quick (refuses what edits part))
          refusals ) ]
