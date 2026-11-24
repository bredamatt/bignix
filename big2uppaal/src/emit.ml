(* UPPAAL-SMC text for a plant: the model (XML) and the queries.

   One run of the model simulates every configuration j (one value of a
   swept parameter) and, in each, every copy c of the module: copy 0 is the
   actual run and each other copy differs from it in one secret. All copies
   and configurations see the same items arrive, with the same random
   numbers. What differs between copy 0 and copy c is then due to the secret
   alone. *)

open Plant

type options = {
  horizon : float;  (** Length of a campaign, s. *)
  items : int;  (** Most items one worker can run in a campaign. *)
  dprime : float;  (** Largest detectability index a site may allow. *)
  z : float;  (** Largest single reading, in standard deviations. *)
  runs : int;  (** Runs for the queries that estimate a mean. *)
  max_odes : int;  (** Most equations in the invariant of one process. *)
}

(* verifyta 5.0.0 takes twice as long to load a model for every equation
   added to one invariant: 28 take 14 s and 42 never finish. Eight load at
   once. *)
let default = { horizon = 300.0; items = 400; dprime = 1.0; z = 3.0; runs = 50; max_odes = 8 }
let sp = Printf.sprintf

let num v =
  let s = sp "%.9g" v in
  if String.contains s '.' || String.contains s 'e' || String.contains s 'n' then s
  else s ^ ".0"

let xml s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '&' -> Buffer.add_string b "&amp;"
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let braces l = "{" ^ String.concat ", " l ^ "}"

(* [chunks n l] is [l] cut into lists of at most [n], in order. *)
let chunks n l =
  let rec go acc cur k = function
    | [] -> List.rev (List.rev cur :: acc)
    | x :: rest when k = n -> go (List.rev cur :: acc) [ x ] 1 rest
    | x :: rest -> go acc (x :: cur) (k + 1) rest
  in
  go [] [] 0 l

(* [plants]: one per configuration. They must differ in numbers only. *)
let check_same (plants : Plant.t list) =
  let p0 = List.hd plants in
  List.iter
    (fun p ->
      if p.odes <> p0.odes || p.clocks <> p0.clocks
         || List.map (fun c -> c.expr) p.channels <> List.map (fun c -> c.expr) p0.channels
         || List.map fst p.consts <> List.map fst p0.consts
      then Topo.error "a swept parameter changed the structure of the model, not only its numbers";
      (* These are written once, not once per configuration. *)
      if p.copies <> p0.copies || p.gap <> p0.gap || p.workers <> p0.workers || p.slots <> p0.slots
      then
        Topo.error
          "a swept parameter changed the campaign or a secret: these are the same in every configuration")
    plants

let declarations o (plants : Plant.t list) =
  let p = List.hd plants in
  let nj = List.length plants and nc = List.length p.copies in
  let nch = List.length p.channels in
  let b = Buffer.create 4096 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  line "const int J = %d;      // configurations" nj;
  line "const int C = %d;      // copies of the module: 0 is the actual run" nc;
  line "const int NW = %d;     // workers" p.workers;
  line "const int NS = %d;     // GPUs of one worker" p.slots;
  line "const int NCH = %d;    // instruments of the operator" nch;
  line "const int MAXI = %d;   // items one worker can run" o.items;
  line "// A clock and a duration that should be equal can differ in the last bit.";
  line "// Without this slack a worker can be stuck one bit short of its deadline.";
  line "const double EPS = 0.000001;";
  line "typedef int[0, J-1] cfg_t;";
  line "typedef int[0, C-1] copy_t;";
  line "typedef int[0, NW-1] worker_t;";
  line "typedef int[0, NCH-1] chan_t;";
  line "";
  line "// Numbers read from the bigraph, one value per configuration.";
  List.iter
    (fun (name, _) ->
      line "const double %s[J] = %s;" name
        (braces (List.map (fun (q : Plant.t) -> num (List.assoc name q.consts)) plants)))
    p.consts;
  line "";
  line "// The secrets, one value per copy.";
  let per f = braces (List.map (fun (_, s) -> f s) p.copies) in
  line "const double PRE[C] = %s;   // ms per prompt token" (per (fun s -> num s.pre_ms));
  line "const double TOK[C] = %s;   // ms per response token" (per (fun s -> num s.tok_ms));
  line "const double LOAD[C] = %s;  // GPU load while decoding" (per (fun s -> num s.load));
  line "const double PLO[C] = %s;" (per (fun s -> num s.p_lo));
  line "const double PHI[C] = %s;" (per (fun s -> num s.p_hi));
  line "const double RLO[C] = %s;" (per (fun s -> num s.r_lo));
  line "const double RHI[C] = %s;" (per (fun s -> num s.r_hi));
  line "const int ITN[C] = %s;      // the worker of the item the secret fixes" (per (fun s -> string_of_int s.it_node));
  line "const int ITI[C] = %s;      // its index" (per (fun s -> string_of_int s.it_index));
  line "const double ITT[C] = %s;   // its response length, tokens" (per (fun s -> num s.it_tokens));
  line "// ENG[c][s]: 1 if the model of copy c uses GPU s of a worker.";
  line "const int ENG[C][NS] = %s;"
    (per (fun s -> braces (List.init p.slots (fun i -> if i < s.gpus then "1" else "0"))));
  line "const double GAP = %s;      // mean pause between items, s" (num p.gap);
  line "";
  line "// The instruments: seconds between readings, and the noise of one reading.";
  let table f = braces (List.map (fun (ch : channel) -> braces (List.init nj (fun _ -> f ch) |> List.mapi (fun j s -> sp "%s[%d]" s j))) p.channels) in
  ignore table;
  let values name = braces (List.map (fun (q : Plant.t) -> num (List.assoc name q.consts)) plants) in
  line "const double PER[NCH][J] = %s;" (braces (List.map (fun (ch : channel) -> values ch.period) p.channels));
  let less name = braces (List.map (fun (q : Plant.t) -> num (List.assoc name q.consts -. 0.000001)) plants) in
  line "const double PERLO[NCH][J] = %s;  // PER less the slack" (braces (List.map (fun (ch : channel) -> less ch.period) p.channels));
  line "const double SIG[NCH][J] = %s;" (braces (List.map (fun (ch : channel) -> values ch.sigma) p.channels));
  line "const int TAP[NCH] = %s;    // 1: the instrument counts bytes at the gateway"
    (braces (List.map (fun (ch : channel) -> if ch.expr = None then "1" else "0") p.channels));
  line "";
  line "// The scenario: the same for every configuration and copy.";
  line "double G[NW][MAXI];    // pause before each item, s";
  line "double UP[NW][MAXI];   // where each prompt length falls in its range";
  line "double UR[NW][MAXI];   // where each response length falls in its range";
  line "";
  line "double act[J][C][NW];  // GPU load a worker asks for: 0 idle, 1 prompt, LOAD decoding";
  line "double backlog[J][C];  // result bytes waiting at the gateway";
  line "double y[NCH][J][C];   // the latest reading of each instrument";
  line "double d2[NCH][J][C];  // sum over readings of ((y[c] - y[0])/sigma)^2: the squared detectability index";
  line "double dmax[NCH][J][C];// largest |y[c] - y[0]|/sigma in one reading";
  line "";
  line "// The state of the plants: power drawn, fan speed, heat carried, ...";
  List.iter (fun c -> line "clock %s[J][C];" c) p.clocks;
  line "";
  line "broadcast chan go;";
  line "broadcast chan tick[NCH][J];";
  line "";
  line "// A clock starts at 0: a module that is switched off. Before a run every";
  line "// clock is set to the value it tends to while the workers are idle. An";
  line "// equation can depend on a clock that is set after it, so the pass is";
  line "// repeated once per clock.";
  line "void settle(cfg_t j, copy_t c) {";
  line "  int n;";
  line "  for (n = 0; n < %d; n++) {" (List.length p.settle);
  List.iter (fun a -> line "    %s;" a) p.settle;
  line "  }";
  line "}";
  line "void settle_all() {";
  line "  int j; int c;";
  line "  for (j = 0; j < J; j++) { for (c = 0; c < C; c++) settle(j, c); }";
  line "}";
  line "";
  line "void draw() {";
  line "  int w; int i;";
  line "  for (w = 0; w < NW; w++) {";
  line "    for (i = 0; i < MAXI; i++) {";
  line "      G[w][i] = random(2.0*GAP);";
  line "      UP[w][i] = random(1.0);";
  line "      UR[w][i] = random(1.0);";
  line "    }";
  line "  }";
  line "}";
  line "";
  (match p.gateway with
  | Some (mode, rate, _) ->
      line "// Bytes the gateway puts on the uplink in one period.";
      line "double sent(cfg_t j, copy_t c, double period) {";
      line "  double s; double room = %s[j]*period;" rate;
      line "  if (%s[j] > 0.5) {" mode;
      line "    // A fixed-rate tunnel: full frames, whatever is waiting.";
      line "    s = room;";
      line "    if (backlog[j][c] > room) backlog[j][c] = backlog[j][c] - room; else backlog[j][c] = 0.0;";
      line "  } else {";
      line "    s = backlog[j][c];";
      line "    backlog[j][c] = 0.0;";
      line "  }";
      line "  return s;";
      line "}"
  | None ->
      line "double sent(cfg_t j, copy_t c, double period) { return 0.0; }");
  line "";
  line "// After every plant has shown instrument ch its reading.";
  line "void score(chan_t ch, cfg_t j) {";
  line "  int c; double d;";
  line "  if (TAP[ch] == 1) { for (c = 0; c < C; c++) y[ch][j][c] = sent(j, c, PER[ch][j]); }";
  line "  for (c = 1; c < C; c++) {";
  line "    d = (y[ch][j][c] - y[ch][j][0])/SIG[ch][j];";
  line "    d2[ch][j][c] = d2[ch][j][c] + d*d;";
  line "    if (d < 0.0) d = -d;";
  line "    if (d > dmax[ch][j][c]) dmax[ch][j][c] = d;";
  line "  }";
  line "}";
  Buffer.contents b

let template ~name ~params ~decl body =
  sp "<template>\n<name>%s</name>\n<parameter>%s</parameter>\n<declaration>%s</declaration>\n%s</template>\n"
    name (xml params) (xml decl) body

let location ?(committed = false) ?invariant id name =
  sp "<location id=\"%s\"><name>%s</name>%s%s</location>\n" id name
    (match invariant with Some i -> sp "<label kind=\"invariant\">%s</label>" (xml i) | None -> "")
    (if committed then "<committed/>" else "")

let edge ?guard ?sync ?update src dst =
  let label kind = function Some s -> sp "<label kind=\"%s\">%s</label>" kind (xml s) | None -> "" in
  sp "<transition><source ref=\"%s\"/><target ref=\"%s\"/>%s%s%s</transition>\n" src dst
    (label "guard" guard) (label "synchronisation" sync) (label "assignment" update)

let scenario =
  template ~name:"Scenario" ~params:"" ~decl:""
    (location ~committed:true "s0" "Start" ^ location "s1" "Running" ^ "<init ref=\"s0\"/>\n"
    ^ edge ~sync:"go!" ~update:"draw(), settle_all()" "s0" "s1")

let worker (p : Plant.t) =
  let token = match p.gateway with Some (_, _, token) -> token ^ "[j]" | None -> "0.0" in
  let decl =
    String.concat "\n"
      [ "clock x;"; "int i = 0;"; "double lr = 0.0;";
        "double dur = 0.0;  // how long to stay in this location";
        "double lo = 0.0;   // dur less the slack: when the worker may leave";
        "void begin_item() {";
        "  double lp = PLO[c] + UP[w][i]*(PHI[c] - PLO[c]);";
        "  lr = RLO[c] + UR[w][i]*(RHI[c] - RLO[c]);";
        "  if (ITN[c] == w && ITI[c] == i) lr = ITT[c];";
        "  dur = lp*PRE[c]/1000.0;";
        "  act[j][c][w] = 1.0;";
        "  lo = dur - EPS;";
        "}";
        "void decode() {";
        "  dur = lr*TOK[c]/1000.0;";
        "  act[j][c][w] = LOAD[c];";
        "  lo = dur - EPS;";
        "}";
        "void end_item() {";
        sp "  backlog[j][c] = backlog[j][c] + lr*%s;" token;
        "  act[j][c][w] = 0.0;";
        "  i = i + 1;";
        "  if (i < MAXI) dur = G[w][i]; else dur = 1000000.0;";
        "  lo = dur - EPS;";
        "}" ]
  in
  template ~name:"Worker" ~params:"const cfg_t j, const copy_t c, const worker_t w" ~decl
    (location "w0" "Wait"
    ^ location ~invariant:"x <= dur" "w1" "Gap"
    ^ location ~invariant:"x <= dur" "w2" "Prompt"
    ^ location ~invariant:"x <= dur" "w3" "Decode"
    ^ "<init ref=\"w0\"/>\n"
    ^ edge ~sync:"go?" ~update:"dur = G[w][0], lo = dur - EPS, x = 0" "w0" "w1"
    ^ edge ~guard:"x >= lo && i < MAXI" ~update:"begin_item(), x = 0" "w1" "w2"
    ^ edge ~guard:"x >= lo" ~update:"decode(), x = 0" "w2" "w3"
    ^ edge ~guard:"x >= lo" ~update:"end_item(), x = 0" "w3" "w1")

(* The processes that hold the equations of a plant, at most [o.max_odes]
   each, and their names. The first also shows the instruments their
   readings. *)
let plant o (p : Plant.t) =
  let shows =
    List.mapi
      (fun ch (c : channel) ->
        match c.expr with
        | Some e -> edge ~sync:(sp "tick[%d][j]?" ch) ~update:(sp "y[%d][j][c] = %s" ch e) "p0" "p0"
        | None -> "")
      p.channels
  in
  let part n odes =
    let name = sp "Plant%d" n and id = sp "p%d" n in
    let invariant = match odes with [] -> None | l -> Some (String.concat " &&\n" l) in
    ( name,
      template ~name ~params:"const cfg_t j, const copy_t c" ~decl:""
        (location ?invariant id "On" ^ sp "<init ref=\"%s\"/>\n" id
        ^ if n = 0 then String.concat "" shows else "") )
  in
  let parts = List.mapi part (chunks o.max_odes p.odes) in
  (List.map fst parts, String.concat "" (List.map snd parts))

let ticker =
  template ~name:"Ticker" ~params:"const chan_t ch, const cfg_t j" ~decl:"clock x;"
    (location ~invariant:"x <= PER[ch][j]" "t0" "Wait"
    ^ location ~committed:true "t1" "Read"
    ^ "<init ref=\"t0\"/>\n"
    ^ edge ~guard:"x >= PERLO[ch][j]" ~sync:"tick[ch][j]!" ~update:"x = 0" "t0" "t1"
    ^ edge ~update:"score(ch, j)" "t1" "t0")

(* ---- Queries ---- *)

type query = { formula : string; comment : string }

let queries o ~labels (p : Plant.t) =
  (* UPPAAL wants a whole number of time units as the bound. *)
  let t = string_of_int (int_of_float (Float.ceil o.horizon)) and d2max = num (o.dprime *. o.dprime) in
  let pairs = List.tl (List.mapi (fun c (name, _) -> (c, name)) p.copies) in
  let chans = List.mapi (fun ch (c : channel) -> (ch, c)) p.channels in
  let each f = List.concat_map (fun (j, label) -> List.concat_map (fun (c, secret) -> f j label c secret) pairs) (List.mapi (fun j l -> (j, l)) labels) in
  let campaign =
    each (fun j label c secret ->
        List.map
          (fun (ch, (chan : channel)) ->
            { formula = sp "Pr[<=%s](<> d2[%d][%d][%d] > %s)" t ch j c d2max;
              comment = sp "campaign | %s | %s | %s" label secret chan.kind })
          chans
        @ [ { formula = sp "Pr[<=%s](<> %s > %s)" t
                (String.concat " + " (List.map (fun (ch, _) -> sp "d2[%d][%d][%d]" ch j c) chans)) d2max;
              comment = sp "campaign | %s | %s | joint" label secret } ])
  in
  let reading =
    each (fun j label c secret ->
        List.map
          (fun (ch, (chan : channel)) ->
            { formula = sp "Pr[<=%s](<> dmax[%d][%d][%d] > %s)" t ch j c (num o.z);
              comment = sp "reading | %s | %s | %s" label secret chan.kind })
          chans)
  in
  let expect =
    each (fun j label c secret ->
        List.map
          (fun (ch, (chan : channel)) ->
            { formula = sp "E[<=%s; %d](max: d2[%d][%d][%d])" t o.runs ch j c;
              comment = sp "mean d2 | %s | %s | %s" label secret chan.kind })
          chans)
  in
  (campaign, reading, expect)

let query_file qs =
  String.concat "" (List.map (fun q -> sp "// %s\n%s\n\n" q.comment q.formula) qs)

let model o ~header (plants : Plant.t list) qs =
  check_same plants;
  let p = List.hd plants in
  List.iter
    (fun (name, (s : secrets)) ->
      if s.it_index >= o.items then
        Topo.error "%s: the item has index %d, but a worker runs at most %d items (--items)" name
          s.it_index o.items)
    p.copies;
  let plant_names, plant_templates = plant o p in
  String.concat ""
    [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
      "<!DOCTYPE nta PUBLIC '-//Uppaal Team//DTD Flat System 1.5//EN' 'http://www.it.uu.se/research/group/darts/uppaal/flat-1_5.dtd'>\n";
      "<nta>\n<declaration>";
      xml (String.concat "\n" (List.map (fun l -> "// " ^ l) header) ^ "\n\n" ^ declarations o plants);
      "</declaration>\n";
      scenario; worker p; plant_templates; ticker;
      sp "<system>system Scenario, Worker, %s, Ticker;</system>\n<queries>\n"
        (String.concat ", " plant_names);
      String.concat ""
        (List.map
           (fun q -> sp "<query><formula>%s</formula><comment>%s</comment></query>\n" (xml q.formula) (xml q.comment))
           qs);
      "</queries>\n</nta>\n" ]
