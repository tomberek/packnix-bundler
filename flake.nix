{
  description = "Pure-Nix Ruby gem/bundler builder using packnix's Gemfile.lock parser -- no bundix, no network access needed for RubyGems-sourced dependencies.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    packnix.url = "github:tomberek/packnix";
  };

  outputs =
    {
      self,
      nixpkgs,
      packnix,
    }:
    let
      mkGemset = import ./lib/mk-gemset.nix { inherit packnix; };
      buildBundlerApp = import ./lib/build-bundler-app.nix { inherit mkGemset; };
      forAllSystems =
        f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] f;
    in
    {
      lib = { inherit mkGemset buildBundlerApp; };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          example = buildBundlerApp {
            inherit pkgs;
            name = "packnix-bundler-example";
            gemdir = ./example;
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          gemset-unit = import ./tests/gemset-unit.nix { inherit pkgs mkGemset; };
        }
      );
    };
}
