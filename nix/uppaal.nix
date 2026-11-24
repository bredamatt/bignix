# UPPAAL 5.0.0: `verifyta`, the command-line verifier, with the statistical
# model checker (UPPAAL-SMC).
#
# UPPAAL is not free software. It is free of charge for academic use, and
# every user needs a licence key of their own from https://uppaal.org.
# Activate it once, inside the nix-shell:
#
#   verifyta --key <your-key>
#
# The lease is kept under $HOME, not in the nix store.
#
# nixpkgs packages only the Linux build, so macOS takes the vendor's app
# bundle. Its binaries are x86_64; on Apple silicon they need Rosetta
# (`softwareupdate --install-rosetta`).
{ pkgs, pkgs-26_05-unfree }:

if pkgs.stdenv.isDarwin then
  pkgs.stdenv.mkDerivation {
    pname = "uppaal";
    version = "5.0.0";

    src = pkgs.fetchurl {
      url = "https://download.uppaal.org/uppaal-5.0/uppaal-5.0.0/UPPAAL-5.0.0-app.zip";
      sha256 = "66dfdbd4b941fbc16a541c4c3962f9768a80a841b4bbe3815d0c31197c0c33ff";
    };

    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";

    # The binaries are signed and find their libraries beside themselves:
    # leave them exactly as shipped.
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share $out/bin
      cp -R UPPAAL-5.0.0.app/Contents/Resources/uppaal $out/share/uppaal
      ln -s $out/share/uppaal/bin/verifyta $out/bin/verifyta
      runHook postInstall
    '';

    meta.description = "UPPAAL model checker (verifyta). Proprietary; needs a licence key";
  }
else
  # Not tried on Linux from this repository.
  pkgs-26_05-unfree.uppaal
