(** The settings of one stress test, read from a JSON file:

    {v
    {
      "model": "model.big",           path, relative to the settings file
      "consts": { "pad": 1 },         values for the model's constants
      "checks": [                     what to search for, one row each
        { "id": "L1", "failure": "leak_em | leak_tr",
          "description": "The attacker learns the output" }
      ],
      "choice": { "mode": "free", "step_cost": 0.01 },
      "max_depth": 100,               the most steps in a run
      "penalty": 100,                 the cost of a run that does not fail
      "solver": { "type": "mcts", "iterations": 10000,
                  "exploration": 1.0, "seed": 0 }
    }
    v}

    Only "model" and "checks" are required; the other values above are the
    defaults. In a check, "failure" is an expression over the model's
    predicates, and "description" is optional. "choice" can also be [{ "mode": "uniform" }] or
    [{ "mode": "weights", "weights": { "action": 2.0, ... } }]. "solver" can
    also be [{ "type": "exact", "max_states": 10000 }]. *)

type solver = Mcts of Mcts.config | Exact of { max_states : int }

type check = { id : string; description : string; failure : Failure.t }

type t = {
  model : string;
  consts : (string * Model.const) list;
  checks : check list;  (** At least one, with different ids. *)
  choice : Problem.choice;
  max_depth : int;
  penalty : float;
  solver : solver;
}

exception Error of string

val of_file : string -> t
(** @raise Error if the file cannot be read or a setting is not valid. *)
