# big2hw: reads a bigraph of two FPGAs and their state machines (a .big
# file) and builds the circuits with Hardcaml, as Verilog.
#
# Like ast-sim, it reads .big files with bigrapher's own parser, compiled
# again as a library: BIGRAPHER_SRC tells its dune build where the sources
# are.
#
# The tests run as part of the build.
{ pkgs, bigraph-tools, hardcaml, src }:

let
  ocamlPackages = pkgs.ocamlPackages;
in
pkgs.stdenv.mkDerivation {
  pname = "big2hw";
  version = "0.1.0";

  src = pkgs.lib.cleanSourceWith {
    src = pkgs.lib.cleanSource src;
    filter = path: _type: baseNameOf path != "_build";
  };

  nativeBuildInputs = [
    ocamlPackages.ocaml
    ocamlPackages.dune_3
    ocamlPackages.findlib # its setup hook puts buildInputs on OCAMLPATH
    ocamlPackages.menhir
  ];

  buildInputs = [ bigraph-tools hardcaml ];
  checkInputs = [ ocamlPackages.alcotest ];

  env.BIGRAPHER_SRC = "${bigraph-tools.src}/bigrapher";

  buildPhase = ''
    runHook preBuild
    dune build --profile=release @install
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    dune runtest --profile=release
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    dune install --profile=release --prefix=$out big2hw
    runHook postInstall
  '';
}
