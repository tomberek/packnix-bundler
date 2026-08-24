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
  # Ruby's own gem-platform naming convention (confirmed against real
  # Gemfile.lock spec entries, e.g. "ffi (1.17.4-x86_64-linux-gnu)",
  # "ffi (1.17.1-arm64-darwin)") -- CPU name + "-linux-gnu"/"-linux-musl"
  # on Linux, CPU name + "-darwin" (no libc suffix at all) on macOS. Used
  # by mkGemset to pick the right platform-qualified spec variant when a
  # gem has no bare (platform-independent) version at all -- see that
  # file's `specRank` for why this matters (picking the wrong platform's
  # variant produces a gemset entry whose version string doesn't match
  # what's actually installed, and Bundler's runtime fails to find it).
  hostPlatform = pkgs.stdenv.hostPlatform;
  rubyPlatform =
    if hostPlatform.isDarwin then
      "${hostPlatform.parsed.cpu.name}-darwin"
    else if hostPlatform.isLinux then
      "${hostPlatform.parsed.cpu.name}-linux-${if hostPlatform.isMusl then "musl" else "gnu"}"
    else
      null;

  gemset = mkGemset {
    lockFile = lockfile;
    platform = rubyPlatform;
  };
  bundlerEnvArgs = (builtins.removeAttrs args [ "pkgs" ]) // {
    inherit gemfile lockfile gemset;
  };
in
pkgs.bundlerEnv bundlerEnvArgs
