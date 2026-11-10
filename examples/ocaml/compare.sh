#!/bin/sh
# Check that each OCaml example builds the same transition system as the
# .big file it was written from. Run inside nix-shell, from this folder:
#
#   dune build && ./compare.sh
#
# Each line below is: the OCaml example, its .big file, and the bigrapher
# exports the example prints, in the order it prints them (p = transitions,
# l = labels, r = state rewards, R = transition rewards).
set -eu

tutorial=../bigrapher/tutorial
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=0

while read -r name big exports; do
  flags=""
  files=""
  for e in $exports; do
    flags="$flags -$e $tmp/$name.$e"
    files="$files $tmp/$name.$e"
  done
  # shellcheck disable=SC2086 # flags and files are lists of words
  bigrapher full -q $flags "$tutorial/$big" > /dev/null
  # shellcheck disable=SC2086
  cat $files > "$tmp/$name.big.out"
  "./_build/default/tutorial/$name.exe" > "$tmp/$name.ml.out"
  if diff "$tmp/$name.big.out" "$tmp/$name.ml.out" > /dev/null; then
    echo "same    $name"
  else
    echo "DIFFER  $name"
    diff "$tmp/$name.big.out" "$tmp/$name.ml.out" || true
    status=1
  fi
done <<LIST
expressions      03-bigraph-expressions/expressions.big            p
reaction_rules   06-reaction-rules/reaction-rules.big              p
conditional      07-conditional-reaction-rules/conditional.big     p
reactive_blocks  08-reactive-system-blocks/reactive-blocks.big     p l r
action           11-action-reactive-systems/example-1/action.big   p R
LIST

exit $status
