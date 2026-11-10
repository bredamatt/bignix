# The packages of this repository. Build one with, for example:
#
#   nix-build -A ast-sim
{
  pkgs ? import ./nix/nixpkgs.nix,
}:

rec {
  bigraph-tools = import ./nix/bigraph-tools.nix {
    inherit pkgs;
    src = ./bigraph-tools;
  };
  ast-sim = import ./nix/ast-sim.nix {
    inherit pkgs bigraph-tools;
    src = ./ast-sim;
  };
}
