(* A bigraph read from a .big file, as plain data: nodes with their control,
   parameters, parent and children, and the links their pins are on. *)

open Bigraph
open Big_frontend

exception Error of string

let error fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

(* ---- Loading ---- *)

module Matcher = Solver.Make_SAT (Solver.MC)
module BRS = Brs.Make (Matcher)

module Store =
  Store.Make
    (BRS)
    (struct
      let parse_react name lhs rhs ?(conds = []) _ eta _ =
        BRS.parse_react_err ~name ~lhs ~rhs ~conds () eta
    end)

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

(* A constant declared in the file wins over one given to the evaluator, so
   an override replaces the declaration itself. *)
let override consts decs =
  let value id = List.assoc_opt id consts in
  let seen = ref [] in
  let decs =
    List.map
      (function
        | Ast.Dfloat (d, loc) as dec -> (
            match value d.Ast.d_id with
            | Some v ->
                seen := d.d_id :: !seen;
                Ast.Dfloat
                  ({ d with d_exp = ENum (Num_float_val (v, d.d_loc)) }, loc)
            | None -> dec)
        | Ast.Dint (d, loc) as dec -> (
            match value d.Ast.d_id with
            | Some v ->
                seen := d.d_id :: !seen;
                Ast.Dint
                  ( { d with
                      d_exp = ENum (Num_int_val (int_of_float v, d.d_loc)) },
                    loc )
            | None -> dec)
        | dec -> dec)
      decs
  in
  List.iter
    (fun (id, _) ->
      if not (List.mem id !seen) then
        error "%s is not an int or float declared in the model" id)
    consts;
  decs

(* [load ~consts file name] is the bigraph declared as [big name = ...] in
   [file], with the numeric declarations in [consts] replaced. *)
let load ?(consts = []) file name =
  let ast = parse file in
  let decs, loc = ast.Ast.model_decs in
  let ast = { ast with model_decs = (override consts decs, loc) } in
  let env = Store.init_env false [] in
  (try ignore (Store.eval_model false ast env)
   with Store.ERROR (e, loc) ->
     error "%s" (located loc (fun fmt -> Store.report_error_aux fmt e)));
  match Base.H_string.find_opt env name with
  | Some { Store.sval = Store.Big b; _ } -> b
  | Some _ -> error "%s is not a bigraph" name
  | None -> error "%s: no bigraph named %s" file name

(* ---- Plain data ---- *)

type node = {
  id : int;
  ctrl : string;
  params : float list;
  parent : int option;  (** None: the node is at the top of a region. *)
  children : int list;
  link : int option;  (** The link of a pin: a node whose control has a port. *)
}

type t = {
  nodes : node array;
  links : int list array;  (** The pins on each link. *)
  names : string list array;  (** The names of each link, if it is open. *)
}

let float_of_param = function
  | Ctrl.I i -> float_of_int i
  | Ctrl.F f -> f
  | Ctrl.S s -> error "string parameter %s: big2uppaal reads numbers only" s

let of_big (b : Big.t) =
  let n = b.p.Place.n in
  let edges = Link.Lg.elements b.l in
  let link_of = Array.make n None in
  let links =
    List.mapi
      (fun e (edge : Link.edg) ->
        Link.Ports.fold
          (fun node _ acc ->
            link_of.(node) <- Some e;
            node :: acc)
          edge.p []
        |> List.sort compare)
      edges
    |> Array.of_list
  in
  let names =
    List.map
      (fun (edge : Link.edg) ->
        Link.Face.elements (Link.Face.union edge.i edge.o)
        |> List.map (fun (Link.Name s) -> s))
      edges
    |> Array.of_list
  in
  let nodes =
    Array.init n (fun id ->
        let c =
          match Nodes.get_ctrl id b.n with
          | Some c -> c
          | None -> error "node %d has no control" id
        in
        {
          id;
          ctrl = c.Ctrl.s;
          params = List.map float_of_param c.Ctrl.p;
          parent = (match IntSet.IntSet.elements (Sparse.prn b.p.Place.nn id) with p :: _ -> Some p | [] -> None);
          children = IntSet.IntSet.elements (Sparse.chl b.p.Place.nn id);
          link = link_of.(id);
        })
  in
  { nodes; links; names }

(* ---- Queries ---- *)

let node t i = t.nodes.(i)
let ctrl t i = t.nodes.(i).ctrl
let all t = Array.to_list t.nodes |> List.map (fun nd -> nd.id)
let with_ctrl t c = List.filter (fun i -> ctrl t i = c) (all t)

let param t i k =
  match List.nth_opt t.nodes.(i).params k with
  | Some v -> v
  | None -> error "%s (node %d) has no parameter %d" (ctrl t i) i k

(* The children of [i] with control [c]. *)
let kids t i c = List.filter (fun k -> ctrl t k = c) t.nodes.(i).children

(* The links of the pins of kind [c] that [i] holds. *)
let pins t i c = List.filter_map (fun k -> t.nodes.(k).link) (kids t i c)

let pin_kinds = [ "Ein"; "Eout"; "Cin"; "Cout"; "Dp"; "Obs"; "Is"; "Slot"; "Worker" ]
let is_pin t i = List.mem (ctrl t i) pin_kinds

(* The nodes that hold a pin of kind [c] on link [l]. *)
let holders t l c =
  List.filter_map
    (fun p -> if ctrl t p = c then t.nodes.(p).parent else None)
    t.links.(l)

let is_ref_ctrl c =
  let n = String.length c in
  n > 3 && String.sub c (n - 3) 3 = "Ref"

(* ---- Views ---- *)

(* A Ref and the root of the view that opens it hold an Is pin on one link. *)
let compute_views t =
  Array.to_list t.links
  |> List.filter_map (fun pins ->
         match List.filter (fun p -> ctrl t p = "Is") pins with
         | [] -> None
         | [ a; b ] -> (
             let pa = Option.get t.nodes.(a).parent
             and pb = Option.get t.nodes.(b).parent in
             match (is_ref_ctrl (ctrl t pa), is_ref_ctrl (ctrl t pb)) with
             | true, false -> Some (pa, pb)
             | false, true -> Some (pb, pa)
             | _ ->
                 error "an Is link must join one Ref and one view: %s, %s"
                   (ctrl t pa) (ctrl t pb))
         | l ->
             error "an Is link must have two ends, not %d" (List.length l))

let views_cache = ref None

let views t =
  match !views_cache with
  | Some (t', v) when t' == t -> v
  | _ ->
      let v = compute_views t in
      views_cache := Some (t, v);
      v

(* True if [i] is a Ref that some view opens: the view stands for it. *)
let opened t i = List.mem_assoc i (views t)

(* The parent in the physical sense: the root of a view sits where its Ref
   sits. *)
let up t i =
  match t.nodes.(i).parent with
  | Some p -> Some p
  | None -> List.find_map (fun (r, d) -> if d = i then Some r else None) (views t)

let rec ancestors t i =
  match up t i with None -> [] | Some p -> p :: ancestors t p

(* The nearest ancestor of [i], or [i] itself, with control [c]. *)
let enclosing t i c = List.find_opt (fun a -> ctrl t a = c) (i :: ancestors t i)

(* All nodes below [i] in its own region. *)
let rec below t i =
  List.concat_map (fun k -> k :: below t k) t.nodes.(i).children

(* ---- Does a Ref show the boundary of the view that opens it? ---- *)

(* Everything a view stands for: its nodes, and the views of the Refs in it. *)
let rec extent t d =
  let own = d :: below t d in
  own
  @ List.concat_map
      (fun i ->
        match List.assoc_opt i (views t) with
        | Some d' -> extent t d'
        | None -> [])
      own

let flow_kinds = [ "Ein"; "Eout"; "Cin"; "Cout"; "Dp" ]

(* For each (Ref, view): the pins the Ref shows and the view does not have
   on its boundary, and the other way round. A pin is a kind and a link. A
   link is on the boundary of a view if a pin outside the view, other than
   the Ref's own, is on it. *)
let boundary_mismatches t =
  List.filter_map
    (fun (r, d) ->
      let inside = extent t d in
      let ref_pins = t.nodes.(r).children in
      let shown =
        List.filter_map
          (fun p ->
            if List.mem (ctrl t p) flow_kinds then
              Some (ctrl t p, Option.get t.nodes.(p).link)
            else None)
          ref_pins
        |> List.sort_uniq compare
      in
      let outside l =
        List.exists
          (fun p -> (not (List.mem p inside)) && not (List.mem p ref_pins))
          t.links.(l)
      in
      let actual =
        List.filter_map
          (fun p ->
            let holder = Option.get t.nodes.(p).parent in
            match t.nodes.(p).link with
            | Some l
              when List.mem (ctrl t p) flow_kinds
                   && (not (opened t holder))
                   && outside l ->
                Some (ctrl t p, l)
            | _ -> None)
          (List.filter (is_pin t) inside)
        |> List.sort_uniq compare
      in
      let missing = List.filter (fun x -> not (List.mem x shown)) actual
      and extra = List.filter (fun x -> not (List.mem x actual)) shown in
      if missing = [] && extra = [] then None
      else Some (ctrl t r, ctrl t d, missing, extra))
    (views t)

(* ---- A description of a link, for reports ---- *)

let describe_link t l =
  match t.names.(l) with
  | n :: _ -> n
  | [] ->
      let ends =
        List.filter_map (fun p -> t.nodes.(p).parent) t.links.(l)
        |> List.filter (fun i -> not (opened t i))
        |> List.map (ctrl t)
      in
      let counted =
        List.sort_uniq compare ends
        |> List.map (fun c ->
               match List.length (List.filter (( = ) c) ends) with
               | 1 -> c
               | k -> Printf.sprintf "%d %s" k c)
      in
      String.concat ", " counted
