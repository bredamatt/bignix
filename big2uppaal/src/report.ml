(* What a system is, in words: its links by kind and which of them an
   instrument of the operator reads, where the operator can stand, and
   whether each Ref shows the boundary of the view that opens it. *)

open Topo

let sp = Printf.sprintf
let instruments = [ "Meter"; "TProbe"; "Tap"; "Console"; "Antenna"; "Mic" ]

let kind_of t l =
  let has c = List.exists (fun p -> ctrl t p = c) t.links.(l) in
  if has "Is" then "view"
  else if has "Ein" || has "Eout" then "electrical"
  else if has "Cin" || has "Cout" then "cooling"
  else if has "Slot" || has "Worker" then "job"
  else if has "Dp" then "data"
  else "other"

(* Who reads link [l]: an instrument on it, or the reader of a unit that
   reports it over another link. *)
let readers t l =
  List.concat_map
    (fun i ->
      if List.mem (ctrl t i) instruments then [ ctrl t i ]
      else
        List.concat_map
          (fun out ->
            List.filter (fun r -> List.mem (ctrl t r) instruments) (holders t out "Obs")
            |> List.map (fun r -> sp "%s, through %s" (ctrl t r) (ctrl t i)))
          (pins t i "Dp"))
    (holders t l "Obs")

let text t =
  let b = Buffer.create 2048 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  line "Views";
  List.iter
    (fun (r, d) -> line "  %s is opened by a %s view" (ctrl t r) (ctrl t d))
    (List.sort_uniq (fun (a, _) (b, _) -> compare (ctrl t a) (ctrl t b)) (views t));
  (match boundary_mismatches t with
  | [] -> line "  Every Ref shows exactly the boundary of the view that opens it."
  | l -> List.iter (fun (r, d, _, _) -> line "  MISMATCH: %s does not show the boundary of %s" r d) l);
  line "";
  line "Links, and who reads them";
  line "  %-11s %-5s %s" "kind" "read" "link";
  Array.iteri
    (fun l _ ->
      match kind_of t l with
      | "view" -> ()
      | kind ->
          let r = readers t l in
          line "  %-11s %-5s %s%s" kind
            (if r = [] then "no" else "YES")
            (describe_link t l)
            (if r = [] then "" else "  <- " ^ String.concat "; " r))
    t.links;
  line "";
  line "Where the operator can put an instrument";
  List.iter
    (fun z ->
      line "  a Zone %g m from the module, in %s: %s" (param t z 0)
        (match (node t z).parent with Some p -> ctrl t p | None -> "the site")
        (String.concat ", "
           (List.filter_map
              (fun k -> if List.mem (ctrl t k) instruments then Some (ctrl t k) else None)
              (node t z).children)))
    (with_ctrl t "Zone");
  Buffer.contents b
