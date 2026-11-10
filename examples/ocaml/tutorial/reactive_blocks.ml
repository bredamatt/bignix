(* examples/bigrapher/tutorial/08-reactive-system-blocks/reactive-blocks.big *)
open Bigraph
open Common
module BRS = Brs.Make (Matcher)

let a = ctrl "A" 1
let b = ctrl "B" 0
let c = ctrl "C" 0 (* atomic *)
let d = ctrl "D" 1

(* big open = A{x}; *)
let open_ = node a [ "x" ]

(* big duplicated = D{x}.(id | id); *)
let duplicated = Big.nest (node d [ "x" ]) (Big.par id id)

(* big closed = /x D{x} | {x}; *)
let closed =
  Big.par (Big.close (face [ "x" ]) (node d [ "x" ])) (Big.intro (face [ "x" ]))

(* big gone = B.1 | {x}; *)
let gone = Big.par (Big.nest (node b []) Big.one) (Big.intro (face [ "x" ]))

(* big has_d = D{x}; *)
let has_d = node d [ "x" ]

(* big has_b = B.1; *)
let has_b = Big.nest (node b []) Big.one

(* react duplicate = open --> duplicated @[0,0]; *)
let duplicate =
  BRS.parse_react_unsafe ~name:"duplicate" ~lhs:open_ ~rhs:duplicated ()
    (Some (Fun.parse [ 0; 0 ]))

(* react close = open --> closed; *)
let close = BRS.parse_react_unsafe ~name:"close" ~lhs:open_ ~rhs:closed () None

(* react remove = open --> gone @[]; *)
let remove =
  BRS.parse_react_unsafe ~name:"remove" ~lhs:open_ ~rhs:gone ()
    (Some (Fun.parse []))

(* big s0 = open * C; *)
let s0 = Big.comp open_ (leaf c [])

(* begin brs
     init s0;
     rules = [ { duplicate, close }, (remove) ];
     preds = { has_d[10], has_b[1] };
   end *)
let () =
  let graph, _ =
    BRS.bfs ~s0
      ~priorities:
        [ BRS.P_class [ duplicate; close ]; BRS.P_rclass [ remove ] ]
      ~predicates:[ (("has_d", 10), has_d); (("has_b", 1), has_b) ]
      ~max:max_states
      (fun _ _ -> ())
  in
  print_string (BRS.to_prism graph);
  print_string (BRS.to_lab graph);
  print_string (BRS.to_state_rewards graph)
