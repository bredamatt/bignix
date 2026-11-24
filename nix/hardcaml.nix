# Hardcaml: circuits written as OCaml programs, with a simulator and a
# Verilog printer. nixpkgs 25.05 does not package it, so it is built here
# from the release that matches the Jane Street 0.17 libraries nixpkgs has.
{ pkgs }:

let
  ocamlPackages = pkgs.ocamlPackages;
in
ocamlPackages.buildDunePackage rec {
  pname = "hardcaml";
  version = "0.17.0";

  src = pkgs.fetchFromGitHub {
    owner = "janestreet";
    repo = "hardcaml";
    rev = "v${version}";
    hash = "sha256-lRzqXuUYrk3VjQhFDTN0Q/aPolf0gKr4gK0i1ZOKKww=";
  };

  propagatedBuildInputs = [
    ocamlPackages.base
    ocamlPackages.bin_prot
    ocamlPackages.core_kernel
    ocamlPackages.ppx_jane
    ocamlPackages.ppx_sexp_conv
    ocamlPackages.ppxlib
    ocamlPackages.stdio
    ocamlPackages.zarith
  ];
}
