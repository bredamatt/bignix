(** Run the checks of a settings file and describe the results. *)

type result = {
  check : Config.check;
  best : Problem.path option;  (** The failing run of least cost found. *)
  failures : int option;
      (** For mcts, how many of the runs tried ended in a failure. *)
}

val run : Config.t -> result list
(** One result for each check, in the order of the settings file.

    @raise Model.Error or Problem.Error with a message for the user. *)

val to_string : Config.t -> result list -> string
(** A table with one row for each check, then the run found for each. *)
