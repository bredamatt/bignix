(* What the parts of a bigraph do, as text for UPPAAL.

   Every expression is over the clocks NAME[j][c] of one plant, the
   constants K...[j] of one configuration j, and the activity act[j][c][w]
   of the workers of one copy c. The same text serves every configuration
   and every copy; only the values of the constants differ between
   configurations. *)

open Topo

(* What keeps a state of its own: each GPU, each GPU tray, each rack, or the
   module as a whole. *)
type level = Chip | Tray | Rack | Module

let level_of_string = function
  | "chip" -> Chip
  | "tray" -> Tray
  | "rack" -> Rack
  | "module" -> Module
  | s -> error "unknown level %s: use chip, tray, rack or module" s

type channel = {
  kind : string;  (** power, thermal, network, telemetry, rf or sound *)
  about : string;  (** The instrument and what it reads. *)
  expr : string option;  (** What a plant shows it. None: the gateway. *)
  period : string;  (** Name of the constant: seconds between readings. *)
  sigma : string;  (** Name of the constant: noise of one reading. *)
}

type secrets = {
  pre_ms : float;
  tok_ms : float;
  load : float;
  gpus : int;
  p_lo : float;
  p_hi : float;
  r_lo : float;
  r_hi : float;
  it_node : int;
  it_index : int;
  it_tokens : float;
}

type t = {
  consts : (string * float) list;
  clocks : string list;  (** Names. Each is an array: NAME[j][c]. *)
  odes : string list;  (** One equation per clock, in the same order. *)
  settle : string list;
      (** One assignment per clock, in the same order: the clock takes the
          value it tends to. *)
  channels : channel list;
  workers : int;
  slots : int;  (** The most GPUs one worker has. *)
  gap : float;
  copies : (string * secrets) list;  (** The first is the actual run. *)
  gateway : (string * string * string) option;
      (** Names of the constants: mode, rate, bytes per token. *)
}

let sum = function [] -> "0.0" | l -> "(" ^ String.concat " + " l ^ ")"
let sp = Printf.sprintf
let one what = function [ x ] -> x | l -> error "%s: expected one, found %d" what (List.length l)

(* Controls that draw a constant power, and which parameter it is. *)
let constant_w =
  [ ("NIC", 0); ("NVSwitch", 0); ("CPU", 0); ("Board", 0); ("BMC", 0);
    ("Nexus", 0); ("MgmtSwitch", 0); ("RDHx", 1); ("CDU", 1) ]

let build ~level (t : Topo.t) =
  (match boundary_mismatches t with
  | [] -> ()
  | (r, d, missing, extra) :: _ ->
      let show l =
        String.concat ", " (List.map (fun (k, l) -> sp "%s on %s" k (describe_link t l)) l)
      in
      error "%s does not show the boundary of %s. Missing: [%s]. Not on the boundary: [%s]"
        r d (show missing) (show extra));
  let consts = ref [] in
  let name_k name v =
    (match List.assoc_opt name !consts with
    | None -> consts := (name, v) :: !consts
    | Some v' -> if v' <> v then error "constant %s has two values" name);
    name
  in
  let k name v = name_k name v ^ "[j]" in
  let kp i idx = k (sp "K%d_%d" i idx) (param t i idx) in
  let clocks = ref [] and odes = ref [] and settle = ref [] in
  (* A clock is an array with one element per configuration and copy, so
     that the equations of a plant can be spread over several processes. *)
  let clock name = name ^ "[j][c]" in
  let ode name rhs tau =
    clocks := name :: !clocks;
    odes := sp "%s' == (%s - %s)/%s" (clock name) rhs (clock name) tau :: !odes;
    settle := sp "%s = %s" (clock name) rhs :: !settle
  in
  (* The parts that hold a pin of this kind on this link. A Ref that a view
     opens is not a part: the view is. *)
  let parts kind l =
    holders t l kind |> List.filter (fun i -> not (opened t i)) |> List.sort_uniq compare
  in

  (* ---- Workers and the GPUs they use ---- *)
  let workers = with_ctrl t "Worker" in
  let gpu_job = Hashtbl.create 64 in
  List.iteri
    (fun w wp ->
      let l = Option.get (node t wp).link in
      List.filter (fun p -> ctrl t p = "Slot") t.links.(l)
      |> List.filter_map (fun p ->
             let tee = Option.get (node t p).parent in
             if ctrl t tee = "TEE" then (node t tee).parent else None)
      |> List.sort compare
      |> List.iteri (fun slot g -> Hashtbl.replace gpu_job g (w, slot)))
    workers;
  let slots = Hashtbl.fold (fun _ (_, s) m -> max m (s + 1)) gpu_job 1 in
  let gpus = with_ctrl t "GPU" in
  List.iter
    (fun g -> if not (Hashtbl.mem gpu_job g) then error "GPU %d runs no worker's job" g)
    gpus;

  (* ---- GPUs: one clock per GPU, per tray, per rack or for the module ---- *)
  let by key items =
    List.sort_uniq compare (List.map key items)
    |> List.map (fun v -> List.filter (fun x -> key x = v) items)
  in
  (* What lumps together at this level: the tray, the rack, or everything. *)
  let lump i =
    match level with
    | Chip -> Some i
    | Tray -> enclosing t i "Node"
    | Rack -> enclosing t i "Rack"
    | Module -> None
  in
  let groups = by lump gpus in
  let gname grp = sp "g%d" (List.hd grp) in
  let gclock grp = clock (gname grp) in
  let mean f grp = List.fold_left (fun a g -> a +. f g) 0.0 grp /. float (List.length grp) in
  let total f grp = List.fold_left (fun a g -> a +. f g) 0.0 grp in
  let idle g = param t g 0 and span g = param t g 1 -. param t g 0 in
  List.iter
    (fun grp ->
      let target =
        sum
          (List.map
             (fun g ->
               let w, slot = Hashtbl.find gpu_job g in
               sp "%s + (%s - %s)*ENG[c][%d]*act[j][c][%d]" (kp g 0) (kp g 1) (kp g 0) slot w)
             grp)
      in
      ode (gname grp) target (k (sp "T%d" (List.hd grp)) (mean (fun g -> param t g 2) grp)))
    groups;
  let gpu_pw g =
    match List.find_opt (fun grp -> List.hd grp = g) groups with
    | Some grp -> gclock grp
    | None -> "0.0"
  in
  (* How hard the GPUs of a node work, from 0 (idle) to 1. Above the tray,
     every node of a lump gets the mean of the lump. *)
  let frac nd =
    let mine =
      match level with
      | Chip | Tray -> List.filter (fun grp -> enclosing t (List.hd grp) "Node" = Some nd) groups
      | Rack | Module -> List.filter (fun grp -> lump (List.hd grp) = lump nd) groups
    in
    if mine = [] then "0.0"
    else
      let all = List.concat mine in
      let tag = sp "%d" (List.hd all) in
      sp "((%s - %s)/%s)"
        (sum (List.map gclock mine))
        (k ("I" ^ tag) (total idle all))
        (k ("S" ^ tag) (total span all))
  in
  let node_of i =
    match enclosing t i "Node" with
    | Some nd -> nd
    | None -> error "%s (node %d) is not in a Node" (ctrl t i) i
  in

  (* ---- Fans: one clock per node, per rack or for the module ---- *)
  let fans = with_ctrl t "Fans" in
  let fan_lump f = match level with Chip | Tray -> Some f | Rack | Module -> lump f in
  let first f = List.find (fun f' -> fan_lump f' = fan_lump f) fans in
  let fname f = sp "f%d" (first f) in
  let fclock f = clock (fname f) in
  List.iter
    (fun f ->
      if first f = f then
        let target =
          sp "(%s > 0.5 ? 1.0 : %s + (1.0 - %s)*%s)" (kp f 4) (kp f 2) (kp f 2) (frac (node_of f))
        in
        ode (fname f) target (kp f 3))
    fans;

  (* ---- Electrical power ---- *)
  let memo = Hashtbl.create 64 in
  let rec pw i =
    match Hashtbl.find_opt memo i with
    | Some s -> s
    | None ->
        let s =
          match (ctrl t i, pins t i "Eout") with
          | "GPU", _ -> gpu_pw i
          | "Fans", _ ->
              let s = fclock i in
              sp "%s*%s*%s*%s" (kp i 0) s s s
          | "LoadBank", _ ->
              let l = one "LoadBank supply" (pins t i "Ein") in
              let others = sum (List.map pw (List.filter (( <> ) i) (parts "Ein" l))) in
              sp "(%s > %s ? %s - %s : 0.0)" (kp i 0) others (kp i 0) others
          | "UPS", _ -> clock (sp "u%d" i)
          | _, [ out ] -> sp "%s/%s" (load out) (kp i 0)
          | c, [] -> (
              match List.assoc_opt c constant_w with
              | Some idx -> kp i idx
              | None -> error "%s (node %d) draws power, but big2uppaal has no rule for it" c i)
          | c, _ -> error "%s (node %d) supplies more than one link" c i
        in
        Hashtbl.replace memo i s;
        s
  and load l = sum (List.map pw (parts "Ein" l)) in
  List.iter
    (fun u ->
      let out = one "UPS output" (pins t u "Eout") in
      ode (sp "u%d" u) (sp "%s/%s" (load out) (kp u 0)) (kp u 1))
    (with_ctrl t "UPS");

  (* ---- Heat ---- *)
  (* What a part turns into heat: what it draws, less what it passes on. *)
  let diss i =
    match pins t i "Eout" with
    | [ out ] -> sp "(%s - %s)" (pw i) (load out)
    | _ -> pw i
  in
  let side x c = one (sp "%s side of %s" c (ctrl t x)) (kids t x c) in
  let exchangers =
    List.filter (fun i -> kids t i "Hot" <> [] && kids t i "Cold" <> []) (all t)
  in
  let heat l =
    let direct =
      parts "Cout" l |> List.filter (fun i -> not (List.mem (ctrl t i) [ "Hot"; "Cold" ]))
    in
    let from =
      List.filter (fun x -> List.mem l (pins t (side x "Cold") "Cout")) exchangers
    in
    sum (List.map diss direct @ List.map (fun x -> sp "(%s + %s)" (clock (sp "h%d" x)) (kp x 1)) from)
  in
  List.iter
    (fun x ->
      let l = one "inlet of a heat exchanger" (pins t (side x "Hot") "Cin") in
      ode (sp "h%d" x) (heat l) (kp x 0))
    exchangers;

  (* ---- Fields: what an instrument in a zone receives ---- *)
  (* The loss in dB from [src] to instrument [i]: every enclosure crossed on
     the way out to the first place that holds both, and the distance. *)
  let enclosure_loss marker src i =
    let outer = ancestors t i in
    let rec crossed = function
      | [] -> 0.0
      | x :: rest ->
          if List.mem x outer then 0.0
          else
            List.fold_left (fun a m -> a +. param t m 0) 0.0 (kids t x marker)
            +. crossed rest
    in
    crossed (src :: ancestors t src)
  in
  let zone i =
    match enclosing t i "Zone" with
    | Some z -> z
    | None -> error "%s (node %d) is not in a Zone" (ctrl t i) i
  in
  let distance i = Float.max 1.0 (param t (zone i) 0) in
  let ambient marker i =
    match List.find_map (fun a -> match kids t a marker with m :: _ -> Some (param t m 0) | [] -> None) (ancestors t i) with
    | Some db -> db
    | None -> error "no %s around %s (node %d)" marker (ctrl t i) i
  in
  let db x = 10.0 ** (x /. 10.0) in

  (* ---- Instruments ---- *)
  let gateway = ref None in
  let obs i = one (sp "what %s reads" (ctrl t i)) (pins t i "Obs") in
  let channel i =
    match ctrl t i with
    | "Meter" ->
        let l = obs i in
        Some { kind = "power"; about = sp "Meter on %s" (describe_link t l);
               expr = Some (load l); period = name_k (sp "P%d" i) (param t i 0);
               sigma = name_k (sp "N%d" i) (param t i 1) }
    | "TProbe" ->
        let l = obs i in
        let plant = one "chilled-water plant" (List.filter (fun p -> ctrl t p = "Plant") (parts "Cin" l)) in
        Some { kind = "thermal"; about = sp "TProbe on %s" (describe_link t l);
               expr = Some (sp "%s/(%s*4186.0)" (heat l) (kp plant 0));
               period = name_k (sp "P%d" i) (param t i 0);
               sigma = name_k (sp "N%d" i) (param t i 1) }
    | "Tap" ->
        let l = obs i in
        let g = one "gateway" (List.filter (fun p -> ctrl t p = "Gateway") (parts "Dp" l)) in
        gateway :=
          Some ( name_k (sp "K%d_0" g) (param t g 0),
                 name_k (sp "K%d_1" g) (param t g 1),
                 name_k (sp "K%d_2" g) (param t g 2) );
        Some { kind = "network"; about = sp "Tap on %s" (describe_link t l);
               expr = None; period = name_k (sp "P%d" i) (param t i 0);
               sigma = name_k (sp "N%d" i) 1.0 }
    | "Console" ->
        let l = obs i in
        let tel = one "telemetry unit" (List.filter (fun p -> ctrl t p = "Telemetry") (parts "Dp" l)) in
        let m = one "what the telemetry unit reads" (pins t tel "Obs") in
        Some { kind = "telemetry"; about = sp "Console on %s, which reports %s" (describe_link t l) (describe_link t m);
               expr = Some (load m); period = name_k (sp "P%d" i) (param t tel 0);
               sigma = name_k (sp "N%d" i) (param t i 0) }
    | "Antenna" ->
        let d = distance i in
        let terms =
          List.map
            (fun e ->
              let src = Option.get (node t e).parent in
              let loss = enclosure_loss "Shield" src i +. (20.0 *. log10 d) in
              sp "exp(0.2302585093*(%s + (%s - %s)*%s - %s))" (kp e 0) (kp e 1) (kp e 0)
                (frac (node_of src)) (k (sp "A%d_%d" e i) loss))
            (with_ctrl t "Rf")
        in
        Some { kind = "rf"; about = sp "Antenna %g m from the module" d;
               expr = Some (sum terms); period = name_k (sp "P%d" i) (param t i 0);
               sigma = name_k (sp "N%d" i) (db (ambient "RfFloor" i) /. sqrt (param t i 1)) }
    | "Mic" ->
        let d = distance i in
        let terms =
          List.map
            (fun f ->
              let loss = enclosure_loss "Wall" f i +. (10.0 *. log10 (4.0 *. Float.pi *. d *. d)) in
              let s = fclock f in
              sp "exp(0.2302585093*(%s - %s))*%s*%s*%s*%s*%s" (kp f 1) (k (sp "A%d_%d" f i) loss) s s s s s)
            fans
        in
        Some { kind = "sound"; about = sp "Mic %g m from the module" d;
               expr = Some (sum terms); period = name_k (sp "P%d" i) (param t i 0);
               sigma = name_k (sp "N%d" i) (db (ambient "Noise" i) /. sqrt (param t i 1)) }
    | _ -> None
  in
  let channels = List.filter_map channel (all t) in

  (* ---- The campaign and its secrets ---- *)
  let campaign = one "Campaign" (with_ctrl t "Campaign") in
  let actual = one "Actual" (kids t campaign "Actual") in
  let the c holder = one (sp "%s in %s" c (ctrl t holder)) (kids t holder c) in
  let read ~model ~bench ~item =
    let p = param t in
    { pre_ms = p model 0; tok_ms = p model 1; load = p model 2; gpus = int_of_float (p model 3);
      p_lo = p bench 0; p_hi = p bench 1; r_lo = p bench 2; r_hi = p bench 3;
      it_node = int_of_float (p item 0); it_index = int_of_float (p item 1); it_tokens = p item 2 }
  in
  let model = the "Model" actual and bench = the "Bench" actual and item = the "Item" actual in
  let copies =
    ("actual", read ~model ~bench ~item)
    :: List.map
         (fun o ->
           match List.map (fun x -> (ctrl t x, x)) (node t o).children with
           | [ ("Model", m) ] -> ("model", read ~model:m ~bench ~item)
           | [ ("Bench", b) ] -> ("benchmark", read ~model ~bench:b ~item)
           | [ ("Item", i) ] -> ("item", read ~model ~bench ~item:i)
           | _ -> error "an Other holds one Model, one Bench or one Item")
         (kids t campaign "Other")
  in
  (* A secret that cannot take effect leaves its copy equal to the actual
     run, and the model would then report the secret as hidden. *)
  let nworkers = List.length workers in
  List.iter
    (fun (name, s) ->
      if s.it_node < 0 || s.it_node >= nworkers then
        error "%s: the item is on worker %d, but the workers are 0 to %d" name s.it_node (nworkers - 1);
      if s.it_index < 0 then error "%s: the item has index %d" name s.it_index;
      if s.gpus < 1 || s.gpus > slots then
        error "%s: the model uses %d GPUs of a worker, which has %d" name s.gpus slots;
      if s.p_lo > s.p_hi || s.r_lo > s.r_hi then
        error "%s: a range of lengths has its low end above its high end" name)
    copies;
  {
    consts = List.rev !consts;
    clocks = List.rev !clocks;
    odes = List.rev !odes;
    settle = List.rev !settle;
    channels;
    workers = nworkers;
    slots;
    gap = param t campaign 0;
    copies;
    gateway = !gateway;
  }
