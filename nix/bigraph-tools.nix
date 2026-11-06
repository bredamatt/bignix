# bigraph-tools: the bigraph OCaml library and the bigrapher CLI, using the
# derivation that ships with the checkout (bigraph-tools/default.nix,
# attribute `bigrapher`), built with our nixpkgs so the OCaml versions match.
#
# Three overrides make it usable as an OCaml library:
#   src        skip _build output left by local (opam) builds;
#   install    put the libraries under lib/ocaml/<version>/site-lib, where
#              findlib (and therefore dune) looks for them;
#   macOS      dune compiles the solvers' C++ bindings with `cc -x c++`, and
#              the Nix clang wrapper then omits the libc++ headers.
{ pkgs, src }:

let
  upstream = import (src + "/default.nix") { inherit pkgs; };
  ocamlPackages = pkgs.ocamlPackages;
  siteLib = "lib/ocaml/${ocamlPackages.ocaml.version}/site-lib";
in
upstream.bigrapher.overrideAttrs (old: {
  src = pkgs.lib.cleanSourceWith {
    src = pkgs.lib.cleanSource src;
    filter = path: _type: baseNameOf path != "_build";
  };

  env = (old.env or { }) // {
    NIX_CFLAGS_COMPILE = pkgs.lib.optionalString pkgs.stdenv.isDarwin
      "-isystem ${pkgs.lib.getDev pkgs.stdenv.cc.libcxx}/include/c++/v1";
  };

  # Libraries that code linking against bigraph also needs.
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
    ocamlPackages.zarith
    ocamlPackages.yojson
    ocamlPackages.ppx_yojson_conv_lib
  ];

  installPhase = ''
    runHook preInstall
    dune install --profile=release --prefix=$out --libdir=$out/${siteLib}
    runHook postInstall
  '';
})
