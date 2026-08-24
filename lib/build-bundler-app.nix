# Pure-Nix bundlerEnv replacement: give it pkgs and a gemdir (or
# explicit gemfile/lockfile), and it produces what pkgs.bundlerEnv
# would, except gemset comes from mkGemset instead of a bundix-generated
# gemset.nix. A thin wrapper -- native extension compilation, binstub
# generation, etc. all stay nixpkgs' own bundlerEnv/buildRubyGem.
{ mkGemset }:

{
  pkgs,
  # Directory containing Gemfile and Gemfile.lock; pass gemfile/lockfile
  # directly instead if they live elsewhere or under different names.
  gemdir ? null,
  gemfile ? if gemdir == null then null else gemdir + "/Gemfile",
  lockfile ? if gemdir == null then null else gemdir + "/Gemfile.lock",
  ...
}@args:
let
  # Ruby's own gem-platform naming convention, e.g.
  # "ffi (1.17.4-x86_64-linux-gnu)", "ffi (1.17.1-arm64-darwin)".
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
    inherit gemfile;
    platform = rubyPlatform;
  };
  bundlerEnvArgs = (builtins.removeAttrs args [ "pkgs" ]) // {
    inherit gemfile lockfile gemset;
  };
in
pkgs.bundlerEnv bundlerEnvArgs
