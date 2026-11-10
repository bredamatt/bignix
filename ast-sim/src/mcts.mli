(** Monte Carlo tree search for the failing run of least cost. The search
    picks every step of a run, both the action and its outcome, and pays
    the step's cost. *)

type config = {
  iterations : int;  (** The number of runs to try. *)
  exploration : float;
      (** How much to favour steps tried less often. Values of steps are
          scaled to between 0 and 1 before this is applied. *)
  seed : int;  (** For the random choices. The same seed gives the same result. *)
}

type result = {
  best : Problem.path option;  (** The best failing run found, if any. *)
  failures : int;  (** How many of the runs tried ended in a failure. *)
}

val search : Problem.t -> config -> result
