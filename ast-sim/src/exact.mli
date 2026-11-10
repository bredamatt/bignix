(** The failing run of least cost, found by exploring every state. Only for
    models small enough to enumerate; it is the reference the other
    searches are checked against. *)

val solve : Problem.t -> max_states:int -> Problem.path option
(** [None] if no run fails.

    @raise Problem.Error if more than [max_states] states are reachable. *)
