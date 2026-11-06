# Development shell for bigraph modelling using BigraphER and OCaml.
#
#   nix-shell        # from project/sidc
#   make test        # inside the shell
#
# Provides OCaml, dune, the bigraph library and bigrapher CLI (built from
# the bigraph-tools submodule), alcotest, editor tooling, graphviz, the PRISM
# model checker and the mCRL2 toolset.
{
  pkgs ? import (builtins.fetchTarball {
    # nixpkgs 25.05: OCaml 5.3.0, dune 3.18
    url = "https://github.com/NixOS/nixpkgs/archive/25.05.tar.gz";
    sha256 = "1915r28xc4znrh2vf4rrjnxldw2imysz819gzhk9qlrkqanmfsxd";
  }) { },
}:

let
  ocamlPackages = pkgs.ocamlPackages;
  bigraph-tools = import ./nix/bigraph-tools.nix {
    inherit pkgs;
    src = ./bigraph-tools;
  };
  # The model checkers come from nixpkgs 26.05. In 25.05, mCRL2 is marked
  # broken on macOS, and PRISM 4.8.1 is not in the binary cache for Linux
  # and fails to build there (its bundled lp_solve does not compile with
  # 25.05's GCC). Take only these packages from 26.05, so the OCaml
  # toolchain above (and the bigraph-tools build) keeps its versions.
  pkgs-26_05 = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/26.05.tar.gz";
    sha256 = "0am8xx09fx5yf2p0wb001v0jx1g5hrfb76h4r37xph378jgk7pcr";
  }) { };
  mcrl2 = pkgs-26_05.mcrl2;
  # On macOS the package only puts the IDE on PATH; the command-line tools
  # (mcrl22lps, ltsconvert, lts2pbes, pbessolve, ...) stay inside the app.
  mcrl2Tools =
    if pkgs.stdenv.isDarwin
    then "${mcrl2}/Applications/mCRL2.app/Contents/bin"
    else "${mcrl2}/bin";
in
pkgs.mkShell {
  # Tools.
  nativeBuildInputs = [
    ocamlPackages.ocaml
    ocamlPackages.dune_3
    ocamlPackages.findlib # its setup hook puts buildInputs on OCAMLPATH
    ocamlPackages.ocaml-lsp
    pkgs.ocamlformat
    pkgs.graphviz # SVG output from bigrapher
    pkgs.gnumake
    pkgs.jq # scripts/mcrl2-check.sh converts bigrapher's JSON with it
    # The PRISM model checker (`prism`, `xprism`). Note that nixpkgs'
    # `prism` package is an unrelated program.
    pkgs-26_05.prism-model-checker
    # The mCRL2 toolset: modal mu-calculus checks over labelled transition
    # systems, so properties can name the rules (actions) that fired.
    mcrl2
  ];

  shellHook = ''
    export PATH="${mcrl2Tools}:$PATH"
  '';

  # Libraries (and the bigrapher binary).
  buildInputs = [
    bigraph-tools
    ocamlPackages.alcotest
  ];
}
