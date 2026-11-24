(* The two circuits and what surrounds them, simulated together, one clock
   cycle at a time. *)

open Hardcaml

(* What the surroundings do in one cycle. *)
type step = {
  load : string option;  (** The sending realm's software hands over this payload. *)
  damage : bool;  (** A tag on a fibre in this cycle is damaged. *)
  tamper : bool;  (** The tamper sensor trips. *)
  take : bool;  (** The receiving realm takes the response. *)
}

let idle = { load = None; damage = false; tamper = false; take = false }

(* A run, written as text: "load Response, -, damage + take" is three cycles.
   In a cycle the surroundings do any of load PAYLOAD, damage, tamper and
   take, joined by +. In the cycle - they do nothing. *)
let parse (d : Design.t) text =
  let need ok what = if not ok then Bg.error "--run: %s" what in
  let word (s : step) w =
    match String.split_on_char ' ' (String.trim w) |> List.filter (( <> ) "") with
    | [] | [ "-" ] -> s
    | [ "load"; p ] ->
        need (List.mem p d.payloads)
          (Printf.sprintf "%s is not a payload of the model (%s)" p (String.concat ", " d.payloads));
        { s with load = Some p }
    | [ "damage" ] ->
        need (Hw.can_damage d) "the model has no Tag and BadTag, so nothing to damage";
        { s with damage = true }
    | [ "tamper" ] ->
        need d.sensor "the model has no tamper sensor";
        { s with tamper = true }
    | [ "take" ] -> { s with take = true }
    | _ ->
        Bg.error "--run: %s is not load PAYLOAD, damage, tamper, take or -" (String.trim w)
  in
  String.split_on_char ',' text
  |> List.map (fun cycle -> List.fold_left word idle (String.split_on_char '+' cycle))

(* What one cycle looked like. *)
type seen = {
  fibres : (string * string) list;  (** What reached each receive pin in the cycle. *)
  enable : bool;  (** The gate's enable wire, in the cycle. *)
  clash : bool;  (** Light reached the data detector while a payload still waited there. *)
  obs : Design.obs;  (** The state after the cycle, named as [Design.observe] names it. *)
}

type t = { design : Design.t; sim : Cyclesim.t_port_list }

(* With [vcd], every cycle is also written to that channel as waveforms. *)
let create ?vcd design =
  let sim = Cyclesim.create (Hw.testbench design) in
  { design; sim = (match vcd with Some ch -> Vcd.wrap ch sim | None -> sim) }

(* Hardcaml drops an input that nothing reads: a machine with no Load
   transition has no load port. There is then nothing to set. *)
let set t name width value =
  match List.assoc_opt name (Cyclesim.in_ports t.sim) with
  | Some port -> port := Bits.of_int ~width value
  | None -> ()

let get ?(during = false) t name =
  Bits.to_int !(Cyclesim.out_port ~clock_edge:(if during then Before else After) t.sim name)

let symbol (d : Design.t) code =
  if code = 0 then "-"
  else
    match List.nth_opt d.symbols (code - 1) with
    | Some s -> s
    | None -> Printf.sprintf "?%d" code

let state (m : Design.machine) code =
  if code < Array.length m.states then m.states.(code).name else Printf.sprintf "?%d" code

let drive t (s : step) =
  let d = t.design in
  set t "load" (Hw.sym_width d) (match s.load with None -> 0 | Some p -> Hw.code d p);
  if Hw.can_damage d then set t "damage" 1 (Bool.to_int s.damage);
  if d.sensor then set t "tamper" 1 (Bool.to_int s.tamper);
  set t "rx_take" 1 (Bool.to_int s.take)

let reset t =
  drive t idle;
  set t "clear" 1 1;
  Cyclesim.cycle t.sim;
  set t "clear" 1 0

(* The state the circuits are in, named as [Design.observe] names it. *)
let observe t : Design.obs =
  let d = t.design in
  let obs =
    [ ("alarm", if d.sensor then string_of_int (get t "alarm") else "0");
      ("tx", state d.tx.machine (get t "tx_state"));
      ("tx.buf", symbol d (get t "tx_buf"));
      ("cc", state d.rx.machine (get t "cc_state"));
      ("rx.buf", symbol d (get t "rx_buf")) ]
    @ List.map
        (fun (i : Design.input) ->
          ("at." ^ i.port, if i.gated then symbol d (get t "dat_held") else "-"))
        d.rx.inputs
  in
  List.sort compare obs

let cycle t (s : step) =
  let d = t.design in
  drive t s;
  Cyclesim.cycle t.sim;
  {
    fibres =
      List.map (fun (i : Design.input) -> (i.port, symbol d (get ~during:true t i.port))) d.rx.inputs;
    enable = get ~during:true t "gate_enable" = 1;
    clash = get ~during:true t "dat_clash" = 1;
    obs = observe t;
  }
