# ast-sim

Adaptive stress testing (AST) for BigraphER models. Given a `.big` file and
a list of checks, each a definition of failure, it searches for the most
likely run of the model that ends in each failure.

It works on action BRS models (`begin abrs`), which define a Markov decision
process (MDP): rules have weights and are grouped into actions. A model with
probabilities, but no choices (a `pbrs`) can be used by putting all of its
rules into one action.

## Run it

Inside `nix-shell`, at the top of the repository:

```sh
ast-sim examples/ast-sim/routes/mcts.json
```

```
model:   examples/ast-sim/routes/routes.big
solver:  mcts, 1000 runs for each check, seed 0

id   result     likelihood  steps  description
L1   reached    0.25        2      The run reaches Fail
H1   reached    0.9         1      The run is stuck in Dead
SC1  not found  -           -      Fail and Dead never hold together

L1: cost 1.40629
  failed in 982 of the runs tried
   1. go -> go_hit   p = 0.5
   2. push -> push_hit   p = 0.5

H1: cost 0.115361
  failed in 989 of the runs tried
   1. short -> short_miss   p = 0.9
```

To build only the package: `nix-build -A ast-sim`.

## What it searches for

A run starts in the model's initial state. At each step, an action is
chosen and one of its outcomes happens. The run ends at the first failure
state, at a state where no rule applies, or after `max_depth` steps.

The cost of a step is

    cost of the choice  -  log(probability of the outcome)

and the search looks for the failing run with the least total cost. The
model gives the probability of each outcome. It gives no probability to the
choice between actions, so the cost of a choice is a setting (`choice`):

| `mode`    | Cost of choosing an action                                   | The result is                                            |
|-----------|--------------------------------------------------------------|----------------------------------------------------------|
| `free`    | `step_cost`, a small cost per step so shorter runs win ties   | the failure that needs the least luck, under the best choices |
| `uniform` | `log(n)`, with `n` actions to choose from                     | the most likely failure when actions are picked at random |
| `weights` | `-log` of the action's share of the weights of the `n` actions | the most likely failure under your own model of the choices |

With `free`, the search makes every choice. If some actions belong to the
system under test, not to its environment, give them a fixed behaviour in
the model (with priority classes or weights), or use `weights`.

## Settings

A JSON file. Only `model` and `checks` are required; the other values
below are the defaults.

```json
{
  "model": "model.big",
  "consts": { "pad": 1 },
  "checks": [
    { "id": "L1", "failure": "leak_em | leak_traffic",
      "description": "The attacker learns the model's output" }
  ],
  "choice": { "mode": "free", "step_cost": 0.01 },
  "max_depth": 100,
  "penalty": 100,
  "solver": { "type": "mcts", "iterations": 10000, "exploration": 1.0, "seed": 0 }
}
```

| Setting     | Meaning |
|-------------|---------|
| `model`     | The `.big` file. A relative path starts at the settings file. |
| `consts`    | Values for constants the model uses but does not declare, as bigrapher's `-c`. |
| `checks`    | What to search for, one row each. `id` names the row. `failure` is an expression over the model's predicates (`preds`), with `!`, `&`, `\|` and parentheses. `description` is optional. Each check is a separate search. |
| `choice`    | See above. For weights: `{ "mode": "weights", "weights": { "action": 2.0 } }`, with every action of the model. |
| `max_depth` | The most steps in a run. |
| `penalty`   | The cost of a run that does not fail. Keep it above the cost of any failing run you care about. |
| `solver`    | `mcts` or `exact`, see below. |

Solvers:

- `{ "type": "mcts", "iterations", "exploration", "seed" }`: Monte Carlo
  tree search (MCTS). It tries `iterations` runs and visits only the states on
  them, so it works on models too large to enumerate. `exploration` is how
  much it favours steps it has tried less. The same `seed` gives the same
  result. It may not find the best run, or any.
- `{ "type": "exact", "max_states": 10000 }`: explores every state within
  `max_depth` steps and returns the best run. Use it on small models, and
  to check what `mcts` finds.

## Results

| Result          | Meaning |
|-----------------|---------|
| `reached`       | A run that ends in the failure was found. It is listed below the table. |
| `not reachable` | `exact` only: no run within `max_depth` steps ends in the failure. |
| `not found`     | `mcts` only: none of the runs tried ended in the failure. One may still exist. |

## Checks for an STPA-Sec analysis

Write each loss, hazard, unsafe control action and constraint as a
predicate of the model, and give each a check:

| Row               | `failure`                                          | A run that reaches it is |
|-------------------|----------------------------------------------------|--------------------------|
| Loss, hazard      | the predicate                                      | a loss scenario |
| Unsafe control action | a predicate for the action in its context      | a scenario with that action |
| Constraint        | `!` the predicate that must always hold            | a violation |

A predicate sees one state. What happened before, and in which order, must
be kept in the state for a predicate to see it: have the rule leave a
marker node behind.

## A difference from bigrapher

When two actions can lead from a state to the same state, `bigrapher full`
merges the two transitions before it turns weights into probabilities,
and the probabilities it exports are wrong (for `routes.big` it gives
`go` probability 1, not 0.5 and 0.5). ast-sim steps each action on its own
and does not have this problem. Its probabilities therefore differ from an
exported `.tra` file for such models.

## Layout

| Folder      | Content |
|-------------|---------|
| `frontend/` | bigrapher's `.big` parser, built as a library from the sources in `bigraph-tools` (found through `BIGRAPHER_SRC`, which the Nix files set). |
| `src/`      | `Model` (load, step), `Failure`, `Problem` (costs), `Exact`, `Mcts`, `Config`, `Report`. |
| `bin/`      | The `ast-sim` command. |
| `test/`     | Tests: `dune runtest`, inside `nix-shell`. |
