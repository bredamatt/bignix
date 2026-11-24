open Big2uppaal

let file = "models/mini.big"
let topo ?consts name = Topo.of_big (Topo.load ?consts file name)
let plant ?consts level = Plant.build ~level (topo ?consts "sys")
let value (p : Plant.t) prefix =
  List.filter (fun (n, _) -> String.length n >= String.length prefix
                             && String.sub n 0 (String.length prefix) = prefix) p.consts
  |> List.map snd
let close = Alcotest.float 1e-6
let contains s sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

let count s sub =
  let n = String.length sub in
  let rec go i acc =
    if i + n > String.length s then acc
    else if String.sub s i n = sub then go (i + n) (acc + 1)
    else go (i + 1) acc
  in
  go 0 0

let views () =
  let t = topo "sys" in
  Alcotest.(check int) "one Ref is opened" 1 (List.length (Topo.views t));
  Alcotest.(check int) "the Ref shows the tray's boundary" 0
    (List.length (Topo.boundary_mismatches t))

let mismatch () =
  let t = topo "bad" in
  Alcotest.(check int) "the extra pin is found" 1 (List.length (Topo.boundary_mismatches t));
  Alcotest.check_raises "no model is built from it"
    (Topo.Error
       "GPUTrayRef does not show the boundary of GPUTray. Missing: []. Not on the boundary: [Dp on PDB, UPS]")
    (fun () -> ignore (Plant.build ~level:Plant.Chip t))

let levels () =
  let clocks level = List.length (plant level).clocks in
  Alcotest.(check int) "chip: two GPUs and the UPS" 3 (clocks Plant.Chip);
  Alcotest.(check int) "tray: the tray and the UPS" 2 (clocks Plant.Tray);
  Alcotest.(check int) "rack: the rack and the UPS" 2 (clocks Plant.Rack);
  Alcotest.(check int) "module: everything and the UPS" 2 (clocks Plant.Module)

let numbers () =
  let p = plant Plant.Tray in
  (* Two GPUs of 100 W idle and 900 W more at full load. *)
  Alcotest.(check (list close)) "idle power of the tray" [ 200.0 ] (value p "I");
  Alcotest.(check (list close)) "span of the tray" [ 1800.0 ] (value p "S");
  (* 10 dB of chassis and 20 log10(10 m). *)
  Alcotest.(check (list close)) "loss to the antenna" [ 30.0 ] (value p "A");
  let antenna = List.find (fun (c : Plant.channel) -> c.kind = "rf") p.channels in
  (* A floor of 20 dB is 100; 100 samples divide its spread by 10. *)
  Alcotest.(check close) "noise of one antenna reading" 10.0 (List.assoc antenna.sigma p.consts)

let power () =
  let p = plant Plant.Tray in
  let meter = List.find (fun (c : Plant.channel) -> c.kind = "power") p.channels in
  (* The meter is on the feed, whose only load is the UPS. *)
  Alcotest.(check bool) "the meter reads the UPS" true
    (match meter.expr with Some e -> String.length e > 2 && e.[1] = 'u' | None -> false);
  (* The UPS draws what the PDB draws, and the PDB what the tray draws over its efficiency. *)
  Alcotest.(check bool) "the UPS follows the tray through the PDB" true
    (List.exists (fun o -> o.[0] = 'u' && contains o "(g") p.odes)

let secrets () =
  let p = plant Plant.Chip in
  Alcotest.(check (list string)) "copies" [ "actual"; "model" ] (List.map fst p.copies);
  Alcotest.(check int) "GPUs the other model uses" 2 (List.assoc "model" p.copies).gpus;
  Alcotest.(check int) "GPUs of the worker" 2 p.slots

let override () =
  let p = plant ~consts:[ ("gpu_max_w", 2000.0) ] Plant.Tray in
  Alcotest.(check (list close)) "span follows the override" [ 3800.0 ] (value p "S");
  Alcotest.check_raises "an unknown name is refused"
    (Topo.Error "nope is not an int or float declared in the model")
    (fun () -> ignore (topo ~consts:[ ("nope", 1.0) ] "sys"))

let emit () =
  let plants = List.map (fun d -> plant ~consts:[ ("dist_m", d) ] Plant.Tray) [ 10.0; 100.0 ] in
  let p = List.hd plants in
  let campaign, reading, expect = Emit.queries Emit.default ~labels:[ "a"; "b" ] p in
  (* Two configurations, one pair, two instruments and their joint. *)
  Alcotest.(check int) "campaign queries" 6 (List.length campaign);
  Alcotest.(check int) "reading queries" 4 (List.length reading);
  Alcotest.(check int) "mean queries" 4 (List.length expect);
  let xml = Emit.model Emit.default ~header:[] plants campaign in
  Alcotest.(check bool) "the system line" true (contains xml "system Scenario, Worker, Plant0, Ticker;");
  Alcotest.(check bool) "one value per configuration" true (contains xml "const int J = 2;");
  Alcotest.(check bool) "no raw comparison in XML" false (contains xml " > 0.5 ?")

(* verifyta 5.0.0 takes twice as long to load a model for every equation
   added to one invariant: 28 take 14 s and 42 never finish. *)
let split () =
  Alcotest.(check (list (list int))) "groups of at most two" [ [ 1; 2 ]; [ 3; 4 ]; [ 5 ] ]
    (Emit.chunks 2 [ 1; 2; 3; 4; 5 ]);
  Alcotest.(check (list (list int))) "nothing to group" [ [] ] (Emit.chunks 2 []);
  let p = plant Plant.Chip in
  let xml = Emit.model { Emit.default with max_odes = 2 } ~header:[] [ p ] [] in
  (* Three clocks, two to an invariant: two processes share the plant. *)
  Alcotest.(check bool) "two plant processes" true
    (contains xml "system Scenario, Worker, Plant0, Plant1, Ticker;");
  Alcotest.(check bool) "the clocks are global, one per configuration and copy" true
    (List.for_all (fun c -> contains xml (Printf.sprintf "clock %s[J][C];" c)) p.clocks);
  Alcotest.(check bool) "an equation is over an element of the array" true
    (List.for_all (fun o -> contains o "[j][c]' == ") p.odes);
  Alcotest.(check (list int)) "each equation is in the model once" [ 1; 1; 1 ]
    (List.map (count xml) p.odes);
  Alcotest.(check bool) "the first process holds two equations and the second one" true
    (contains xml (String.concat " &amp;&amp;\n" [ List.nth p.odes 0; List.nth p.odes 1 ] ^ "</label>")
     && contains xml (">" ^ List.nth p.odes 2 ^ "</label>"))

(* A clock starts at 0: a module that is switched off. Each run starts
   from the idle module instead. *)
let settled () =
  let p = plant Plant.Chip in
  Alcotest.(check int) "one starting value per clock" (List.length p.clocks) (List.length p.settle);
  Alcotest.(check bool) "each sets its clock to what the clock tends to" true
    (List.for_all2
       (fun c s ->
         let lhs = c ^ "[j][c] = " in
         String.length s > String.length lhs
         && String.sub s 0 (String.length lhs) = lhs
         && contains (List.find (fun o -> contains o (c ^ "[j][c]' == ")) p.odes)
              (String.sub s (String.length lhs) (String.length s - String.length lhs)))
       p.clocks p.settle);
  let xml = Emit.model Emit.default ~header:[] [ p ] [] in
  Alcotest.(check bool) "the scenario settles every plant before it starts" true
    (contains xml "draw(), settle_all()" && contains xml "void settle(cfg_t j, copy_t c)")

(* The secrets are written once, not once per configuration. *)
let sweep_of_a_secret () =
  let plants = List.map (fun g -> plant ~consts:[ ("gap_s", g) ] Plant.Tray) [ 1.0; 4.0 ] in
  Alcotest.check_raises "refused"
    (Topo.Error "a swept parameter changed the campaign or a secret: these are the same in every configuration")
    (fun () -> ignore (Emit.model Emit.default ~header:[] plants []))

(* A secret that cannot take effect makes its copy equal to the actual run:
   the model would report it as hidden. *)
let secret_ranges () =
  Alcotest.check_raises "an item on a worker that is not there"
    (Topo.Error "actual: the item is on worker 3, but the workers are 0 to 0")
    (fun () -> ignore (plant ~consts:[ ("item_node", 3.0) ] Plant.Tray));
  Alcotest.check_raises "more GPUs than a worker has"
    (Topo.Error "model: the model uses 5 GPUs of a worker, which has 2")
    (fun () -> ignore (plant ~consts:[ ("other_gpus", 5.0) ] Plant.Tray));
  let p = plant Plant.Tray in
  Alcotest.check_raises "an item the campaign never reaches"
    (Topo.Error "actual: the item has index 0, but a worker runs at most 0 items (--items)")
    (fun () -> ignore (Emit.model { Emit.default with items = 0 } ~header:[] [ p ] []))

(* ---- A system with reaction rules, as a Markov chain ---- *)

let pulse = "models/pulse.big"
let probs (c : Chain.t) = List.sort compare (List.map (fun (_, _, pr) -> pr) c.trans)

let chain () =
  let c = Chain.load pulse ~init:"one" in
  (* Work; a pulse at the GPU; a pulse at the meter; nothing. *)
  Alcotest.(check int) "states" 4 c.states;
  Alcotest.(check (list close)) "probabilities" [ 0.25; 0.75; 1.0 ] (probs c);
  Alcotest.(check bool) "state 0 is the initial bigraph: the burst is certain" true
    (List.exists (fun (src, _, pr) -> src = 0 && pr = 1.0) c.trans);
  Alcotest.(check (list int)) "the meter has a pulse in one state, never two" [ 1; 0 ]
    (List.map (fun (_, states) -> List.length states) c.labels);
  Alcotest.(check (list string)) "the predicates, in the order of the file" [ "seen1"; "seen2" ]
    (List.map fst c.labels);
  Alcotest.(check (option int)) "the longest run" (Some 2) (Chain.longest c)

let chain_options () =
  let two = Chain.load pulse ~init:"two" in
  Alcotest.(check (option int)) "another initial bigraph: two bursts" (Some 4) (Chain.longest two);
  Alcotest.(check bool) "what leaves a state sums to 1, or nothing leaves it" true
    (List.for_all
       (fun st ->
         let out = List.filter (fun (src, _, _) -> src = st) two.trans in
         out = [] || Float.abs (List.fold_left (fun a (_, _, pr) -> a +. pr) 0.0 out -. 1.0) < 1e-9)
       (List.init two.states Fun.id));
  let half = Chain.load pulse ~consts:[ ("p", 0.5) ] ~init:"one" in
  Alcotest.(check (list close)) "a number replaced" [ 0.5; 0.5; 1.0 ] (probs half);
  Alcotest.check_raises "too many states"
    (Topo.Error "two has more than 3 states (--max-states)")
    (fun () -> ignore (Chain.load pulse ~max:3 ~init:"two"));
  Alcotest.check_raises "a system without probabilities"
    (Topo.Error "models/mini.big is not a pbrs: only a system with probabilities (begin pbrs) becomes a Markov chain")
    (fun () -> ignore (Chain.load file ~init:"sys"))

let chain_emit () =
  let worlds = List.map (fun init -> Chain.load pulse ~init) [ "one"; "two" ] in
  let steps = Emit_chain.steps worlds None in
  (* One more than the longest run, so that its last step is inside the bound. *)
  Alcotest.(check int) "steps" 5 steps;
  Alcotest.(check int) "steps given" 9 (Emit_chain.steps worlds (Some 9));
  let xml = Emit_chain.model ~header:[] worlds in
  Alcotest.(check bool) "one process per world" true (contains xml "system one, two;");
  Alcotest.(check int) "each has its predicates as variables" 2 (count xml "bool seen1 = false;");
  Alcotest.(check bool) "the probabilities of world one" true
    (contains xml "const double P[M] = {1.0, 0.25, 0.75};"
     || contains xml "const double P[M] = {1.0, 0.75, 0.25};");
  Alcotest.(check bool) "no variable has a name UPPAAL keeps for itself" false
    (contains xml "double sum");
  let each = Emit_chain.queries ~steps worlds in
  Alcotest.(check bool) "a query per world and predicate" true
    (List.exists (fun (q : Emit.query) -> q.formula = "Pr[<=5](<> two.seen2)") each);
  Alcotest.(check int) "and one for the end of the run" 6 (List.length each);
  (* deadlock is a word of UPPAAL's query language. *)
  Alcotest.(check bool) "the end of the run" true
    (List.exists (fun (q : Emit.query) -> q.formula = "Pr[<=5](<> one.ended)") each)

let () =
  Alcotest.run "big2uppaal"
    [ ( "topology",
        [ Alcotest.test_case "views" `Quick views; Alcotest.test_case "mismatch" `Quick mismatch ] );
      ( "plant",
        [ Alcotest.test_case "levels" `Quick levels; Alcotest.test_case "numbers" `Quick numbers;
          Alcotest.test_case "power" `Quick power; Alcotest.test_case "secrets" `Quick secrets;
          Alcotest.test_case "override" `Quick override;
          Alcotest.test_case "secret ranges" `Quick secret_ranges ] );
      ( "emit",
        [ Alcotest.test_case "model and queries" `Quick emit;
          Alcotest.test_case "equations split over processes" `Quick split;
          Alcotest.test_case "plants start idle" `Quick settled;
          Alcotest.test_case "sweep of a secret" `Quick sweep_of_a_secret ] );
      ( "chain",
        [ Alcotest.test_case "states and probabilities" `Quick chain;
          Alcotest.test_case "options and refusals" `Quick chain_options;
          Alcotest.test_case "model and queries" `Quick chain_emit ] ) ]
