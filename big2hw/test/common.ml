(* Shared by the tests: the model, and copies of it with one thing changed. *)

open Big2hw

let file = "models/crs.big"

let read path =
  let ch = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ch)
    (fun () -> really_input_string ch (in_channel_length ch))

let count text part =
  let n = String.length part in
  let rec go i acc =
    if i + n > String.length text then acc
    else if String.sub text i n = part then go (i + n) (acc + 1)
    else go (i + 1) acc
  in
  go 0 0

let contains text part = count text part > 0

(* [variant edits] is the path of a copy of crs.big, or of [of_], in which
   each [(old, new_)] of [edits] replaces the one place [old] is written. *)
let variant ?(of_ = file) edits =
  let replace text (old, new_) =
    if count text old <> 1 then
      Alcotest.failf "the model has %d places that read: %s" (count text old) old;
    let i =
      let n = String.length old in
      let rec find i = if String.sub text i n = old then i else find (i + 1) in
      find 0
    in
    String.sub text 0 i ^ new_
    ^ String.sub text (i + String.length old) (String.length text - i - String.length old)
  in
  let path = Filename.temp_file "crs" ".big" in
  let ch = open_out_bin path in
  output_string ch (List.fold_left replace (read of_) edits);
  close_out ch;
  path

let design ?(file = file) () = Design.of_model ~name:"crs" (Bg.load file)

(* The message of the error that building the design of a variant gives. *)
let refusal edits =
  match design ~file:(variant edits) () with
  | _ -> Alcotest.fail "the model was accepted"
  | exception Bg.Error msg -> msg

(* The model with a channel control that also takes a tag while Idle. *)
let idle_takes_tag =
  [ ("State{c0}.(Idle  | Trans.(Pulse | To{c1}))",
     "State{c0}.(Idle  | Trans.(Pulse | To{c1}) | Trans.(Tag | To{c2}))") ]
