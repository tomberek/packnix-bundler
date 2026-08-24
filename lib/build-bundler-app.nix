# A pure-Nix `bundlerEnv` replacement: give it `pkgs`, a `gemdir` (or
# explicit `gemfile`/`lockfile`), and it produces exactly what
# `pkgs.bundlerEnv` would, EXCEPT the `gemset` comes from `mkGemset`
# (packnix's Gemfile.lock parser + `builtins.convertHash`) instead of a
# `gemset.nix` file `bundix` generated offline.
#
# This is intentionally a thin wrapper, not a gem-installation
# reimplementation: nixpkgs' `bundlerEnv`/`buildRubyGem`
# (`pkgs/development/ruby-modules/`) already correctly handles native
# extension compilation, binstub generation, multi-gem environments, etc.
# -- the only piece this repo replaces is where `gemset` comes from.
{ mkGemset }:

{
  pkgs,
  # Directory containing Gemfile and Gemfile.lock -- if given, both are
  # resolved from it (mirrors pkgs.bundlerEnv's own `gemdir` convenience
  # argument). Pass `gemfile`/`lockfile` directly instead if they live
  # elsewhere or under different names.
  gemdir ? null,
  gemfile ? if gemdir == null then null else gemdir + "/Gemfile",
  lockfile ? if gemdir == null then null else gemdir + "/Gemfile.lock",
  ...
}@args:
let
  gemset = mkGemset { lockFile = lockfile; };
  bundlerEnvArgs = (builtins.removeAttrs args [ "pkgs" ]) // {
    inherit gemfile lockfile gemset;
  };
in
pkgs.bundlerEnv bundlerEnvArgs
