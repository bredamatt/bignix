(* Stand-in for bigrapher's Cmd module. The real one parses the command line
   when it is linked. Store reads only these two options from it. *)
type t = { initfile : string option; quiet : bool }

let defaults = { initfile = None; quiet = true }
