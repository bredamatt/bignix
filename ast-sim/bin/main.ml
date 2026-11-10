open Ast_sim

let usage = "usage: ast-sim SETTINGS.json\n\nSee the README for the settings.\n"

let () =
  match Sys.argv with
  | [| _; file |] when file <> "--help" && file <> "-h" -> (
      try
        let config = Config.of_file file in
        print_string (Report.to_string config (Report.run config))
      with
      | Config.Error msg | Model.Error msg | Problem.Error msg ->
          prerr_endline ("ast-sim: " ^ msg);
          exit 1
      | e ->
          prerr_endline ("ast-sim: unexpected error: " ^ Printexc.to_string e);
          exit 1)
  | [| _; _ |] -> print_string usage
  | _ ->
      prerr_string usage;
      exit 2
