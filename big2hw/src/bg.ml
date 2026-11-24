(* A .big file as a model, and a bigraph as plain data: nodes with their
   control, parent, children and links. *)

open Bigraph
open Big_frontend

exception Error of string

let error fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

(* ---- A model: the initial bigraph, the rules and the predicates ---- *)

module Matcher = Solver.Make_SAT (Solver.MC)
module PBRS = Pbrs.Make (Matcher)

module Store =
  Store.Make
    (PBRS)
    (struct
      let parse_react name lhs rhs ?(conds = []) label eta _ =
        match label with
        | `F p -> PBRS.parse_react_err ~name ~lhs ~rhs ~conds p eta
        | `E () | `P _ ->
            Error (Printf.sprintf "rule %s has no weight: write -[1.0]->" name)
    end)

type model = {
  init : Big.t;
  priorities : PBRS.p_class list;  (** The class that acts first is first. *)
  predicates : (Base.Predicate.t * Big.t) list;
}

let located loc print = Format.asprintf "@[<v>%a%t@]" Loc.print_loc loc print

let parse file =
  let ch = try open_in file with Sys_error msg -> error "%s" msg in
  let lexbuf = Lexing.from_channel ch in
  Lexing.set_filename lexbuf file;
  Stdlib.Fun.protect
    ~finally:(fun () -> close_in_noerr ch)
    (fun () ->
      try Parser.model Lexer.token lexbuf with
      | Parser.Error ->
          error "%s"
            (located (Loc.curr lexbuf) (fun fmt ->
                 Format.fprintf fmt "Syntax error near token `%s'"
                   (Lexing.lexeme lexbuf)))
      | Lexer.ERROR (e, loc) ->
          error "%s" (located loc (fun fmt -> Lexer.report_error fmt "" e)))

(* [load ?init file] is the system in [file]. With [init], it starts from
   [big init = ...] instead of the bigraph the file names. *)
let load ?init file =
  let ast = parse file in
  let rs = ast.Ast.model_rs in
  (match fst rs.dbrs_type with
  | Rs.PBRS -> ()
  | _ -> error "%s is not a pbrs: big2hw reads systems declared with begin pbrs" file);
  let ast =
    match init with
    | None -> ast
    | Some name ->
        let loc = snd rs.dbrs_init in
        { ast with model_rs = { rs with dbrs_init = (Ast.Init (name, loc), loc) } }
  in
  let env = Store.init_env false [] in
  let init, priorities, predicates, _ =
    try Store.eval_model false ast env
    with Store.ERROR (e, loc) ->
      error "%s" (located loc (fun fmt -> Store.report_error_aux fmt e))
  in
  { init; priorities; predicates }

let rules (m : model) =
  List.concat_map (function PBRS.P_class rs | PBRS.P_rclass rs -> rs) m.priorities

(* ---- A bigraph as plain data ---- *)

type node = {
  ctrl : string;
  parent : int option;  (** None: the node is at the top of a region. *)
  children : int list;
  links : int list;  (** The links its ports are on. Ports have no order. *)
}

type t = {
  nodes : node array;
  links : int list array;  (** The nodes on each link. *)
}

let of_big (b : Big.t) =
  let links =
    Link.Lg.elements b.l
    |> List.map (fun (edge : Link.edg) ->
           Link.Ports.fold (fun node _ acc -> node :: acc) edge.p []
           |> List.sort_uniq compare)
  in
  let links_of id =
    List.concat (List.mapi (fun l on -> if List.mem id on then [ l ] else []) links)
  in
  let nodes =
    Array.init b.p.Place.n (fun id ->
        let ctrl =
          match Nodes.get_ctrl id b.n with
          | Some c -> c.Ctrl.s
          | None -> error "node %d has no control" id
        in
        {
          ctrl;
          parent =
            (match IntSet.IntSet.elements (Sparse.prn b.p.Place.nn id) with
            | p :: _ -> Some p
            | [] -> None);
          children = IntSet.IntSet.elements (Sparse.chl b.p.Place.nn id);
          links = links_of id;
        })
  in
  { nodes; links = Array.of_list links }

(* ---- Queries ---- *)

let ctrl t i = t.nodes.(i).ctrl
let children t i = t.nodes.(i).children
let all t = List.init (Array.length t.nodes) (fun i -> i)
let with_ctrl t c = List.filter (fun i -> ctrl t i = c) (all t)

(* The children of [i] with control [c]. *)
let kids t i c = List.filter (fun k -> ctrl t k = c) (children t i)

(* The nodes with control [c] on link [l]. *)
let on_link t l c = List.filter (fun i -> ctrl t i = c) t.links.(l)

(* The only link of a node with one port. *)
let link t i =
  match t.nodes.(i).links with
  | [ l ] -> l
  | ls -> error "%s (node %d) is on %d links, not one" (ctrl t i) i (List.length ls)

(* The other link of a node with two ports, one of them on [l]. *)
let other_link t i l =
  match List.filter (( <> ) l) t.nodes.(i).links with
  | [ l' ] -> l'
  | _ -> error "%s (node %d) does not have exactly two links" (ctrl t i) i
