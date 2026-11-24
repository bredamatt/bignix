# Development shell for bigraph modelling using BigraphER and OCaml.
#
#   nix-shell        # from project/sidc
#   make test        # inside the shell
#
# Provides OCaml, dune, the bigraph library and bigrapher CLI (built from
# the bigraph-tools submodule), the ast-sim stress tester, the big2uppaal
# generator, the big2hw circuit generator with Hardcaml, yosys and
# SymbiYosys, alcotest, editor tooling, graphviz, the PRISM model checker,
# the mCRL2 toolset and UPPAAL.
{
  pkgs ? import ./nix/nixpkgs.nix,
}:

let
  ocamlPackages = pkgs.ocamlPackages;
  inherit (import ./default.nix { inherit pkgs; }) bigraph-tools ast-sim big2uppaal hardcaml big2hw;
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
  # UPPAAL (`verifyta`): statistical model checking of the models that
  # big2uppaal writes. It is proprietary and needs a licence key, and the
  # vendor ships x86_64 binaries only, so it is left out on aarch64-linux:
  # see nix/uppaal.nix.
  uppaal = pkgs.lib.optional (pkgs.stdenv.isDarwin || pkgs.stdenv.isx86_64)
    (import ./nix/uppaal.nix { inherit pkgs; });
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
    ocamlPackages.menhir # ast-sim builds bigrapher's .big parser
    ocamlPackages.findlib # its setup hook puts buildInputs on OCAMLPATH
    ocamlPackages.ocaml-lsp
    pkgs.ocamlformat
    pkgs.graphviz # SVG output from bigrapher
    pkgs.gnumake
    pkgs.jq # scripts/mcrl2-check.sh converts bigrapher's JSON with it
    pkgs.yosys # synthesises the Verilog that big2hw writes
    pkgs.sby # SymbiYosys: proves properties of that Verilog
    pkgs.yices # the SMT solver SymbiYosys is run with
    # The PRISM model checker (`prism`, `xprism`). Note that nixpkgs'
    # `prism` package is an unrelated program.
    pkgs-26_05.prism-model-checker
    # The mCRL2 toolset: modal mu-calculus checks over labelled transition
    # systems, so properties can name the rules (actions) that fired.
    mcrl2
  ] ++ uppaal;

  shellHook = ''
    export PATH="${mcrl2Tools}:$PATH"
    # Where ast-sim's dune build finds bigrapher's parser sources.
    export BIGRAPHER_SRC="${bigraph-tools.src}/bigrapher"
  '';

  # Libraries (and the bigrapher and ast-sim binaries).
  buildInputs = [
    bigraph-tools
    ast-sim
    big2uppaal
    big2hw
    hardcaml # so that dune builds big2hw inside the shell
    ocamlPackages.alcotest
  ];
}
