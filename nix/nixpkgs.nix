# The nixpkgs every package and the shell are built with.
# nixpkgs 25.05: OCaml 5.3.0, dune 3.18
import (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/25.05.tar.gz";
  sha256 = "1915r28xc4znrh2vf4rrjnxldw2imysz819gzhk9qlrkqanmfsxd";
}) { }
