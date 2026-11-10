(** A stress-testing problem: a model, what counts as a failure, and what a
    run costs. A run is a sequence of steps from the initial state. It ends
    at the first failure state, at a state with no transitions, or after
    [max_depth] steps. The searches look for the failing run of least cost. *)

open Bigraph

(** The cost of choosing an action. The model gives probabilities only to
    the outcomes of an action, not to the choice between actions. *)
type choice =
  | Free of float
      (** Choices cost nothing. The number is a small cost added to every
          step, so that shorter runs win ties. *)
  | Uniform  (** Each action that can be taken is equally likely. *)
  | Weights of (string * float) list
      (** An action is chosen in proportion to its weight, among the actions
          that can be taken. *)

type t

type step = {
  transition : Model.transition;
  cost : float;
      (** The cost of the choice plus [-log] of the outcome's probability. *)
}

type path = { steps : step list; cost : float }

exception Error of string

val make :
  model:Model.t ->
  failure:Failure.t ->
  choice:choice ->
  max_depth:int ->
  penalty:float ->
  t
(** [penalty] is the cost of a run that ends without a failure.

    @raise Error if the settings do not fit the model. *)

val model : t -> Model.t
val max_depth : t -> int
val penalty : t -> float

val failed : t -> Big.t -> bool
(** True if a state is a failure. *)

val steps : t -> Big.t -> step list
(** The steps that can be taken from a state, with their costs. *)

val path : step list -> path

val likelihood : path -> float
(** The product of the outcome probabilities along a path. *)
