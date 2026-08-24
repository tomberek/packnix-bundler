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

      # `nixpkgs.legacyPackages` is already an attrset of one `pkgs` per
      # supported system -- `builtins.mapAttrs` over it directly gives
      # every per-system output nixpkgs' own top-level flake.nix produces
      # (see its `forAllSystems`/`genAttrs systems` there), without this
      # flake needing to declare its own systems list at all. Contrast
      # with the previous version of this file, which hardcoded
      # `[ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]`
      # via `nixpkgs.lib.genAttrs` -- functionally the same result, but
      # that list has to be kept in sync by hand as new systems are
      # added/dropped, where mapAttrs-over-legacyPackages tracks whatever
      # nixpkgs itself already supports.
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
          # A minimal single-gem project (this repo's own example/) --
          # smallest possible demonstration of the CHECKSUMS pure-fetch
          # path.
          example = buildBundlerApp {
            inherit pkgs;
            name = "packnix-bundler-example";
            gemdir = ./example;
          };

          # A real nixpkgs package (pkgs/tools/security/bundler-audit),
          # built the packnix-bundler way instead of bundix's way -- see
          # examples/bundler-audit/README.md for the full comparison
          # against nixpkgs' actual checked-in Gemfile.lock/gemset.nix.
          bundler-audit = buildBundlerApp {
            inherit pkgs;
            pname = "bundler-audit";
            gemdir = ./examples/bundler-audit;
          };

          # A git-sourced gem (anystyle, pinned to a real commit) -- no
          # gitHashes needed. builtins.fetchGit { url; rev; } with a full
          # commit SHA is itself content-addressed and evaluates purely
          # (confirmed: no --impure anywhere in this build), so
          # mkGemset pre-fetches it directly and hands the result to
          # buildRubyGem as `src`, bypassing only the fetch step of
          # nixpkgs' usual fetchgit-based path.
          git-source = buildBundlerApp {
            inherit pkgs;
            pname = "anystyle";
            gemdir = ./examples/git-source;
          };

          # A big, real nixpkgs package: Chef development kit
          # (pkgs/development/tools/chefdk), 289 gems, native extensions
          # (ffi-yajl etc.) -- the scale test. Its lockfile regenerated
          # via `bundle lock --add-checksums` resolves a few gems
          # differently than the ~2020-era one committed to nixpkgs
          # (rubygems.org's index has moved on since); notably it pulls
          # in BOTH `fauxhai-ng` and `fauxhai-chef`, which both ship a
          # `bin/fauxhai` binstub -- a real upstream collision, not a
          # packnix-bundler bug, worked around the same way any
          # `bundlerEnv` package would (`ignoreCollisions`).
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

          # fastlane (pkgs/tools/admin/fastlane) -- a real, widely-used
          # nixpkgs package (mobile CI/CD tooling). Its Gemfile pins no
          # fastlane version (`gem 'fastlane'`), so re-locking pulls the
          # current release -- a deliberately different vintage than
          # chefdk/bundler-audit above: those two exercise mkGemset
          # against OLD, previously-committed nixpkgs lockfiles (useful
          # for the bug comparisons in the README), whereas this one
          # shows a FRESH real-world lockfile building cleanly with no
          # native-toolchain overrides needed at all.
          fastlane = buildBundlerApp {
            inherit pkgs;
            pname = "fastlane";
            gemdir = ./examples/fastlane;
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
