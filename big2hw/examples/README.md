# The smallest example: a pulse opens a gate

[gate.big](gate.big) is the smallest model big2hw builds. It has what
`crs.big` has, with everything left out that is not needed to see how a
bigraph becomes a circuit: no tag, no credential, no hazard line, one kind
of message.

```
   Sender                                          Receiver
 ┌──────────────────┐     control fibre       ┌───────────────────────────┐
 │ Tx               ├──── Pulse ────────────▶ │ CC   Closed ─Pulse▶ Open  │
 │  TxIdle          │                         │        ▲              │   │
 │   │ Load         │                         │        └──── Msg ─────┘   │
 │  TxLoaded        │                         │              enable       │
 │   │ SendPulse    │     data fibre          │                │          │
 │  TxRequested     ├──── Msg ──────────────▶ │ ────────────▶ Gate ─▶ Buf │
 │   │ SendPayload  │                         │                           │
 └──────────────────┘                         └───────────────────────────┘
```

The sending board puts a pulse on the control fibre, then a message on the
data fibre. The receiving board opens its gate when it sees the pulse, lets
one message through into a buffer, and closes the gate again.

Read this page with `gate.big` open beside it.

## Run it

Inside `nix-shell` (from the `bignix` folder), in this folder:

```sh
big2hw gate.big                    # what was read
big2hw gate.big --run "load Msg,-,-,take"
big2hw gate.big --check            # compare the circuits with the rules
big2hw gate.big -o out             # Verilog
```

## Part 1: the first state is the circuit diagram

big2hw builds the circuits from `big system`, the first state of the model.
It is made of three bigraphs.

### `big boards`: modules and fibres

```
big boards =
  Sender.FPGA{b_tx}.(Laser{ctl_o, ctl_f} | Laser{dat_o, dat_f})
  | Receiver.FPGA{b_rx}.(Detector{ctl_f, ctl_i}.1 | Detector{dat_f, dat_i}.1);
```

| In the bigraph | In the circuit |
|---|---|
| `FPGA{b_tx}` inside `Sender` | The Verilog module `gate_sender` |
| `FPGA{b_rx}` inside `Receiver` | The Verilog module `gate_receiver` |
| The link `ctl_f`, with a `Laser` and a `Detector` on it | A fibre: in `gate.v`, a wire from the port `ctl_o` to the port `ctl_i` |
| The link `dat_f` | The other fibre: `dat_o` to `dat_i` |

A fibre is one-way because of what is on it: a laser at one end and a
detector at the other. Nothing at the detector's end can send.

### `big layouts`: pins, the gate and the buffers

```
big layouts =
  Layout{b_tx}.Tx{r_tx}.(CtlOut{ctl_o} | DatOut{dat_o} | Buf.1)
  | /net Layout{b_rx}.( CC{r_cc}.(In{ctl_i} | In{dat_i})
                      | Gate.(DatIn{dat_i} | Enable{en} | NetOut{net})
                      | Rx.(NetIn{net} | Buf.1) );
```

A link says what is wired to what. `Layout{b_tx}` is on the link of
`FPGA{b_tx}`, so it is what is configured on that board. `CtlOut{ctl_o}` is
on the link of a laser, so it is the pin that drives that laser.

| In the bigraph | In the circuit |
|---|---|
| `CtlOut{ctl_o}`, `DatOut{dat_o}` | The output ports `ctl_o` and `dat_o` of `gate_sender` |
| `In{ctl_i}`, `In{dat_i}` | The input ports `ctl_i` and `dat_i` of `gate_receiver` |
| `DatIn{dat_i}`, on the same link as `In{dat_i}` | The gate's data input is the data fibre |
| `Enable{en}` | The gate's enable wire, `gate_enable` |
| `NetOut{net}` and `NetIn{net}` | The net `gate_net`, from the gate to the receive buffer |
| `Buf` in `Tx`, `Buf` in `Rx` | The registers `tx_buf` and `rx_buf` |

### `big tx_machine` and `big cc_machine`: registers

```
big cc_machine =
  /c0 /c1 /c2
  Machine.( State{c0}.(Closed | Trans.(Pulse | To{c1}))
          | State{c1}.(Open | Drive{en} | Trans.(Msg | To{c0}))
          | State{c2}.Blocked
          | Now{c0, r_cc} );
```

Each state has a link of its own. A transition points at a state by being
on its link: `To{c1}` leads to the state `State{c1}`. The token `Now{c0,
r_cc}` is on two links: `c0`, the current state, and `r_cc`, the link of the
block `CC{r_cc}` that the machine belongs to.

| In the bigraph | In the circuit |
|---|---|
| The three `State` nodes | The register `cc_state`, 2 bits. Closed is 0, Open is 1, Blocked is 2. |
| `Now{c0, r_cc}` | Closed has code 0: a cleared register holds it |
| `Trans.(Pulse \| To{c1})` in Closed | If the state is 0 and a pulse arrives, the next state is 1 |
| `Drive{en}` in Open, on the link of `Enable{en}` | `gate_enable` is high while the state is 1 |
| `State{c2}.Blocked`, with no transition | Where the machine goes on anything it has no transition for. It never leaves. |

`big2hw gate.big` prints what it read:

```
Symbols: what a fibre or a buffer carries, 2 bits. 0 is nothing.
    1  Pulse
    2  Msg    (payload)

Board sender: circuit gate_sender
  The transmit machine. State register tx_state, 2 bits:
    0  TxIdle       --Load--> TxLoaded
    1  TxLoaded     --SendPulse--> TxRequested
    2  TxRequested  --SendPayload--> TxIdle
  in   load[1:0]
  out  ctl_o[1:0], dat_o[1:0], tx_state[1:0], tx_buf[1:0]

Board receiver: circuit gate_receiver
  The channel control. State register cc_state, 2 bits:
    0  Closed   --Pulse--> Open
    1  Open     --Msg--> Closed    (drives the gate's enable wire)
    2  Blocked  no transition out    (the state it fails to)
  in   ctl_i[1:0], dat_i[1:0] (also to the gate), rx_take
  out  rx_buf[1:0], cc_state[1:0], gate_enable, dat_held[1:0], dat_clash

Fibres, and the whole system as circuit gate:
    ctl_o -> ctl_i
    dat_o -> dat_i
```

The symbols are not in the first state. They are read from the rules:
`Pulse` and `Msg` are the controls that some rule puts inside a `Light`, and
`Msg` is the one that some rule puts inside a `Buf`.

## Part 2: the rules say what the parts do

A rule does not name a state. It names a shape:

```
Now{s, r} || State{s}.(Trans.(Pulse | To{t}) | id)
```

reads "the current state of the machine of block `r` has a transition
labelled Pulse, to the state on link `t`". The rule takes the transition by
putting the token on `t`. So one rule serves every state and every machine,
and changing the machine means changing the first state, not the rules.

| Rule | What it says | In the circuit |
|---|---|---|
| `load` | Software puts a message in the empty transmit buffer | `load` holds 2 while `tx_state` is 0 and `tx_buf` is 0: `tx_buf` becomes 2, `tx_state` becomes 1 |
| `tx_pulse` | The transmit logic puts a pulse on the control fibre | `tx_state` is 1: `ctl_o` is 1 in that cycle, `tx_state` becomes 2 |
| `tx_send` | It moves its buffer onto the data fibre | `tx_state` is 2: `dat_o` is `tx_buf` in that cycle, `tx_buf` becomes 0 |
| `step_pulse` | A pulse arrives, and the current state has a transition for it | `ctl_i` is 1 while `cc_state` is 0: `cc_state` becomes 1 |
| `carry` | A message arrives while the current state drives the enable wire, and the receive buffer is empty | `dat_i` is 2 while the state is 1: `rx_buf` becomes 2, `cc_state` becomes 0 |
| `block_pulse` | A pulse arrives, and the current state has no transition for it | `ctl_i` is 1 while the state is 1: `cc_state` becomes 2 |
| `drop` | In Blocked, whatever arrives is discarded | In state 2, nothing changes |
| `rx_take` | The receiving realm takes the message | `rx_take` is high: `rx_buf` becomes 0 |

big2hw does not translate the rules. It knows what `State`, `Trans`, `Now`,
`Drive`, `Gate` and `Buf` mean, and builds the right-hand column from the
first state alone. The rules are what `--check` compares the circuits with.

## Part 3: a run, cycle by cycle

```
$ big2hw gate.big --run "load Msg,-,-,take,load Msg,-,-,load Msg,-,-"
cycle  inputs    ctl_i  dat_i  enable  tx           cc      rx.buf
1      load Msg  -      -      0       TxLoaded     Closed  -
2      nothing   Pulse  -      1       TxRequested  Open    -
3      nothing   -      Msg    1       TxIdle       Closed  Msg
4      take      -      -      0       TxIdle       Closed  -
5      load Msg  -      -      0       TxLoaded     Closed  -
6      nothing   Pulse  -      1       TxRequested  Open    -
7      nothing   -      Msg    1       TxIdle       Closed  Msg
8      load Msg  -      -      0       TxLoaded     Closed  Msg
9      nothing   Pulse  -      1       TxRequested  Open    Msg
10     nothing   -      Msg    1       TxIdle       Open    Msg
```

`ctl_i`, `dat_i` and `enable` are wires, shown as they are during the cycle.
`tx`, `cc` and `rx.buf` are registers, shown as they are after it.

| Cycle | Reactions of the model |
|---|---|
| 1 | `load` |
| 2 | `tx_pulse`, then `step_pulse`. The board reads the pulse in the cycle it is sent, so `enable` is already high. |
| 3 | `tx_send`, then `carry` |
| 4 | `rx_take` |
| 5 to 7 | The same again. This time the message is not taken. |
| 8, 9 | `load`; then `tx_pulse` and `step_pulse` |
| 10 | `tx_send`, and no `carry`: the receive buffer is full. The message waits at the detector, and the channel control stays Open. |

One clock cycle is one or more reactions. A circuit does at once what the
model does in steps.

## Part 4: the check

```
$ big2hw gate.big --check
The model has 42 states.
The circuits reach 14 states. Each was tried with every input: 56 clock cycles.
Every cycle is a run of the model's reaction rules.
So the circuits do nothing the model cannot do. That they do what they
should is not checked here: see the predicates below, and the tests.
In no cycle did light reach a detector that still held some.
Predicates of the model, and the circuit states each holds in:
  open                   4
  blocked                6
  delivered              8
  bad_enable_closed      none
  bad_enable_blocked     none
```

The 42 states are every bigraph the rules can reach from `system`, as
`bigrapher full gate.big` computes them. The check simulates the circuits in
every state they reach, with every input, and for each clock cycle looks for
a sequence of reactions that does the same, as in the table of part 3.

The circuits reach fewer states than the model because a circuit reads a
symbol in the cycle it arrives. In the model a pulse can lie at its
detector while the software loads the next message.

## Part 5: where it is in the code

| Step | File | Function |
|---|---|---|
| A `.big` file to bigraphs | [../src/bg.ml](../src/bg.ml) | `load`, `of_big` |
| The symbols, from the rules | [../src/design.ml](../src/design.ml) | `alphabet` |
| A machine, from `Now`, `State`, `Trans`, `To`, `Drive` | [../src/design.ml](../src/design.ml) | `machine` |
| Pins and fibres, from the links | [../src/design.ml](../src/design.ml) | `sender`, `receiver`, `across` |
| The sending board in Hardcaml | [../src/hw.ml](../src/hw.ml) | `sender` |
| The receiving board in Hardcaml | [../src/hw.ml](../src/hw.ml) | `receiver` |
| The 42 states | [../src/space.ml](../src/space.ml) | `build` |
| The check | [../src/conform.ml](../src/conform.ml) | `check` |

`sender` in `hw.ml` is about thirty lines and shows all the Hardcaml this
tool uses:

| Hardcaml | Meaning |
|---|---|
| `reg spec d` | A register that takes the value of `d` at each clock edge, and 0 on `clear` |
| `wire w`, then `x <== e` | Names a signal before saying what drives it. A register's next value depends on the register, so the wire comes first. |
| `mux2 c a b` | `a` if `c` is high, else `b` |
| `x ==:. 3` | High if `x` is 3 |
| `a &: b`, `a \|: b`, `~: a` | And, or, not |
| `x -- "name"` | Gives the signal that name in the Verilog |

The next state of the transmit machine is a chain of `mux2`, one for each
transition. In `out/gate_sender.v` it is these lines:

```verilog
assign do_load = _22 & _27;                           // state is 0, load holds a payload
assign _35 = do_load ? _41 : tx_state_reg;            // then 1, else stay
assign do_send_pulse = tx_state_reg == _41;           // state is 1
assign _37 = do_send_pulse ? _36 : _35;               // then 2
assign do_send_payload = tx_state_reg == _36;         // state is 2
assign _39 = do_send_payload ? _19 : _37;             // then 0
```

The comments are added here. `_19`, `_41` and `_36` are the constants 0, 1
and 2.

## Things to try

Each takes one edit of `gate.big`.

**1. Take `Drive{en}` out of Open.** The state that accepts a message no
longer opens the gate. big2hw refuses:

```
big2hw: Open has a transition for the payload Msg and does not drive the gate: no rule carries it
```

**2. Take `block_pulse` out of the list of rules** at the end of the file.
The first state is the same, so the circuits are the same. The model can no
longer block. `--check` finds four cycles that are not a run of the rules,
and exits with status 1. The first:

```
  before  alarm=0 at.ctl_i=- at.dat_i=Msg cc=Open rx.buf=Msg tx=TxLoaded tx.buf=Msg
  inputs  nothing
  after   alarm=0 at.ctl_i=- at.dat_i=- cc=Blocked rx.buf=Msg tx=TxRequested tx.buf=Msg
  the model has no such state
```

A message waits at the data detector, the next pulse arrives while the
channel control is Open, and the circuit blocks. The circuit needs an answer
for every input. The model now has none for this one.

**3. Let Open take a pulse:** add `| Trans.(Pulse | To{c1})` to Open. Now the
pulse of the next transfer does not block. The next message then arrives
while the last one still waits at the detector. `--check` finds eight cycles
that are not a run of the rules.

In the model, the transmit rules fire only when the detector is free
(`Detector{f, i}.1`). A transmitter cannot see the far end of a one-way
fibre, so the circuit sends anyway, and the receiving board fails to
Blocked. The model worked only because it let the sender look across the
diode.

**4. Give Closed a second transition,** for example `| Trans.(Pulse |
To{c2})`. big2hw refuses, because the circuit could not choose:

```
big2hw: Closed has two transitions labelled Pulse: the circuit cannot choose
```

## From here to `crs.big`

`crs.big` is this model with more in it:

| Added | What for |
|---|---|
| `Tag`, `BadTag`, `Cred`, the state `Armed` | The sender is authenticated before the gate opens |
| `Response` and `Weights` as payloads | One must pass and the other must not |
| `Sensor`, `HazIn`, `block_hazard` in a first priority class | A hazard line that blocks before anything else |
| The regions `Physical`, `Logical`, `Computational` | The three perspectives, named |
| More `block_` rules, and predicates for PRISM | Every symbol in every state has a rule; the properties |
