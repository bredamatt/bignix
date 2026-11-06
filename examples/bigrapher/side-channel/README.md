# Side-channel threat modelling

## Instructions

### Generating the state diagrams

To generate the bigraph diagrams for this execute:

```
bigrapher full -c pad=0,door=0,mask=0   -t out/ts -s out/states -f svg  side-channel.big
```

Note that the `out/states/` directory must already exist.

To generate the diagrams for all 8 protocol settings, each into its own
folder under `out/` (e.g. `out/pad1-door0-mask1/`), run this from this
folder:

```sh
for p in 0 1; do for d in 0 1; do for m in 0 1; do
  o=out/pad$p-door$d-mask$m
  mkdir -p $o/states
  bigrapher full -q -c pad=$p,door=$d,mask=$m -t $o/ts -s $o/states -f svg side-channel.big
done; done; done
```

### Model checking certain properties

