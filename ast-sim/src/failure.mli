(** What counts as a failure: a boolean expression over the predicates of a
    model, such as ["leak_em | (leak_acoustic & !masked)"]. *)

type t = Pred of string | Not of t | And of t * t | Or of t * t

val parse : string -> (t, string) result
(** Operators, from the tightest: [!], [&], [|]. Parentheses group. A
    predicate with parameters is written as bigrapher names it, as in
    [near(1,2)]. *)

val names : t -> string list
(** The predicates an expression uses. *)

val eval : (string -> bool) -> t -> bool
(** [eval holds e] is the value of [e] when [holds p] says if predicate [p]
    holds. *)
