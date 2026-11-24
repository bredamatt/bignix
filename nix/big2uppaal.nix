# big2uppaal: reads a bigraph of a compute module and its host site (a .big
# file) and writes the UPPAAL-SMC model of its side channels.
#
# Like ast-sim, it reads .big files with bigrapher's own parser, compiled
# again as a library: BIGRAPHER_SRC tells its dune build where the sources
# are.
#
# The tests run as part of the build.
{ pkgs, bigraph-tools, src }:

let
  ocamlPackages = pkgs.ocamlPackages;
in
pkgs.stdenv.mkDerivation {
  pname = "big2uppaal";
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
    dune install --profile=release --prefix=$out big2uppaal
    runHook postInstall
  '';
}
