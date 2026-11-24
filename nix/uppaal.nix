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
# The vendor ships x86_64 binaries only, for Linux and macOS. On Apple
# silicon they need Rosetta (`softwareupdate --install-rosetta`). There is
# no build for aarch64-linux, so shell.nix leaves UPPAAL out there.
#
# nixpkgs (26.05, unfree) packages UPPAAL as well, but marks it broken
# outside x86_64-linux and puts only the Java GUI on PATH, not verifyta.
# Both platforms therefore take the vendor's archives here.
{ pkgs }:

let
  version = "5.0.0";
  base = "https://download.uppaal.org/uppaal-5.0/uppaal-${version}";
  description = "UPPAAL model checker (verifyta). Proprietary; needs a licence key";
in
if pkgs.stdenv.isDarwin then
  pkgs.stdenv.mkDerivation {
    pname = "uppaal";
    inherit version;

    src = pkgs.fetchurl {
      url = "${base}/UPPAAL-${version}-app.zip";
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
      cp -R UPPAAL-${version}.app/Contents/Resources/uppaal $out/share/uppaal
      ln -s $out/share/uppaal/bin/verifyta $out/bin/verifyta
      runHook postInstall
    '';

    meta = { inherit description; };
  }
else if pkgs.stdenv.isLinux && pkgs.stdenv.isx86_64 then
  pkgs.stdenv.mkDerivation {
    pname = "uppaal";
    inherit version;

    src = pkgs.fetchurl {
      url = "${base}/uppaal-${version}-linux64.zip";
      hash = "sha256-htZtjNJcAPb0UVZhfzp1ZvH0/nrtdN0XG/ye8nosYc4=";
    };

    # The binaries expect the loader at /lib64 and glibc and libstdc++ on
    # the system; autoPatchelfHook points them at nixpkgs' instead. The
    # other libraries (libssl, libcrypto, libprlearn, libstrategy) ship
    # beside them in bin/.
    nativeBuildInputs = [ pkgs.unzip pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share $out/bin
      cp -R . $out/share/uppaal
      # The vendor's fallback libstdc++, for hosts without one: nixpkgs' is used.
      rm -rf $out/share/uppaal/bin/lib
      ln -s $out/share/uppaal/bin/verifyta $out/bin/verifyta
      addAutoPatchelfSearchPath $out/share/uppaal/bin
      runHook postInstall
    '';

    meta = { inherit description; };
  }
else
  throw "uppaal: UPPAAL ships x86_64 binaries only; there is no build for ${pkgs.stdenv.hostPlatform.system}"
