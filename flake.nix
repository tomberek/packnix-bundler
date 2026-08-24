{
  description = "Pure-Nix Ruby gem/bundler builder using packnix's Gemfile.lock parser -- no bundix, no network access needed for RubyGems-sourced dependencies.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    packnix.url = "github:tomberek/packnix";
  };

  outputs =
    { nixpkgs, packnix, ... }:
    let
      mkGemset = import ./lib/mk-gemset.nix { inherit packnix; };
      buildBundlerApp = import ./lib/build-bundler-app.nix { inherit mkGemset; };

      # One `pkgs` per system nixpkgs itself supports, without this
      # flake needing to declare its own systems list.
      perSystem =
        f:
        builtins.mapAttrs (
          system: pkgs:
          f {
            inherit system pkgs;
          }
        ) nixpkgs.legacyPackages;
    in
    {
      lib = { inherit mkGemset buildBundlerApp; };

      packages = perSystem (
        { pkgs, ... }:
        {
          # Smallest possible demonstration of the CHECKSUMS pure-fetch
          # path: a single-gem project.
          example = buildBundlerApp {
            inherit pkgs;
            name = "packnix-bundler-example";
            gemdir = ./example;
          };

          # pkgs/tools/security/bundler-audit, built the packnix-bundler
          # way -- see examples/bundler-audit/README.md for the
          # comparison against nixpkgs' committed Gemfile.lock/gemset.nix.
          bundler-audit = buildBundlerApp {
            inherit pkgs;
            pname = "bundler-audit";
            gemdir = ./examples/bundler-audit;
          };

          # A git-sourced gem (anystyle, pinned to a real commit) -- no
          # gitHashes needed, since fetchGit with a full commit SHA is
          # itself content-addressed and evaluates purely.
          git-source = buildBundlerApp {
            inherit pkgs;
            pname = "anystyle";
            gemdir = ./examples/git-source;
          };

          # Chef development kit (pkgs/development/tools/chefdk), 289
          # gems, native extensions -- the scale test. Re-locked lockfile
          # pulls in both fauxhai-ng and fauxhai-chef, which both ship a
          # bin/fauxhai binstub (a real upstream collision, worked around
          # with ignoreCollisions like any bundlerEnv package would).
          chefdk = buildBundlerApp {
            inherit pkgs;
            name = "chefdk-example";
            gemdir = ./examples/chefdk;
            buildInputs = [
              pkgs.perl
              pkgs.autoconf
            ];
            ignoreCollisions = true;
          };

          # pkgs/tools/admin/fastlane. Its Gemfile pins no version, so
          # re-locking pulls the current release -- a fresh, real
          # lockfile that builds cleanly with no native-toolchain
          # overrides, unlike chefdk/bundler-audit's older ones.
          fastlane = buildBundlerApp {
            inherit pkgs;
            pname = "fastlane";
            gemdir = ./examples/fastlane;
          };

          # The real, current anystyle project (github:inukshuk/anystyle
          # v1.5.0): its Gemfile does `gemspec`, making its own root gem
          # a PATH source, alongside 5 real `group` blocks.
          path-source = buildBundlerApp {
            inherit pkgs;
            pname = "anystyle";
            gemdir = ./examples/anystyle;
          };
        }
      );

      checks = perSystem (
        { pkgs, ... }:
        {
          gemset-unit = import ./tests/gemset-unit.nix { inherit pkgs mkGemset buildBundlerApp; };
        }
      );
    };
}
