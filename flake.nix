{
  description = "Pure-Nix Ruby gem/bundler builder using packnix's Gemfile.lock parser -- no bundix, no network access needed for RubyGems-sourced dependencies.";

  # NOTE: pinned to the `worktree-agent-a6447a1ba85f3c2fb` branch, not
  # `master`, because packnix#10 (which adds the flake.nix this input
  # needs) is still an open PR at the time this was written. Switch this
  # to `github:tomberek/packnix` (tracking master) once that PR merges --
  # everything this repo depends on (`lib.packrat`, `lib.grammars.gemfileLock`)
  # is already on master via packnix#9; only the flake.nix wrapper itself
  # is pending.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    packnix.url = "github:tomberek/packnix/worktree-agent-a6447a1ba85f3c2fb";
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
