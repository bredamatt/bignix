# ast-sim: adaptive stress testing of action BRS models (.big files).
#
# It reads .big files with bigrapher's own parser. bigrapher builds that
# parser only into its executable, so ast-sim compiles the parser sources
# again, as a library: BIGRAPHER_SRC tells its dune build where they are.
#
# The tests run as part of the build.
{ pkgs, bigraph-tools, src }:

let
  ocamlPackages = pkgs.ocamlPackages;
in
pkgs.stdenv.mkDerivation {
  pname = "ast-sim";
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

  buildInputs = [ bigraph-tools ];
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
    dune install --profile=release --prefix=$out ast-sim
    runHook postInstall
  '';
}
