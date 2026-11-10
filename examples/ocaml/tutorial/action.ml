(* examples/bigrapher/tutorial/11-action-reactive-systems/example-1/action.big *)
open Bigraph
open Common
module ABRS = Abrs.Make (Matcher)

(* big a = A.1; *)
let a = Big.nest (node (ctrl "A" 0) []) Big.one
let b = Big.nest (node (ctrl "B" 0) []) Big.one
let c = Big.nest (node (ctrl "C" 0) []) Big.one

(* A rule's label is (action, action reward, weight), so the actions block
   of the .big file is spread over the rules:
     actions = [ choose[2] = {to_b, to_c}, wait[0] = {stay} ]; *)

(* react to_b = a -[7]-> b; *)
let to_b =
  ABRS.parse_react_unsafe ~name:"to_b" ~lhs:a ~rhs:b ("choose", 2, 7.) None

(* react to_c = a -[3]-> c; *)
let to_c =
  ABRS.parse_react_unsafe ~name:"to_c" ~lhs:a ~rhs:c ("choose", 2, 3.) None

(* react stay = a -[1]-> a; *)
let stay =
  ABRS.parse_react_unsafe ~name:"stay" ~lhs:a ~rhs:a ("wait", 0, 1.) None

(* begin abrs init a; rules = [ {to_b, to_c, stay} ]; ... end *)
let () =
  let graph, _ =
    ABRS.bfs ~s0:a
      ~priorities:[ ABRS.P_class [ to_b; to_c; stay ] ]
      ~predicates:[] ~max:max_states
      (fun _ _ -> ())
  in
  print_string (ABRS.to_prism graph);
  print_string (ABRS.to_transition_rewards graph)
