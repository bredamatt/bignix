(* examples/bigrapher/tutorial/03-bigraph-expressions/expressions.big *)
open Bigraph
open Common
module BRS = Brs.Make (Matcher)

let a = ctrl "A" 1
let b = ctrl "B" 1
let c = ctrl "C" 1
let d = ctrl "D" 1
let p = ctrl "P" 0
let q = ctrl "Q" 0

(* big t = P.1 + Q.1; *)
let t = Big.tens (Big.nest (node p []) Big.one) (Big.nest (node q []) Big.one)

(* big c = id(2) * t; *)
let c' = Big.comp (Big.id (Big.Inter (2, Link.Face.empty))) t

(* big p = A{x}.1 | B{x}.1; *)
let p' =
  Big.par
    (Big.nest (node a [ "x" ]) Big.one)
    (Big.nest (node b [ "x" ]) Big.one)

(* big pp = C{y}.1 || D{y}.1; *)
let pp =
  Big.ppar
    (Big.nest (node c [ "y" ]) Big.one)
    (Big.nest (node d [ "y" ]) Big.one)

(* big init_state = p | pp | c; *)
let init_state = Big.par (Big.par p' pp) c'

(* begin brs init init_state; rules = []; end *)
let () =
  let graph, _ =
    BRS.bfs ~s0:init_state ~priorities:[] ~predicates:[] ~max:max_states
      (fun _ _ -> ())
  in
  print_string (BRS.to_prism graph)
