# Unit test: mkGemset against a small, real Bundler-generated
# Gemfile.lock (example/Gemfile.lock, produced by an actual `bundle lock
# --add-checksums` run, not hand-written) must produce exactly the
# attrset shape nixpkgs' `bundled-common`/`buildRubyGem` expects.
#
# The sha256 is independently verified in this repo's README/commit
# history: `builtins.fetchurl` with this exact hash actually succeeded
# against the real https://rubygems.org/gems/json-2.21.2.gem, proving
# the CHECKSUMS-hex-to-nix32 conversion is correct, not just internally
# self-consistent. `remotes` has no trailing slash (unlike a
# Gemfile.lock's own `remote:` line, which always has one) -- verified
# directly that the double-slash URL a trailing-slash remote would
# produce genuinely 404s against rubygems.org's real server, only
# masked in small examples by builds substituting from a binary cache
# instead of hitting the URL directly (see lib/mk-gemset.nix's
# `stripTrailingSlash` for the fix, surfaced by a much larger example
# with many not-already-cached gems).
{ pkgs, mkGemset }:
let
  gemset = mkGemset { lockFile = ../example/Gemfile.lock; };

  expected = {
    json = {
      dependencies = [ ];
      groups = [ "default" ];
      platforms = [ ];
      source = {
        remotes = [ "https://rubygems.org" ];
        sha256 = "0shwgjqbj856mb6m9kgkpy08nhym2gdvc2yaprlimfmky9y3n78z";
        type = "gem";
      };
      version = "2.21.2";
    };
  };

  passed = gemset == expected;
in
pkgs.runCommand "packnix-bundler-gemset-unit-test"
  {
    passthru = {
      inherit gemset expected;
    };
  }
  ''
    ${
      if passed then
        "echo PASS > $out"
      else
        throw "mkGemset output for example/Gemfile.lock did not match the expected gemset -- got: ${builtins.toJSON gemset}"
    }
  ''
