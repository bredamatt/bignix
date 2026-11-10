(** An action BRS loaded from a .big file, as a Markov decision process that
    is explored one state at a time. *)

open Bigraph

type t

(** A value for a constant of the model, as bigrapher's [-c] option. *)
type const = Int of int | Float of float | String of string

type transition = {
  action : string;  (** The action chosen. *)
  prob : float;  (** The probability of this outcome, given the action. *)
  rules : string list;  (** The reaction rules that give this outcome. *)
  next : Big.t;  (** The state reached. *)
}

exception Error of string
(** Raised by {!load} with a message for the user. *)

val load : ?consts:(string * const) list -> string -> t
(** [load ~consts file] reads the model in [file].

    @raise Error if the file cannot be read or is not a valid [abrs] model. *)

val initial : t -> Big.t
(** The initial state. *)

val step : t -> Big.t -> transition list
(** The transitions out of a state. The probabilities of each action sum to
    one. Priority classes apply as in bigrapher: only the first class with
    a rule that matches is used, and instantaneous classes are applied to
    every state reached. *)

val actions : t -> string list
(** The names of all actions of the model. *)

val predicates : t -> string list
(** The names of all predicates of the model. *)

val holds : t -> Big.t -> string -> bool
(** [holds m s p] is true if predicate [p] holds in state [s].

    @raise Not_found if the model has no predicate [p]. *)

val same_state : Big.t -> Big.t -> bool
(** True if two states are the same bigraph (up to isomorphism). *)
