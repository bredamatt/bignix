(* UPPAAL-SMC text for Markov chains: the model (XML) and the queries.

   Each chain is one process, named after its initial bigraph. The process
   keeps the number of the current state in [s] and takes one step per time
   unit: it draws the next state with the probabilities of the chain. A
   predicate of the bigraph model is a boolean variable of the process, true
   while the current state satisfies it. A state that no rule applies to
   keeps the process where it is. *)

open Emit

(* Names the process uses itself. *)
let reserved = [ "s"; "x"; "N"; "M"; "FIRST"; "TO"; "P"; "step"; "show"; "ended" ]

(* The time bound of the queries: [given], or one more than the longest run
   of any world, so that the last step of that run is inside the bound. *)
let steps (worlds : Chain.t list) given =
  match given with
  | Some n -> n
  | None ->
      1
      + List.fold_left
          (fun acc (w : Chain.t) ->
            match Chain.longest w with
            | Some l -> Stdlib.max acc l
            | None -> Topo.error "a run of %s can go on for ever: give --steps" w.name)
          0 worlds

let declarations (w : Chain.t) =
  List.iter
    (fun (label, _) ->
      if List.mem label reserved then
        Topo.error "predicate %s: big2uppaal uses this name itself, rename the predicate" label)
    w.labels;
  if w.trans = [] then Topo.error "no rule applies to %s: there is nothing to run" w.name;
  let first =
    List.init (w.states + 1) (fun i ->
        List.length (List.filter (fun (src, _, _) -> src < i) w.trans))
  in
  let holds states = braces (List.init w.states (fun i -> string_of_bool (List.mem i states))) in
  let b = Buffer.create 2048 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  line "// The Markov chain of %s." w.name;
  line "const int N = %d;  // states: the bigraphs that can be reached. 0 is %s itself" w.states w.name;
  line "const int M = %d;  // transitions" (List.length w.trans);
  line "// Transition k goes to state TO[k] with probability P[k]. The transitions";
  line "// that leave state i are FIRST[i] to FIRST[i+1] - 1.";
  line "const int FIRST[N+1] = %s;" (braces (List.map string_of_int first));
  line "const int TO[M] = %s;" (braces (List.map (fun (_, dst, _) -> string_of_int dst) w.trans));
  line "const double P[M] = %s;" (braces (List.map (fun (_, _, p) -> num p) w.trans));
  line "";
  line "// The predicates of the bigraph model: the states in which each holds.";
  List.iter (fun (label, states) -> line "const bool IS_%s[N] = %s;" label (holds states)) w.labels;
  line "";
  line "int[0, N-1] s = 0;  // the current state";
  line "clock x;";
  List.iter (fun (label, states) -> line "bool %s = %b;" label (List.mem 0 states)) w.labels;
  line "bool ended = false;  // no rule applies to the current state";
  line "";
  line "void show() {";
  List.iter (fun (label, _) -> line "  %s = IS_%s[s];" label label) w.labels;
  line "  ended = FIRST[s] == FIRST[s+1];";
  line "}";
  line "";
  line "// One step: draw the next state.";
  line "void step() {";
  line "  double u = random(1.0);";
  line "  double acc = 0.0;  // not sum: UPPAAL keeps that word for itself";
  line "  int from = s;";
  line "  int k;";
  line "  bool found = false;";
  line "  for (k = FIRST[from]; k < FIRST[from+1]; k++) {";
  line "    acc = acc + P[k];";
  line "    if (!found && u < acc) { s = TO[k]; found = true; }";
  line "  }";
  line "  // The probabilities are written to nine digits and can sum to just under 1.";
  line "  if (!found && FIRST[from] < FIRST[from+1]) s = TO[FIRST[from+1] - 1];";
  line "  show();";
  line "}";
  Buffer.contents b

let world (w : Chain.t) =
  let id = w.name ^ "_run" in
  template ~name:w.name ~params:"" ~decl:(declarations w)
    (location ~invariant:"x <= 1" id "Run"
    ^ sp "<init ref=\"%s\"/>\n" id
    ^ edge ~guard:"x >= 1" ~update:"step(), x = 0" id id)

let model ~header (worlds : Chain.t list) =
  String.concat ""
    [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
      "<!DOCTYPE nta PUBLIC '-//Uppaal Team//DTD Flat System 1.5//EN' 'http://www.it.uu.se/research/group/darts/uppaal/flat-1_5.dtd'>\n";
      "<nta>\n<declaration>";
      xml (String.concat "\n" (List.map (fun l -> "// " ^ l) header));
      "\n</declaration>\n";
      String.concat "" (List.map world worlds);
      sp "<system>system %s;</system>\n</nta>\n"
        (String.concat ", " (List.map (fun (w : Chain.t) -> w.name) worlds)) ]

(* For each world, how likely each predicate is to hold at some point of a
   run, and how likely the run is to have ended.

   There is no query that compares two worlds. UPPAAL 5.0.0 has one,
   Pr[..](<> a) >= Pr[..](<> b), but on these models it answered against
   the exact probabilities: it accepted 0.19 >= 0.271 and 0 >= 1 with every
   seed tried. Compare the estimates and their intervals instead. *)
let queries ~steps (worlds : Chain.t list) =
  let reach (w : Chain.t) label = sp "Pr[<=%d](<> %s.%s)" steps w.name label in
  List.concat_map
    (fun (w : Chain.t) ->
      List.map
        (fun (label, _) -> { formula = reach w label; comment = sp "%s | %s" w.name label })
        w.labels
      @ [ { formula = reach w "ended"; comment = sp "%s | the run has ended" w.name } ])
    worlds
