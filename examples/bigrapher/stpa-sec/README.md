# Checking a published STPA-Sec analysis

The rows of a published STPA-Sec analysis, written as predicates of a
bigraph model and checked with `ast-sim`.

## The case

The system and the analysis are the case study of:

> J. Yu, S. Wagner, F. Luo. *Data-Flow-Based Extension of the
> System-Theoretic Process Analysis for Security (STPA-Sec)*.
> [arXiv:2006.02930](https://arxiv.org/abs/2006.02930), 2020.

A user locks and unlocks the doors of a vehicle from a smartphone. The
control structure (Fig. 5 of the paper) has a user, a smartphone, a cloud
server and the door controller in the vehicle. The door controller
registers at the server, the phone sends lock and unlock commands to the
door controller over Bluetooth, and the phone shows the user the result.

[digital-key.big](digital-key.big) models one mission: the user is at the
unlocked vehicle, locks it from the phone, and walks away.

**From the paper:** the system, and every row below, with the paper's
identifiers and wording (Tables VI, IX and X). The paper gives a selection
of insecure control actions and loss scenarios as examples, not a full
list.

**Not from the paper:** the bigraph model, what the attacker can do in it,
and the probabilities. The probabilities are placeholders.

## The rows, and how each is checked

| Row | Text in the paper | Check |
|-----|-------------------|-------|
| **Losses** | | |
| L-1 | Loss of physical property (the vehicle and properties in it) | `stolen` |
| L-2 | Loss of non-physical property (manufacturer's reputation) | not in the model |
| **Vulnerabilities** | | |
| V-1 | Fail to lock the vehicle without being detected [L-1/2] | `door_unlocked & shows_locked` |
| V-2 | Fail to lock or unlock the vehicle, which can be detected by the user [L-2] | `shows_failed` |
| V-3 | Leak sensitive information [L-1/2] | `leaked` |
| **Constraints** | | A violation is searched for: |
| SC-1 | Missions should be completed successfully [V-1/2] | V-1 or V-2 |
| SC-2 | If the mission fails, it must be detected by the user [V-1] | the check for V-1 |
| SC-3 | Sensitive information should be protected from leaking [V-3] | the check for V-3 |
| SC-4 | If sensitive information is leaked, it should be detected and reactions need to be taken to minimize losses [V-3] | not checked |
| **Insecure control actions** | | |
| D_CA1_ICA1 | The door controller fails to register at the server [V-2] | not in the model |
| D_CA1_ICA2 | The door controller registers with data leakage risks [V-3] | `registered & leaked` |
| D_CA1_ICA3 | The action violates the timing limits [V-1] | not checked |
| U_CA2_ICA1 | The user is fooled to send wrong commands [V-1/2] | `sent_unlock` |
| **Loss scenarios** | | |
| U_CA2_ICA1_LS1 | The user interface of the smartphone is modified to guide the user to send wrong commands | the run found for U_CA2_ICA1 |
| U_CA2_ICA1_LS2 | The vehicle state is presented wrongly, which leads to the user's wrong behaviors | `door_unlocked & shows_locked & !sent_unlock` |

The checks are in [digital-key.json](digital-key.json). Each is an
expression over what the model's components hold:

- **A state of the system.** V-1 is "the door is unlocked and the phone
  shows that it is locked". Both are states of components, so the row is
  an expression over two predicates.
- **Something that happened.** U_CA2_ICA1 is about a command that was
  sent. A predicate sees only the current state, so the phone keeps the
  last command it sent (`SentLock`, `SentUnlock`), and the predicate looks
  for that.
- **A loss scenario.** A scenario is a run, not a state. `ast-sim` returns
  the most likely run that reaches a row, and that run is a scenario. To
  ask for a second scenario of the same row, exclude the first: the check
  for LS2 is V-1 without a wrong command having been sent.

## Run it

Inside `nix-shell`, from this folder:

```sh
ast-sim digital-key.json
```

```
id              result   likelihood  steps  description
L-1             reached  0.05        4      Loss of physical property
V-1             reached  0.05        2      Fail to lock the vehicle without being detected
V-2             reached  0.5         3      Fail to lock the vehicle, which can be detected by the user
V-3             reached  0.01        2      Leak sensitive information
SC-1            reached  0.5         3      Missions should be completed successfully
D_CA1_ICA2      reached  0.01        2      The door controller registers with data leakage risks
U_CA2_ICA1      reached  0.05        2      The user is fooled to send wrong commands
U_CA2_ICA1_LS2  reached  0.025       4      The vehicle state is presented wrongly

L-1: cost 3.03573
   1. modify -> modify_ok   p = 0.05
   2. lock -> lock_fooled   p = 1
   3. leave -> leave   p = 1
   4. steal -> steal   p = 1
...
U_CA2_ICA1_LS2: cost 3.72888
   1. register -> register_ok   p = 1
   2. jam -> jam_bluetooth   p = 1
   3. lock -> lock_jammed   p = 0.5
   4. spoof -> spoof_ok   p = 0.05
```

## Read the result

- **`reached`** means the row can happen in the model. The likelihood is
  that of the most likely run that gets there, listed below the table.
- **The run for L-1 is the paper's LS1**, carried through to the loss: the
  attacker modifies the app, the user's lock command is sent as unlock
  while the phone shows the doors locked, the user leaves, and the vehicle
  is emptied.
- **The run for U_CA2_ICA1_LS2 is the paper's LS2**: a jammed command
  fails, and the attacker replaces the failure on the display.
- **For a constraint, `reached` means it is violated.** SC-1 fails most
  easily through V-2: a jammed command, which the user sees.

The settings use the `exact` solver, so a `not reachable` would be a proof
for runs of up to `max_depth` steps.

## Change the numbers

The probabilities are declared at the top of [digital-key.big](digital-key.big):

| Constant | Meaning | Value |
|----------|---------|-------|
| `p_tamper` | The attacker gets a modified app onto the phone | 0.05 |
| `p_jam`    | A jammed Bluetooth command is lost | 0.5 |
| `p_spoof`  | The attacker gets a false result onto the phone's display | 0.05 |
| `p_break`  | The attacker reads registration data it has captured | 0.01 |

To try other values, edit them there. A constant that the model declares
cannot be set from outside, neither with bigrapher's `-c` nor with `consts`
in the settings.

With `p_tamper` and `p_spoof` both 0 (an app and a display that cannot be
interfered with), L-1, V-1, U_CA2_ICA1 and U_CA2_ICA1_LS2 become
`not reachable`. V-2 stays: jamming still makes a lock fail, but the user
sees it, which is what SC-2 asks for.

## What is not checked

- **L-2** (reputation) is not a state of this system.
- **SC-4** asks for a reaction after a leak. The model has no detection of
  leaks, and "eventually reacts" is not a property of one state.
- **D_CA1_ICA3** is about timing limits. The model has no time.
- **D_CA1_ICA1** (registration fails) and the scenarios of D_CA1_ICA3 are
  left out to keep the model small.
- **The session key exchange** of the paper's Fig. 3 is left out: a
  registered door controller accepts the phone's commands.

## With bigrapher

```sh
mkdir -p out/states
bigrapher full -t out/ts -s out/states -f svg digital-key.big
```

This gives the 98 states, and `-l` exports which predicates hold in which
state. Some of the exported probabilities are not right (see "A difference
from bigrapher" in the [ast-sim README](../../../ast-sim/README.md)).
