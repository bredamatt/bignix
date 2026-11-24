(* The hardware a bigraph describes: two FPGA boards, the state machine on
   each, and the fibres between them.

   The controls have fixed meanings:

     Layout{b}           what is configured on the FPGA board on link b
     Tx{r}, CC{r}        a block, and the state register of its machine
     CtlOut, DatOut      pins of Tx that drive a laser
     In, HazIn           pins of CC that read a detector, and the sensor
     Gate, Rx, Buf       the data path: a gate, receive logic, a buffer
     Machine, State, Trans, To, Now, Drive
                         a state machine, written out
     Laser, Detector     the two ends of a fibre
     Light               what has reached a detector *)

let error = Bg.error

type state = {
  name : string;
  trans : (string * int) list;  (** Label, and the code of the state it leads to. *)
}

(* The code of a state is its place in [states]. The state the token is on
   has code 0, so a cleared state register holds it. *)
type machine = { states : state array }

type sender = {
  board : string;
  machine : machine;
  ctl : string option;  (** The port that drives the control laser. *)
  dat : string option;  (** The port that drives the data laser. *)
}

type input = {
  port : string;
  gated : bool;  (** The gate's data input is on the same detector. *)
}

type receiver = {
  board : string;
  machine : machine;
  inputs : input list;  (** The gated one is last. *)
  hazard : bool;  (** It reads a hazard line. *)
  enable : int list;  (** The states that drive the gate's enable wire. *)
  blocked : int;  (** The state it fails to. *)
}

type t = {
  name : string;
  symbols : string list;  (** What light can carry. Code 0 is no light, the first is 1. *)
  payloads : string list;  (** The symbols a buffer can hold. *)
  tx : sender;
  rx : receiver;
  sensor : bool;  (** A tamper sensor stands in the receiving realm. *)
  fibres : (string * string) list;  (** A port of [tx], and the port of [rx] it reaches. *)
}

(* What changes from one state of the model to the next, by name. *)
type obs = (string * string) list

(* ---- Names ---- *)

(* ServerRoom is server_room. *)
let snake s =
  String.to_seq s |> List.of_seq
  |> List.mapi (fun i c ->
         let low = String.make 1 (Char.lowercase_ascii c) in
         if i > 0 && c <> Char.lowercase_ascii c then "_" ^ low else low)
  |> String.concat ""

(* A name Verilog accepts for a module: my-model.v2 is my_model_v2. *)
let identifier s =
  let ok c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' in
  let s = String.map (fun c -> if ok c then c else '_') s in
  if s = "" || (s.[0] >= '0' && s.[0] <= '9') then "m_" ^ s else s

let out_port pin = snake (String.sub pin 0 (String.length pin - 3)) ^ "_o"
let in_port out = String.sub out 0 (String.length out - 1) ^ "i"

let distinct l =
  List.fold_left (fun acc x -> if List.mem x acc then acc else acc @ [ x ]) [] l

let index x l =
  let rec go i = function [] -> None | y :: _ when y = x -> Some i | _ :: r -> go (i + 1) r in
  go 0 l

(* ---- What light carries, and what a buffer holds ---- *)

(* Read from every rule: the controls that appear inside a Light, and inside
   a Buf. *)
let alphabet (bigs : Bg.t list) =
  let inside parent =
    List.concat_map
      (fun b ->
        Bg.with_ctrl b parent
        |> List.concat_map (fun i ->
               match Bg.children b i with
               | [] | [ _ ] -> List.map (Bg.ctrl b) (Bg.children b i)
               | l ->
                   error
                     "a %s holds %d things in the first state or in a rule: it is one symbol or nothing"
                     parent (List.length l)))
      bigs
    |> distinct
  in
  let lights = inside "Light" and payloads = inside "Buf" in
  (lights @ List.filter (fun p -> not (List.mem p lights)) payloads, payloads)

(* ---- Machines ---- *)

(* The one child of [i] that is not one of [parts]: its name or its label. *)
let name_in b i ~parts ~what =
  match List.filter (fun k -> not (List.mem (Bg.ctrl b k) parts)) (Bg.children b i) with
  | [ k ] -> Bg.ctrl b k
  | ks -> error "%s holds %d names, not one" what (List.length ks)

let contents b i =
  match Bg.children b i with
  | [] -> "-"
  | ks -> String.concat "+" (List.map (Bg.ctrl b) ks)

(* The machine whose state register is on link [r], and for each state the
   wires it drives. *)
let machine b ~owner r =
  let now =
    match Bg.on_link b r "Now" with
    | [ n ] -> n
    | l -> error "%s has %d state registers (Now), not one" owner (List.length l)
  in
  let home =
    match b.Bg.nodes.(now).parent with
    | Some m -> m
    | None -> error "the state register of %s is in no Machine" owner
  in
  let all = Bg.kids b home "State" in
  let current =
    match List.filter (fun s -> List.mem s all) (Bg.on_link b (Bg.other_link b now r) "State") with
    | [ s ] -> s
    | _ -> error "the state register of %s is not on one state of its machine" owner
  in
  let state_on l =
    match List.filter (fun s -> List.mem s all) (Bg.on_link b l "State") with
    | [ s ] -> s
    | _ -> error "a transition of %s leads to no state of its machine" owner
  in
  (* A state as written: its node, name, transitions and the wires it drives. *)
  let read s =
    let name = name_in b s ~parts:[ "Trans"; "Drive" ] ~what:("a state of " ^ owner) in
    let trans =
      Bg.kids b s "Trans"
      |> List.map (fun tr ->
             let label =
               name_in b tr ~parts:[ "To" ] ~what:("a transition out of " ^ name)
             in
             match Bg.kids b tr "To" with
             | [ t ] -> (label, state_on (Bg.link b t))
             | _ -> error "the transition %s out of %s must lead to one state" label name)
      |> List.sort compare
    in
    List.iter
      (fun (label, _) ->
        if List.length (List.filter (fun (l, _) -> l = label) trans) > 1 then
          error "%s has two transitions labelled %s: the circuit cannot choose" name label)
      trans;
    (s, name, trans, List.map (Bg.link b) (Bg.kids b s "Drive"))
  in
  let written = List.map read all in
  let node_of (s, _, _, _) = s and name_of (_, n, _, _) = n in
  let names = List.map name_of written in
  if List.length (distinct names) <> List.length names then
    error "two states of %s have one name" owner;
  (* Codes: the current state, then the states its transitions lead to in
     turn, then the states no transition leads to, by name. *)
  let rec walk seen s =
    if List.mem s seen then seen
    else
      let _, _, trans, _ = List.find (fun w -> node_of w = s) written in
      List.fold_left (fun seen (_, t) -> walk seen t) (seen @ [ s ]) trans
  in
  let reached = walk [] current in
  let rest =
    List.filter (fun w -> not (List.mem (node_of w) reached)) written
    |> List.sort (fun a b -> compare (name_of a) (name_of b))
    |> List.map node_of
  in
  let order = reached @ rest in
  let code s = Option.get (index s order) in
  let states =
    List.map
      (fun s ->
        let _, name, trans, drives = List.find (fun w -> node_of w = s) written in
        ({ name; trans = List.map (fun (l, t) -> (l, code t)) trans }, drives))
      order
  in
  ({ states = Array.of_list (List.map fst states) }, List.map snd states)

let labels (m : machine) =
  Array.to_list m.states |> List.concat_map (fun (s : state) -> List.map fst s.trans) |> distinct

(* ---- The transmit side ---- *)

let actions = [ "Load"; "SendPulse"; "SendTag"; "SendPayload" ]

(* From an output pin: across its laser and the fibre, to the link that the
   detector at the far end is read on. *)
let across b ~pin p =
  let o = Bg.link b p in
  match Bg.on_link b o "Laser" with
  | [ laser ] -> (
      let fibre = Bg.other_link b laser o in
      match Bg.on_link b fibre "Detector" with
      | [ det ] -> Bg.other_link b det fibre
      | _ -> error "the fibre from %s does not end at one detector" pin)
  | _ -> error "%s must drive one laser" pin

let sender b ~board ~symbols tx =
  let pin c =
    match Bg.kids b tx c with
    | [] -> None
    | [ p ] -> Some (out_port c, across b ~pin:c p)
    | _ -> error "Tx has two %s pins" c
  in
  let ctl = pin "CtlOut" and dat = pin "DatOut" in
  let has c = Bg.kids b tx c <> [] in
  let m, _ = machine b ~owner:"Tx" (Bg.link b tx) in
  Array.iter
    (fun (s : state) ->
      if List.length s.trans > 1 then
        error "the transmit state %s has two transitions: the circuit cannot choose" s.name)
    m.states;
  let used = labels m in
  List.iter
    (fun l ->
      if not (List.mem l actions) then
        error "the transmit machine has a transition %s: Tx can only %s" l
          (String.concat ", " actions))
    used;
  let need label what ok =
    if List.mem label used && not ok then
      error "the transmit machine has a transition %s, and Tx has no %s" label what
  in
  need "SendPulse" "CtlOut pin" (ctl <> None);
  need "SendPulse" "symbol Pulse in the rules" (List.mem "Pulse" symbols);
  need "SendTag" "DatOut pin" (dat <> None);
  need "SendTag" "Cred" (has "Cred");
  need "SendTag" "symbol Tag in the rules" (List.mem "Tag" symbols);
  need "SendPayload" "DatOut pin" (dat <> None);
  need "SendPayload" "Buf" (has "Buf");
  need "Load" "Buf" (has "Buf");
  let tx_obs =
    [ ("tx", m.states.(0).name);
      ("tx.buf", match Bg.kids b tx "Buf" with [ buf ] -> contents b buf | _ -> "-") ]
  in
  ( { board; machine = m; ctl = Option.map fst ctl; dat = Option.map fst dat },
    List.filter_map (fun p -> p) [ ctl; dat ],
    tx_obs )

(* ---- The receive side ---- *)

let receiver b ~board ~layout ~symbols ~payloads ~fibres cc =
  let m, drives = machine b ~owner:"CC" (Bg.link b cc) in
  let one node c =
    match Bg.kids b node c with
    | [ p ] -> p
    | l -> error "%s needs one %s, and has %d" (Bg.ctrl b node) c (List.length l)
  in
  let gate = one layout "Gate" in
  let gate_in = Bg.link b (one gate "DatIn")
  and enable_wire = Bg.link b (one gate "Enable")
  and net = Bg.link b (one gate "NetOut") in
  let rx =
    match List.filter_map (fun p -> b.Bg.nodes.(p).parent) (Bg.on_link b net "NetIn") with
    | [ rx ] when Bg.ctrl b rx = "Rx" && b.Bg.nodes.(rx).parent = Some layout -> rx
    | _ -> error "the gate's NetOut must reach the NetIn of one Rx in the same layout"
  in
  let buf = one rx "Buf" in
  let detector l =
    match Bg.on_link b l "Detector" with
    | [ det ] -> det
    | _ -> error "an In pin of CC must read one detector"
  in
  let inputs =
    Bg.kids b cc "In"
    |> List.map (fun p ->
           let l = Bg.link b p in
           let det = detector l in
           match List.find_opt (fun (_, far) -> far = l) fibres with
           | Some (out, _) -> ({ port = in_port out; gated = l = gate_in }, det)
           | None -> error "an In pin of CC reads a detector that no pin of Tx drives")
    |> List.sort (fun (a, _) (b, _) -> compare (a.gated, a.port) (b.gated, b.port))
  in
  if List.length (List.filter (fun (i, _) -> i.gated) inputs) <> 1 then
    error "the gate's DatIn must be on the detector of one In pin of CC";
  let hazard =
    match Bg.kids b cc "HazIn" with
    | [] -> false
    | [ p ] when Bg.on_link b (Bg.link b p) "Sensor" <> [] -> true
    | _ -> error "CC needs at most one HazIn, and it must read a Sensor"
  in
  let states = Array.to_list m.states in
  let blocked =
    match index "Blocked" (List.map (fun (s : state) -> s.name) states) with
    | Some i when m.states.(i).trans = [] -> i
    | Some _ -> error "Blocked has a transition out: the channel control must stay Blocked"
    | None -> error "the channel control has no state named Blocked to fail to"
  in
  let enable =
    List.concat (List.mapi (fun i d -> if List.mem enable_wire d then [ i ] else []) drives)
  in
  List.iter
    (fun l ->
      if not (List.mem l symbols) then
        error "the channel control has a transition %s, which no rule puts on a fibre" l)
    (labels m);
  List.iteri
    (fun i (s : state) ->
      List.iter
        (fun (l, _) ->
          if List.mem l payloads && not (List.mem i enable) then
            error
              "%s has a transition for the payload %s and does not drive the gate: no rule carries it"
              s.name l)
        s.trans)
    states;
  let light det =
    match Bg.kids b det "Light" with
    | [] -> "-"
    | [ l ] -> ( match contents b l with "-" -> "Light" | c -> c)
    | _ -> "?"
  in
  let rx_obs =
    [ ("cc", m.states.(0).name); ("rx.buf", contents b buf) ]
    @ List.map (fun (i, det) -> ("at." ^ i.port, light det)) inputs
  in
  ({ board; machine = m; inputs = List.map fst inputs; hazard; enable; blocked }, rx_obs)

(* ---- The whole design ---- *)

(* The board a layout is configured on, named after the realm it stands in. *)
let board_of b layout =
  match Bg.on_link b (Bg.link b layout) "FPGA" with
  | [ fpga ] -> (
      match b.Bg.nodes.(fpga).parent with
      | Some realm -> snake (Bg.ctrl b realm)
      | None -> error "an FPGA board stands in no realm")
  | _ -> error "a Layout must be on the link of one FPGA board"

let read ~name ~symbols ~payloads b =
  let layouts = Bg.with_ctrl b "Layout" in
  let find c =
    match List.concat_map (fun l -> List.map (fun x -> (l, x)) (Bg.kids b l c)) layouts with
    | [ found ] -> found
    | l -> error "big2hw builds one %s block, and the model has %d" c (List.length l)
  in
  let tx_layout, tx_node = find "Tx" and rx_layout, cc_node = find "CC" in
  if board_of b tx_layout = board_of b rx_layout then
    error "both boards stand in %s: big2hw builds one board in each of two realms"
      (board_of b tx_layout);
  let tx, far, tx_obs = sender b ~board:(board_of b tx_layout) ~symbols tx_node in
  let rx, rx_obs =
    receiver b ~board:(board_of b rx_layout) ~layout:rx_layout ~symbols ~payloads
      ~fibres:far cc_node
  in
  let sensors = Bg.with_ctrl b "Sensor" in
  let alarm = List.exists (fun s -> Bg.kids b s "Alarm" <> []) sensors in
  let fibres =
    List.map
      (fun (out, _) ->
        if List.exists (fun i -> i.port = in_port out) rx.inputs then (out, in_port out)
        else error "the fibre from %s ends at a detector that no In pin of CC reads" out)
      far
  in
  ( { name; symbols; payloads; tx; rx; sensor = sensors <> []; fibres },
    List.sort compare ((("alarm", if alarm then "1" else "0") :: tx_obs) @ rx_obs) )

let of_model ~name (m : Bg.model) =
  let sides = List.concat_map (fun r -> [ Bg.PBRS.lhs r; Bg.PBRS.rhs r ]) (Bg.rules m) in
  let symbols, payloads = alphabet (List.map Bg.of_big (m.init :: sides)) in
  let d, first = read ~name ~symbols ~payloads (Bg.of_big m.init) in
  (* A cleared circuit has empty buffers, dark detectors and no alarm. *)
  List.iter
    (fun (key, value) ->
      let cleared = if key = "alarm" then "0" else "-" in
      if key <> "tx" && key <> "cc" && value <> cleared then
        error
          "the first state of the model has %s=%s: a circuit starts with empty buffers, nothing at the detectors and the alarm down"
          key value)
    first;
  d

(* What a state of the model looks like from outside: where each token is,
   what each buffer and detector holds, and whether the alarm is up. *)
let observe (d : t) b : obs = snd (read ~name:d.name ~symbols:d.symbols ~payloads:d.payloads b)

let show (o : obs) = String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ v) o)
