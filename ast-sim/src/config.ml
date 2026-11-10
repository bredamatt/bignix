type solver = Mcts of Mcts.config | Exact of { max_states : int }

type check = { id : string; description : string; failure : Failure.t }

type t = {
  model : string;
  consts : (string * Model.const) list;
  checks : check list;
  choice : Problem.choice;
  max_depth : int;
  penalty : float;
  solver : solver;
}

exception Error of string

let error fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

(* The fields of the object called [name], whatever their names. *)
let any_fields name = function
  | `Assoc fields -> fields
  | _ -> error "%s must be an object" name

(* The fields of the object called [name]. Unknown fields are an error, so
   that a misspelt setting is not silently ignored. *)
let fields name ~known json =
  let fields = any_fields name json in
  List.iter
    (fun (key, _) ->
      if not (List.mem key known) then
        error "unknown setting \"%s\" in %s (known: %s)" key name
          (String.concat ", " known))
    fields;
  fields

let number key json =
  let value =
    match json with
    | `Int i -> float_of_int i
    | `Float f -> f
    | _ -> error "\"%s\" must be a number" key
  in
  if Float.is_finite value then value
  else error "\"%s\" must be a finite number" key

let integer key = function
  | `Int i -> i
  | _ -> error "\"%s\" must be a whole number" key

let text key = function
  | `String s -> s
  | _ -> error "\"%s\" must be a string" key

let optional fields key read ~default =
  match List.assoc_opt key fields with
  | Some json -> read key json
  | None -> default

let required fields key read =
  match List.assoc_opt key fields with
  | Some json -> read key json
  | None -> error "\"%s\" is missing" key

let const key = function
  | `Int i -> Model.Int i
  | `Float f -> Model.Float f
  | `String s -> Model.String s
  | _ -> error "constant \"%s\" must be a number or a string" key

let consts _ json =
  any_fields "\"consts\"" json
  |> List.map (fun (key, value) -> (key, const key value))

let failure key json =
  match Failure.parse (text key json) with
  | Ok failure -> failure
  | Error msg -> error "%s" msg

let check json =
  let fs = fields "a check" ~known:[ "id"; "failure"; "description" ] json in
  let id = required fs "id" text in
  if id = "" then error "the \"id\" of a check must not be empty";
  try
    {
      id;
      description = optional fs "description" text ~default:"";
      failure = required fs "failure" failure;
    }
  with Error msg -> error "check %s: %s" id msg

let checks key = function
  | `List [] -> error "\"%s\" must have at least one check" key
  | `List rows ->
      let checks = List.map check rows in
      let ids = List.map (fun c -> c.id) checks in
      List.iteri
        (fun i id ->
          if List.exists (( = ) id) (List.filteri (fun j _ -> j < i) ids) then
            error "two checks have the id \"%s\"" id)
        ids;
      checks
  | _ -> error "\"%s\" must be a list" key

(* The "mode" or "type" of an object says which other fields it can have. *)
let kind name key json =
  match List.assoc_opt key (any_fields name json) with
  | Some value -> text key value
  | None -> error "\"%s\" is missing in %s" key name

let choice _ json =
  let name = "\"choice\"" in
  match kind name "mode" json with
  | "free" ->
      let fs = fields name ~known:[ "mode"; "step_cost" ] json in
      Problem.Free (optional fs "step_cost" number ~default:0.01)
  | "uniform" ->
      ignore (fields name ~known:[ "mode" ] json);
      Problem.Uniform
  | "weights" ->
      let fs = fields name ~known:[ "mode"; "weights" ] json in
      let weights _ json =
        any_fields "\"weights\"" json
        |> List.map (fun (action, w) -> (action, number action w))
      in
      Problem.Weights (required fs "weights" weights)
  | mode -> error "unknown choice mode \"%s\" (known: free, uniform, weights)" mode

let default_mcts = { Mcts.iterations = 10000; exploration = 1.0; seed = 0 }

let at_least least key value =
  if value < least then error "\"%s\" must be at least %d" key least else value

let mcts fs =
  let exploration =
    optional fs "exploration" number ~default:default_mcts.exploration
  in
  if exploration < 0. then error "\"exploration\" must not be negative";
  Mcts
    {
      iterations =
        optional fs "iterations" integer ~default:default_mcts.iterations
        |> at_least 1 "iterations";
      exploration;
      seed = optional fs "seed" integer ~default:default_mcts.seed;
    }

let solver _ json =
  let name = "\"solver\"" in
  match kind name "type" json with
  | "mcts" ->
      mcts (fields name ~known:[ "type"; "iterations"; "exploration"; "seed" ] json)
  | "exact" ->
      let fs = fields name ~known:[ "type"; "max_states" ] json in
      Exact
        {
          max_states =
            optional fs "max_states" integer ~default:10000
            |> at_least 1 "max_states";
        }
  | typ -> error "unknown solver type \"%s\" (known: mcts, exact)" typ

let of_json ~dir json =
  let known =
    [ "model"; "consts"; "checks"; "choice"; "max_depth"; "penalty"; "solver" ]
  in
  let fs = fields "the settings" ~known json in
  let model = required fs "model" text in
  {
    model =
      (if Filename.is_relative model then Filename.concat dir model else model);
    consts = optional fs "consts" consts ~default:[];
    checks = required fs "checks" checks;
    choice = optional fs "choice" choice ~default:(Problem.Free 0.01);
    max_depth = optional fs "max_depth" integer ~default:100;
    penalty = optional fs "penalty" number ~default:100.;
    solver = optional fs "solver" solver ~default:(Mcts default_mcts);
  }

let of_file file =
  let json =
    try Yojson.Safe.from_file file with
    | Sys_error msg -> error "%s" msg
    | Yojson.Json_error msg -> error "%s: %s" file msg
  in
  try of_json ~dir:(Filename.dirname file) json
  with Error msg -> error "%s: %s" file msg
