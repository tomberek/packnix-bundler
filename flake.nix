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
        }
      );

      checks = perSystem (
        { pkgs, ... }:
        {
          gemset-unit = import ./tests/gemset-unit.nix { inherit pkgs mkGemset; };
        }
      );
    };
}
