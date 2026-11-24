open Big2hw

let usage =
  "big2hw MODEL.big [options]\n\n\
   MODEL.big is a bigraph of two FPGA boards, the layout of each and the state\n\
   machine on each, with its reaction rules (begin pbrs). With no option,\n\
   prints what was read: symbols, machines, ports and fibres.\n"

let write name text =
  let ch = open_out name in
  Fun.protect ~finally:(fun () -> close_out ch) (fun () -> output_string ch text)

let run d ~vcd text =
  let steps = Sim.parse d text in
  let trace ch =
    let sim = Sim.create ?vcd:ch d in
    Sim.reset sim;
    List.map (fun step -> (step, Sim.cycle sim step)) steps
  in
  let cycles =
    match vcd with
    | "" -> trace None
    | file ->
        let ch = open_out file in
        Fun.protect ~finally:(fun () -> close_out ch) (fun () -> trace (Some ch))
  in
  print_string (Report.trace d cycles)

let emit d ~source dir =
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
  let header = Report.header ~source d in
  List.iter
    (fun circuit ->
      let file = Filename.concat dir (Hardcaml.Circuit.name circuit ^ ".v") in
      write file (header ^ Hw.verilog circuit);
      prerr_endline ("wrote " ^ file))
    [ Hw.sender_circuit d; Hw.receiver_circuit d; Hw.system_circuit d ];
  let file = Filename.concat dir (d.name ^ "_codes.vh") in
  write file (Report.codes ~source d);
  prerr_endline ("wrote " ^ file)

let () =
  let file = ref "" and system = ref "" and name = ref "" and dir = ref "" in
  let check = ref false and script = ref "" and vcd = ref "" in
  let spec =
    [ ("-o", Arg.Set_string dir, "DIR  write the circuits as Verilog: one file per board, and one for both");
      ("--check", Arg.Set check, " compare every clock cycle of the circuits with the model's reaction rules");
      ("--run", Arg.Set_string script, "CYCLES  simulate, e.g. \"load Response,-,-,-,take\". In a cycle: load PAYLOAD, damage, tamper, take, joined by +");
      ("--vcd", Arg.Set_string vcd, "FILE  with --run: also write the waveforms");
      ("--system", Arg.Set_string system, "NAME  start from big NAME = ... instead of the model's init");
      ("--name", Arg.Set_string name, "NAME  name of the design (default: the file name)") ]
  in
  let model_file s =
    if !file <> "" then raise (Arg.Bad ("one model file, not " ^ !file ^ " and " ^ s));
    file := s
  in
  Arg.parse spec model_file usage;
  try
    if !file = "" then raise (Bg.Error "give a model file");
    let model = Bg.load ?init:(if !system = "" then None else Some !system) !file in
    let source = Filename.basename !file in
    let name = Design.identifier (if !name = "" then Filename.remove_extension source else !name) in
    if !vcd <> "" && !script = "" then raise (Bg.Error "--vcd needs --run");
    let d = Design.of_model ~name model in
    if !dir = "" && (not !check) && !script = "" then print_string (Report.design d);
    if !dir <> "" then emit d ~source !dir;
    if !script <> "" then run d ~vcd:!vcd !script;
    if !check then begin
      let r = Conform.check d (Space.build model) in
      print_string (Conform.text r);
      if r.failures <> [] then exit 1
    end
  with Bg.Error msg | Sys_error msg ->
    prerr_endline ("big2hw: " ^ msg);
    exit 1
