(* The circuits, built with Hardcaml from a design.

   A symbol on a fibre or in a buffer is a number: 0 is nothing, and the
   symbols of the design are 1, 2, ... in order. A state register holds the
   code of the current state; cleared, it holds the state the token is on in
   the bigraph. *)

open Hardcaml
open Signal

let sym_width (d : Design.t) = num_bits_to_represent (List.length d.symbols)

let code (d : Design.t) s =
  match Design.index s d.symbols with
  | Some i -> i + 1
  | None -> Bg.error "%s is not a symbol of the model" s

let can_damage (d : Design.t) = List.mem "Tag" d.symbols && List.mem "BadTag" d.symbols
let state_width (m : Design.machine) = Stdlib.max 1 (address_bits_for (Array.length m.states))
let any = List.fold_left ( |: ) gnd

(* Every transition of a machine, as (code of its state, label, code of the
   state it leads to). *)
let transitions (m : Design.machine) =
  Array.to_list m.states
  |> List.mapi (fun i (s : Design.state) -> List.map (fun (label, t) -> (i, label, t)) s.trans)
  |> List.concat

(* ---- The transmit side ---- *)

type sender = { ctl : t; dat : t; tx_state : t; tx_buf : t }

(* The transmit machine takes the one transition out of its state each cycle.
   The label says what it does on the way:

     Load         waits for the software to hand over a payload, and stores it
     SendPulse    puts Pulse on the control fibre
     SendTag      puts Tag on the data fibre
     SendPayload  puts the stored payload on the data fibre *)
let sender (d : Design.t) spec ~load =
  let m = d.tx.machine and w = sym_width d in
  let sw = state_width m in
  let sym s = of_int ~width:w (code d s) in
  let next_state = wire sw and next_buf = wire w in
  let state = reg spec next_state -- "tx_state_reg" and buf = reg spec next_buf -- "tx_buf_reg" in
  (* As in the rules: a payload is loaded only into an empty buffer. *)
  let loadable = any (List.map (fun p -> load ==: sym p) d.payloads) &: (buf ==:. 0) in
  (* Each transition, with the signal that is high in the cycle it is taken. *)
  let taken =
    List.map
      (fun (i, label, target) ->
        let go = (state ==:. i) &: if label = "Load" then loadable else vdd in
        (label, target, go -- ("do_" ^ Design.snake label)))
      (transitions m)
  in
  (* [value ()] in a cycle in which a transition labelled [label] is taken. *)
  let on label value otherwise =
    List.fold_left
      (fun acc (l, _, go) -> if l = label then mux2 go (value ()) acc else acc)
      otherwise taken
  in
  next_state
  <== List.fold_left
        (fun acc (_, target, go) -> mux2 go (of_int ~width:sw target) acc)
        state taken;
  next_buf <== on "SendPayload" (fun () -> zero w) (on "Load" (fun () -> load) buf);
  {
    ctl = on "SendPulse" (fun () -> sym "Pulse") (zero w);
    dat = on "SendPayload" (fun () -> buf) (on "SendTag" (fun () -> sym "Tag") (zero w));
    tx_state = state;
    tx_buf = buf;
  }

(* ---- The receive side ---- *)

type receiver = { cc_state : t; rx_buf : t; held : t; enable : t; clash : t }

(* In one cycle, in this order:

     1. The hazard line, if up, puts the channel control in Blocked.
     2. The receiving realm takes the response out of the receive buffer.
     3. Each fibre is read in turn. A symbol the current state has a
        transition for moves the machine along it. Any other symbol, also a
        code that is no symbol, moves it to Blocked.
     4. A payload the current state has a transition for passes the gate into
        the receive buffer, if that state drives the enable wire and the
        buffer is empty. If the buffer is full it waits at the detector. *)
let receiver (d : Design.t) spec ~inputs ~hazard ~take =
  let m = d.rx.machine and w = sym_width d in
  let sw = state_width m in
  let st i = of_int ~width:sw i in
  let blocked = st d.rx.blocked in
  let next_state = wire sw and next_buf = wire w and next_held = wire w in
  let state = reg spec next_state -- "cc_state_reg"
  and buf = reg spec next_buf -- "rx_buf_reg"
  and held = reg spec next_held -- "dat_held_reg" in
  let steps, carries =
    List.partition (fun (_, label, _) -> not (List.mem label d.payloads)) (transitions m)
  in
  (* [s] has transition [e], and the symbol [x] is its label. *)
  let hit s x (i, label, _) = (s ==:. i) &: (x ==:. code d label) in
  let target s x among =
    List.fold_left (fun acc ((_, _, t) as e) -> mux2 (hit s x e) (st t) acc) blocked among
  in
  (* The state after [x] arrives in state [s]. No light: no change. *)
  let step s x = mux2 (x ==:. 0) s (target s x steps) in
  let after_hazard = mux2 hazard blocked state -- "cc_after_hazard" in
  let after_take = mux2 take (zero w) buf -- "rx_buf_after_take" in
  let plain, gated =
    List.partition (fun ((i : Design.input), _) -> not i.gated) (List.combine d.rx.inputs inputs)
  in
  let s =
    List.fold_left
      (fun s ((i : Design.input), x) -> step s x -- ("cc_after_" ^ i.port))
      after_hazard plain
  in
  let arriving = match gated with [ (_, x) ] -> x | _ -> Bg.error "one input must be on the gate" in
  (* What is at the data detector: what waits there, or else what arrives. *)
  let x = mux2 (held ==:. 0) arriving held -- "at_gate" in
  (* Light arrives while the detector is full. The model's transmit logic
     waits for a free detector, which over a diode it cannot see. *)
  let clash = (held <>:. 0) &: (arriving <>:. 0) in
  let enable = any (List.map (fun i -> s ==:. i) d.rx.enable) -- "enable_wire" in
  let net = mux2 (enable &: any (List.map (hit s x) carries)) x (zero w) -- "gate_net" in
  let passes = net <>:. 0 in
  let free = after_take ==:. 0 in
  let carry = (passes &: free &: ~:clash) -- "carry"
  and wait = (passes &: ~:free &: ~:clash) -- "wait_for_buffer" in
  next_state
  <== mux2 clash blocked (mux2 carry (target s x carries) (mux2 wait s (step s x)));
  next_buf <== mux2 carry net after_take;
  next_held <== mux2 wait x (zero w);
  { cc_state = state; rx_buf = buf; held; enable; clash }

(* ---- Circuits ---- *)

let clocked () = Reg_spec.create ~clock:(input "clock" 1) ~clear:(input "clear" 1) ()

let sender_ports (d : Design.t) (s : sender) =
  List.filter_map
    (fun (port, signal) -> Option.map (fun p -> output p signal) port)
    [ (d.tx.ctl, s.ctl); (d.tx.dat, s.dat) ]
  @ [ output "tx_state" s.tx_state; output "tx_buf" s.tx_buf ]

let receiver_ports (r : receiver) =
  [ output "rx_buf" r.rx_buf; output "cc_state" r.cc_state;
    output "gate_enable" r.enable; output "dat_held" r.held; output "dat_clash" r.clash ]

(* The FPGA in the sending realm. *)
let sender_circuit (d : Design.t) =
  let s = sender d (clocked ()) ~load:(input "load" (sym_width d)) in
  Circuit.create_exn ~name:(d.name ^ "_" ^ d.tx.board) (sender_ports d s)

(* The FPGA in the receiving realm. *)
let receiver_circuit (d : Design.t) =
  let w = sym_width d in
  let r =
    receiver d (clocked ())
      ~inputs:(List.map (fun (i : Design.input) -> input i.port w) d.rx.inputs)
      ~hazard:(if d.rx.hazard then input "haz_i" 1 else gnd)
      ~take:(input "rx_take" 1)
  in
  Circuit.create_exn ~name:(d.name ^ "_" ^ d.rx.board) (receiver_ports r)

(* Both boards on one clock, with each fibre a wire from a transmit pin to a
   receive pin. With [env], also what surrounds them in the model: a tag can
   be damaged on its fibre, and a tamper sensor latches the hazard line. *)
let joined ~name ~env (d : Design.t) =
  let w = sym_width d and spec = clocked () in
  let tx = sender d spec ~load:(input "load" w) in
  let damage = if env && can_damage d then Some (input "damage" 1) else None in
  let fibre (i : Design.input) =
    let sent =
      match List.find_opt (fun (_, p) -> p = i.port) d.fibres with
      | Some (out, _) when Some out = d.tx.ctl -> tx.ctl
      | Some _ -> tx.dat
      | None -> Bg.error "no fibre reaches %s" i.port
    in
    match damage with
    | Some damage ->
        mux2 (damage &: (sent ==:. code d "Tag")) (of_int ~width:w (code d "BadTag")) sent
    | None -> sent
  in
  let arriving = List.map fibre d.rx.inputs in
  (* The sensor, once tripped, holds the hazard line up. *)
  let line, alarm =
    if env && d.sensor then
      let tamper = input "tamper" 1 in
      let alarm = reg_fb spec ~width:1 ~f:(fun a -> a |: tamper) in
      (alarm |: tamper, [ output "alarm" alarm ])
    else if d.rx.hazard then (input "haz_i" 1, [])
    else (gnd, [])
  in
  let hazard = if d.rx.hazard then line else gnd in
  let rx = receiver d spec ~inputs:arriving ~hazard ~take:(input "rx_take" 1) in
  let seen =
    if env then List.map2 (fun (i : Design.input) x -> output i.port x) d.rx.inputs arriving
    else []
  in
  Circuit.create_exn ~name (sender_ports d tx @ receiver_ports rx @ seen @ alarm)

let system_circuit (d : Design.t) = joined ~name:d.name ~env:false d
let testbench (d : Design.t) = joined ~name:(d.name ^ "_tb") ~env:true d

let verilog circuit =
  let buffer = Buffer.create 4096 in
  Rtl.output ~output_mode:(To_buffer buffer) Verilog circuit;
  Buffer.contents buffer
