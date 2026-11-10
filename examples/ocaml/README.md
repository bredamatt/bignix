# The bigraph library in OCaml

The same models as in `examples/bigrapher/tutorial`, written with the
`bigraph` OCaml library in place of a `.big` file. Each file has the `.big`
lines as comments above the OCaml that does the same.

| OCaml                         | `.big` file |
|-------------------------------|-------------|
| `tutorial/expressions.ml`     | `03-bigraph-expressions/expressions.big` |
| `tutorial/reaction_rules.ml`  | `06-reaction-rules/reaction-rules.big` |
| `tutorial/conditional.ml`     | `07-conditional-reaction-rules/conditional.big` |
| `tutorial/reactive_blocks.ml` | `08-reactive-system-blocks/reactive-blocks.big` |
| `tutorial/action.ml`          | `11-action-reactive-systems/example-1/action.big` |

Each program builds the transition system and prints it in PRISM format,
as `bigrapher full -p` does.

Inside `nix-shell`, from this folder:

```sh
dune build
dune exec tutorial/action.exe
./compare.sh    # check each program against bigrapher's output for its .big file
```

The linker prints `directory not found for option '-Lgbs/src'` warnings.
They come from the bigraph library and can be ignored.
