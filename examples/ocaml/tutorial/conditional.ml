(* examples/bigrapher/tutorial/07-conditional-reaction-rules/conditional.big *)
open Bigraph
open Common
module BRS = Brs.Make (Matcher)

let room = node (ctrl "Room" 0) []
let person = leaf (ctrl "Person" 0) []
let alarm = leaf (ctrl "Alarm" 0) []
let safe = leaf (ctrl "Safe" 0) []
let done_ = leaf (ctrl "Done" 0) []

(* react evacuate = Person --> Done if Alarm in ctx; *)
let evacuate =
  BRS.parse_react_unsafe ~name:"evacuate" ~lhs:person ~rhs:done_
    ~conds:[ AppCond.{ neg = false; where = Ctx; pred = alarm } ]
    () None

(* react stay = Person --> Safe if !Alarm in ctx; *)
let stay =
  BRS.parse_react_unsafe ~name:"stay" ~lhs:person ~rhs:safe
    ~conds:[ AppCond.{ neg = true; where = Ctx; pred = alarm } ]
    () None

(* react clear = Room.Person --> Room.Done if Person in param; *)
let clear =
  BRS.parse_react_unsafe ~name:"clear" ~lhs:(Big.nest room person)
    ~rhs:(Big.nest room done_)
    ~conds:[ AppCond.{ neg = false; where = Param; pred = person } ]
    () None

(* big s0 = Room.Person | Alarm; *)
let s0 = Big.par (Big.nest room person) alarm

(* begin brs init s0; rules = [ { evacuate, stay, clear } ]; end *)
let () =
  let graph, _ =
    BRS.bfs ~s0
      ~priorities:[ BRS.P_class [ evacuate; stay; clear ] ]
      ~predicates:[] ~max:max_states
      (fun _ _ -> ())
  in
  print_string (BRS.to_prism graph)
