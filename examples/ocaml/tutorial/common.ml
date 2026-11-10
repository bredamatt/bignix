(* Helpers shared by the examples. *)
open Bigraph

(* The matching engine. MiniCARD is also bigrapher's default. *)
module Matcher = Solver.Make_SAT (Solver.MC)

(* ctrl A = 1;  -->  let a = ctrl "A" 1 *)
let ctrl name arity = { Ctrl.s = name; p = []; i = arity }

(* {x, y} *)
let face = Link.parse_face

(* A{x} for a non-atomic control: a node with a site inside it. *)
let node c names = Big.ion (face names) c

(* A{x} for an atomic control: a node with nothing inside it. *)
let leaf c names = Big.atom (face names) c

(* id: one site in one region. *)
let id = Big.id (Big.Inter (1, Link.Face.empty))

(* The largest transition system to build, as bigrapher's -M option. *)
let max_states = 1000
