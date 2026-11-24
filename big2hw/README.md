# big2hw

Reads a BigraphER model (a `.big` file) of two FPGA boards and builds the
two circuits with [Hardcaml](https://github.com/janestreet/hardcaml), as
Verilog. It then checks that every clock cycle of the circuits is something
the model's reaction rules can do.

```
            read the first state            build                print
 crs.big ──────────────────────▶ design ──────────▶ Hardcaml ──────────▶ Verilog
    │      boards, pins, fibres,                    circuits
    │      machines, symbols                           │
    │                                                  │ simulate every state
    │      apply the rules in every way                ▼ with every input
    └──────────────────────────▶ 276 states ◀──── compare, cycle by cycle
```

New to it? Start with [examples/](examples): the smallest model big2hw
builds, explained part by part.

The circuits work at the level of the model. A symbol on a fibre is a small
number, and a tag either verifies or does not. No cryptography and no
optical link is built.

## Run it

The example is `models/multi-perspective/src/crs.big` in the bigraph-sidc
repository, which has this repository as its `bignix` folder. That model
describes one cross-realm solution: a transmit FPGA in the ServerRoom, a
receive FPGA in the Interface, and two one-way fibres between them. Its
README explains the model.

From the top of bigraph-sidc:

```sh
nix-shell bignix/shell.nix
cd models/multi-perspective
big2hw src/crs.big                # what was read
big2hw src/crs.big -o out/hw      # the circuits, as Verilog
big2hw src/crs.big --check        # compare the circuits with the rules
big2hw src/crs.big --run "load Response,-,-,-,take"
```

`-o` writes four files: `crs_server_room.v` and `crs_interface.v`, one for
each board; `crs.v`, both boards with the fibres as wires between them; and
`crs_codes.vh`, the code of each symbol and each state by name, for Verilog
written by hand against the circuits.
A board is named after the realm it stands in, and the design after the
file.

### What was read

```
Symbols: what a fibre or a buffer carries, 3 bits. 0 is nothing.
    1  Pulse
    2  Tag
    3  BadTag
    4  Response    (payload)
    5  Weights    (payload)

Board server_room: circuit crs_server_room
  The transmit machine. State register tx_state, 2 bits:
    0  TxIdle       --Load--> TxLoaded
    1  TxLoaded     --SendPulse--> TxRequested
    2  TxRequested  --SendTag--> TxTagged
    3  TxTagged     --SendPayload--> TxIdle
  in   load[2:0]
  out  ctl_o[2:0], dat_o[2:0], tx_state[1:0], tx_buf[2:0]

Board interface: circuit crs_interface
  The channel control. State register cc_state, 2 bits:
    0  Idle     --Pulse--> Armed
    1  Armed    --Tag--> Open
    2  Open     --Response--> Idle    (drives the gate's enable wire)
    3  Blocked  no transition out    (the state it fails to)
  in   ctl_i[2:0], dat_i[2:0] (also to the gate), haz_i, rx_take
  out  rx_buf[2:0], cc_state[1:0], gate_enable, dat_held[2:0], dat_clash

Fibres, and the whole system as circuit crs:
    ctl_o -> ctl_i
    dat_o -> dat_i
```

Every circuit also has the inputs `clock` and `clear`. `clear` is a
synchronous reset. `dat_held` is a payload that waits at the data detector,
and `dat_clash` is high when more light arrives while one waits.

### A run

`--run` simulates both circuits from reset. Cycles are separated by commas.
In a cycle, the surroundings can do any of `load PAYLOAD`, `damage` (a tag on
a fibre is damaged), `tamper` (the sensor trips) and `take` (the receiving
realm takes the response), joined by `+`. `-` is a cycle in which they do
nothing. `--vcd FILE` also writes the waveforms.

```
$ big2hw src/crs.big --run "load Response,-,-,-,take,load Weights,-,-,-"
cycle  inputs         ctl_i  dat_i     enable  tx           cc       rx.buf    alarm
1      load Response  -      -         0       TxLoaded     Idle     -         0
2      nothing        Pulse  -         0       TxRequested  Armed    -         0
3      nothing        -      Tag       0       TxTagged     Open     -         0
4      nothing        -      Response  1       TxIdle       Idle     Response  0
5      take           -      -         0       TxIdle       Idle     -         0
6      load Weights   -      -         0       TxLoaded     Idle     -         0
7      nothing        Pulse  -         0       TxRequested  Armed    -         0
8      nothing        -      Tag       0       TxTagged     Open     -         0
9      nothing        -      Weights   1       TxIdle       Blocked  -         0
```

`ctl_i`, `dat_i` and `enable` are what the fibres and the enable wire carry
during the cycle. The other columns are the registers after it. In cycle 9
the weights reach the gate while it is enabled. The channel control has no
transition for them, so nothing passes and it goes to Blocked.

## How the bigraph becomes a circuit

Only the first state of the model is read for this. In `crs.big` the state
machines are part of the bigraph, not of the rules, so the first state holds
everything a circuit needs.

| In the bigraph | In the circuit |
|---|---|
| `Layout{b}`, on the link of an `FPGA` board | One circuit, named after the realm the board stands in |
| `Machine` and its `State` nodes | A state register. Each state has a code. |
| `Now{s, r}` | The state on link `s` has code 0, so a cleared register holds it. The block on link `r` (`Tx` or `CC`) owns the register. |
| `Trans.(L \| To{t})` inside a state | One branch of the next-state logic: on `L`, go to the state on link `t` |
| `Drive{e}` inside a state, `Enable{e}` inside the `Gate` | The enable wire: high while the machine is in that state |
| A pin: `CtlOut`, `DatOut`, `In`, `HazIn` | A port. `CtlOut` is `ctl_o`. The pin that reads the far end of that fibre is `ctl_i`. |
| `Laser{o, f}` and `Detector{f, i}` | A fibre. In `crs.v` it is a wire from the transmit port to the receive port. |
| `Gate`, with `NetOut{n}` and the `NetIn{n}` of `Rx` | The net `gate_net`, from the data input to the receive buffer |
| `Buf` | A register that holds one symbol, or 0 |
| `Sensor{h}` on the link of `HazIn{h}` | The input `haz_i` |
| A control inside a `Light`, in any rule | A symbol. They are numbered from 1 in the order the rules mention them. |
| A control inside a `Buf`, in any rule | A payload: a symbol the buffers can hold |

Links closed in the model have no name once it is evaluated, so a port is
named after its pin and not after its link.

### What the rules become

The rules are not translated one by one. They say what the controls mean,
and big2hw has that meaning built in. `--check` then compares the circuits
with the rules, so a circuit that does not follow them is found.

**The transmit machine** takes the one transition out of its state in each
cycle. The label says what it does on the way:

| Label | In that cycle | Rule |
|---|---|---|
| `Load` | Waits until `load` holds a payload and the buffer is empty, and stores it | `load_response`, `load_weights` |
| `SendPulse` | Puts Pulse on `ctl_o` | `tx_request` |
| `SendTag` | Puts Tag on `dat_o` | `tx_tag` |
| `SendPayload` | Puts the stored payload on `dat_o`, and empties the buffer | `tx_send` |

**The receiving board** does this in one cycle, in this order:

| Step | What happens | Rule |
|---|---|---|
| 1 | If `haz_i` is high, the channel control is in Blocked from here on | `block_hazard` |
| 2 | If `rx_take` is high, the receive buffer is emptied | `rx_take` |
| 3 | The control fibre is read, then the data fibre. A symbol the current state has a transition for moves the machine along it. | `step_pulse`, `step_tag` |
| | Any other symbol moves it to Blocked. In Blocked, every symbol is discarded. | `block_*`, `drop` |
| 4 | A payload the current state has a transition for passes the gate into the receive buffer, if that state drives the enable wire and the buffer is empty | `carry` |
| | If the buffer is full, the payload waits (`dat_held`) and is tried again in the next cycle | no rule applies yet |

Step 1 comes first because `block_hazard` is in the model's first priority
class.

## The check

`--check` asks whether the circuits do only what the model does.

```
$ big2hw src/crs.big --check
The model has 276 states.
The circuits reach 45 states. Each was tried with every input: 1080 clock cycles.
Every cycle is a run of the model's reaction rules.
So the circuits do nothing the model cannot do. That they do what they
should is not checked here: see the predicates below, and the tests.
In no cycle did light reach a detector that still held some.
Predicates of the model, and the circuit states each holds in:
  bad_reverse_fibre      none
  bad_weights_out        none
  bad_enable_idle        none
  bad_enable_armed       none
  bad_enable_blocked     none
  bad_two_states         none
  bad_blocked_exit       none
  bad_blocked_entry      none
  cc_idle                6
  cc_open                7
  cc_blocked             28
  rx_empty               21
  rx_full                24
  pulse_waiting          none
  tag_waiting            none
  bad_tag_waiting        none
  response_waiting       3
  alarm                  14
  weights_loaded         19
```

It exits with status 1 if a cycle is not a run of the rules, and prints the
state before, the inputs and the state after.

### How it works

1. It builds every state the model can reach, as `bigrapher full` does.
2. It simulates both circuits together with what surrounds them in the
   model: software that loads a response or the weights, a fibre that can
   damage a tag, a tamper sensor, and a realm that takes the response.
3. From reset, it tries every input in every state the circuits reach.
4. For each cycle it looks for a run of the rules, from the model state that
   looks like the circuits before the cycle to the one that looks like them
   after it.

Two states look the same if both machines are in the same state, both
buffers and both detectors hold the same, and the alarm is the same.

The run may use any rules, with these limits:

- The alarm goes up only if `tamper` was high in that cycle.
- The transmit buffer fills only with the payload that was on `load`.
- The receive buffer empties only if `take` was high.
- Light reaches a detector only if that symbol was on that fibre.
- Each of these happens at most once.
- The run does not end in a state the model leaves at once: one in which a
  rule of the first priority class can fire.

The limits are about effects, not rule names, as the properties in
`props/crs.props` are.

### What it means

Every state the circuits reach is a state of the model. So a predicate that
holds in no state of the model holds in no state of the circuits: the eight
`bad_` predicates above. PRISM proved those for the model.

Every cycle is a run of the rules. So no sequence of cycles does what no
sequence of reactions does. This carries over the properties that say
something never happens.

It does not carry over properties that say something can happen. A circuit
that never did anything would pass, and so would one that ignored `rx_take`.
That the circuits do deliver is tested by simulation (`test/test_hw.ml`), and
the list of predicates shows which states they reach.

The enable wire and the fibres are compared only through what they do to the
registers. That the enable wire is high only in Open is tested by simulation
(03 in `test/test_hw.ml`).

The tests also build three wrong circuits and check that each is caught:
one that opens on a damaged tag, one with no hazard pin, and one that fails
to Idle and not to Blocked.

### What it shows about the model

- **The circuits reach 45 of the model's 276 states.** A circuit reads a
  symbol in the cycle it arrives. In the model a symbol can lie at a
  detector while other things happen.
- **`pulse_waiting` and `tag_waiting` hold in no circuit state.** The first
  finding of the model's README, a tag read before its pulse, cannot happen
  in these circuits. This rests on both boards having one clock and both
  fibres one delay, which is the timing rule that README asks for.
- **The second finding does happen.** A response that arrives while the
  receive buffer is full waits at the detector. The pulse of the next
  transfer then blocks the channel control (`test/test_hw.ml`, 12b).
- **The model's transmit rules wait for a free detector.** A transmitter
  cannot see the far end of a diode. The circuits send without looking. The
  check counts the cycles in which light reaches a detector that still holds
  some, and with this protocol there are none.

## Where the circuit says more than the model

A circuit needs an answer for every input. The model has no rule for these,
and its transmit machine never causes them, so `--check` does not reach
them. Each fails secure, and each is tested on the receiving board alone.

| Input | The model | The circuit |
|---|---|---|
| A code that is no symbol (6 or 7) | Has no such light | Blocked |
| A payload on the control fibre, in a state with a transition for it | It stays at the detector for ever | Blocked |
| Light on the data fibre while a payload still waits there | The transmit logic waits | Blocked, and both are discarded |
| Symbols on both fibres in one cycle | Either order | The control fibre first |
| `load` holds something that is not a payload | Software loads only payloads | Ignored |

## What it refuses

Each of these stops the tool with a message.

| Case | Why |
|---|---|
| The channel control has no state named `Blocked` | It has nowhere to fail to |
| `Blocked` has a transition out | The channel control must stay Blocked (property 05) |
| Two transitions with one label out of one state | The circuit cannot choose |
| A transmit state with two transitions | The circuit cannot choose |
| Two `Now` tokens for one block | One register, one state (property 04) |
| A transition for a payload in a state that does not drive the gate | No rule carries it |
| A transition label of the channel control that no rule puts on a fibre | It can never be taken |
| A transition label of the transmit machine other than the four above | big2hw does not know what to send |
| `SendTag` with no `Cred` in `Tx`; `SendPayload` or `Load` with no `Buf`; a send with no pin | The rule for it can never fire |
| A pin that reaches no laser, detector or sensor; a gate that reaches no `Rx` | Nothing to wire it to |
| A first state with something in a buffer or at a detector, or with the alarm up | A cleared circuit starts empty |
| A `Light` or a `Buf` that holds two things, in the first state or in a rule | A fibre carries one symbol at a time |
| A fibre from a pin of `Tx` to a detector that no `In` pin reads | Nothing would read what is sent |
| Both boards in one realm; a gate and the `Rx` it feeds in two layouts | One board in each of two realms |
| More than one `Tx` block or `CC` block; a model that is not a `pbrs` | Outside this version |

## Synthesis

The Verilog is plain: registers, comparisons and multiplexers. With yosys
0.51, `synth_ice40` reports no problems and these sizes:

| Circuit | LUTs | Flip-flops |
|---|---|---|
| `crs_server_room` | 11 | 5 |
| `crs_interface` | 28 | 8 |
| `crs` | 35 | 13 |

```sh
cd out/hw
yosys -p 'read_verilog crs_interface.v; synth_ice40 -top crs_interface; stat'
```

## Not built

- **Bits.** A tag is one symbol. A real tag is a message authentication code
  over a frame, checked against the credential.
- **Two clocks.** Each board has its own clock in practice, and a fibre needs
  a serial link with clock recovery.
- **A transmit FPGA that misbehaves.** `--check` uses the transmit machine of
  the model, and big2hw only tests the table above. For `crs.big`, properties
  of the receiving board are proved for any input with SymbiYosys. They are
  written by hand, next to the model: see its README.
- **Other shapes.** One transmit block, one channel control, one gate.

## Files

| File | Content |
|------|---------|
| [src/bg.ml](src/bg.ml) | A `.big` file as a model, and a bigraph as plain data |
| [src/design.ml](src/design.ml) | The design read from a bigraph, and what a state looks like from outside |
| [src/hw.ml](src/hw.ml) | The circuits, in Hardcaml |
| [src/sim.ml](src/sim.ml) | Both circuits and their surroundings, simulated, and the text of `--run` |
| [src/space.ml](src/space.ml) | Every state the model can reach |
| [src/conform.ml](src/conform.ml) | The check |
| [src/report.ml](src/report.ml) | The texts printed above |
| [frontend/](frontend) | BigraphER's parser, built as a library (as in `ast-sim`) |
| [examples/](examples) | `gate.big`, the smallest model, with a walkthrough |
| [test/](test) | 49 tests. `test/models/crs.big` is a copy of the model: keep it in step. |

Run the tests with `dune runtest` in this folder, inside the nix-shell. They
also run when nix builds the package.
