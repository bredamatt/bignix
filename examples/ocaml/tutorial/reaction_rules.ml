(* examples/bigrapher/tutorial/06-reaction-rules/reaction-rules.big *)
open Bigraph
open Common
module BRS = Brs.Make (Matcher)

let a = ctrl "A" 1
let b = ctrl "B" 0
let c = ctrl "C" 0 (* atomic *)
let d = ctrl "D" 1

(* big open = A{x}; *)
let open_ = node a [ "x" ]

(* big closed = /x D{x} | {x}; *)
let closed =
  Big.par (Big.close (face [ "x" ]) (node d [ "x" ])) (Big.intro (face [ "x" ]))

(* big gone = B.1 | {x}; *)
let gone = Big.par (Big.nest (node b []) Big.one) (Big.intro (face [ "x" ]))

(* react close = open --> closed; *)
let close = BRS.parse_react_unsafe ~name:"close" ~lhs:open_ ~rhs:closed () None

(* react remove = open --> gone @[]; *)
let remove =
  BRS.parse_react_unsafe ~name:"remove" ~lhs:open_ ~rhs:gone ()
    (Some (Fun.parse []))

(* big s0 = open * C; *)
let s0 = Big.comp open_ (leaf c [])

(* begin brs init s0; rules = [ {close, remove} ]; end *)
let () =
  let graph, _ =
    BRS.bfs ~s0
      ~priorities:[ BRS.P_class [ close; remove ] ]
      ~predicates:[] ~max:max_states
      (fun _ _ -> ())
  in
  print_string (BRS.to_prism graph)
