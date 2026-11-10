type t = Pred of string | Not of t | And of t * t | Or of t * t
type token = Name of string | Bang | Amp | Bar | Open | Close

exception Invalid of string

let invalid fmt = Printf.ksprintf (fun msg -> raise (Invalid msg)) fmt

let is_name_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
  | _ -> false

let without_spaces s =
  String.concat "" (String.split_on_char ' ' s)

(* The name that starts at [i], and where it ends. A name directly followed
   by "(" is a predicate with parameters, and runs to the next ")".
   bigrapher writes such names without spaces, as in near(1,2). *)
let name_at s i =
  let n = String.length s in
  let rec word j = if j < n && is_name_char s.[j] then word (j + 1) else j in
  let j = word i in
  let stop =
    if j < n && s.[j] = '(' then
      match String.index_from_opt s j ')' with
      | Some k -> k + 1
      | None -> invalid "missing `)' after `%s'" (String.sub s i (j - i))
    else j
  in
  (without_spaces (String.sub s i (stop - i)), stop)

let tokens s =
  let n = String.length s in
  let rec scan i acc =
    if i >= n then List.rev acc
    else
      match s.[i] with
      | ' ' | '\t' | '\n' -> scan (i + 1) acc
      | '!' -> scan (i + 1) (Bang :: acc)
      | '&' -> scan (i + 1) (Amp :: acc)
      | '|' -> scan (i + 1) (Bar :: acc)
      | '(' -> scan (i + 1) (Open :: acc)
      | ')' -> scan (i + 1) (Close :: acc)
      | c when is_name_char c ->
          let name, stop = name_at s i in
          scan stop (Name name :: acc)
      | c -> invalid "unexpected character `%c'" c
  in
  scan 0 []

(* or := and ("|" and)*   and := unary ("&" unary)*
   unary := "!" unary | "(" or ")" | name
   Each function returns the expression and the tokens left. *)
let rec parse_or toks =
  let left, rest = parse_and toks in
  match rest with
  | Bar :: rest ->
      let right, rest = parse_or rest in
      (Or (left, right), rest)
  | _ -> (left, rest)

and parse_and toks =
  let left, rest = parse_unary toks in
  match rest with
  | Amp :: rest ->
      let right, rest = parse_and rest in
      (And (left, right), rest)
  | _ -> (left, rest)

and parse_unary = function
  | Bang :: rest ->
      let e, rest = parse_unary rest in
      (Not e, rest)
  | Open :: rest -> (
      match parse_or rest with
      | e, Close :: rest -> (e, rest)
      | _ -> invalid "missing `)'")
  | Name name :: rest -> (Pred name, rest)
  | _ -> invalid "expected a predicate name"

let parse s =
  try
    match parse_or (tokens s) with
    | e, [] -> Ok e
    | _ -> invalid "unexpected text after the expression"
  with Invalid msg ->
    Error (Printf.sprintf "invalid failure expression `%s': %s" s msg)

let rec names = function
  | Pred name -> [ name ]
  | Not e -> names e
  | And (a, b) | Or (a, b) -> names a @ names b

let rec eval holds = function
  | Pred name -> holds name
  | Not e -> not (eval holds e)
  | And (a, b) -> eval holds a && eval holds b
  | Or (a, b) -> eval holds a || eval holds b
