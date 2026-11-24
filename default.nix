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
  big2uppaal = import ./nix/big2uppaal.nix {
    inherit pkgs bigraph-tools;
    src = ./big2uppaal;
  };
  hardcaml = import ./nix/hardcaml.nix { inherit pkgs; };
  big2hw = import ./nix/big2hw.nix {
    inherit pkgs bigraph-tools hardcaml;
    src = ./big2hw;
  };
}
