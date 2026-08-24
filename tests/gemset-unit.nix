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
{
  pkgs,
  mkGemset,
  buildBundlerApp,
}:
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

  # Groups regression test: fixtures/groups/{Gemfile,Gemfile.lock} has
  # `json` (no group -> "default") and `rspec` inside `group :test do`.
  # Verifies BOTH that mkGemset resolves the right `groups` per gem (not
  # just that it parses without erroring) AND that this actually changes
  # what `pkgs.bundlerEnv` installs -- narrowing `groups` to exclude
  # "test" must genuinely leave `rspec` itself out of the built env
  # (transitive deps like rspec-core stay, since they're not directly
  # named in the Gemfile and so default to "default" -- expected
  # `bundlerEnv` behavior, not a bug: see `groupMatches`/`filterGemset`
  # in nixpkgs' bundled-common/functions.nix).
  groupsGemset = mkGemset {
    lockFile = ./fixtures/groups/Gemfile.lock;
    gemfile = ./fixtures/groups/Gemfile;
  };
  groupsGemsetExpected = {
    groups = groupsGemset.json.groups == [ "default" ] && groupsGemset.rspec.groups == [ "test" ];
  };

  defaultBuild = buildBundlerApp {
    inherit pkgs;
    pname = "json";
    gemdir = ./fixtures/groups;
    groups = [ "default" ];
  };
  withTestBuild = buildBundlerApp {
    inherit pkgs;
    pname = "json";
    gemdir = ./fixtures/groups;
    groups = [
      "default"
      "test"
    ];
  };

  gemNames = drv: builtins.attrNames (builtins.readDir "${drv}/lib/ruby/gems");
  installedGemDirNames =
    drv:
    let
      rubyGemsDir = "${drv}/lib/ruby/gems/" + builtins.head (gemNames drv) + "/gems";
    in
    builtins.attrNames (builtins.readDir rubyGemsDir);

  defaultGems = installedGemDirNames defaultBuild;
  withTestGems = installedGemDirNames withTestBuild;
  defaultExcludesRspec = !(builtins.any (n: builtins.match "rspec-[0-9].*" n != null) defaultGems);
  withTestIncludesRspec = builtins.any (n: builtins.match "rspec-[0-9].*" n != null) withTestGems;

  groupsFilteringWorks = groupsGemsetExpected.groups && defaultExcludesRspec && withTestIncludesRspec;

  # PATH-source regression test: fixtures/path-source/{Gemfile,
  # Gemfile.lock,mygem/} declares `gem 'mygem', path: 'mygem'`. Before
  # the fix, mkGemset stored a PATH source's `remote:` (here "mygem")
  # verbatim as a bare string, which nixpkgs' `pathDerivation` (`outPath
  # = "${path}"`) took completely literally -- meaningless outside the
  # original checkout, so the gem silently failed to install with no
  # error at all (confirmed directly against examples/anystyle/, a real,
  # much bigger PATH-sourced project). Verifies BOTH that `mkGemset`
  # resolves the path relative to the lockfile's own directory (matching
  # a real `bundix`-generated gemset.nix's `path = ./.;` idiom) AND that
  # the built environment actually contains the gem's real file, not
  # just that the gemset attrset's `source.path` looks plausible.
  pathSourceGemset = mkGemset { lockFile = ./fixtures/path-source/Gemfile.lock; };
  pathSourceExpected = {
    resolvesToRealDirectory = builtins.pathExists (
      pathSourceGemset.mygem.source.path + "/lib/mygem.rb"
    );
  };
  pathSourceBuild = buildBundlerApp {
    inherit pkgs;
    pname = "mygem";
    gemdir = ./fixtures/path-source;
  };
  pathSourceBuildContainsRealFile = builtins.pathExists (pathSourceBuild + "/lib/mygem.rb");
in
pkgs.runCommand "packnix-bundler-gemset-unit-test"
  {
    passthru = {
      inherit
        gemset
        expected
        groupsGemset
        defaultBuild
        withTestBuild
        pathSourceGemset
        pathSourceBuild
        ;
    };
  }
  ''
    ${
      if !passed then
        throw "mkGemset output for example/Gemfile.lock did not match the expected gemset -- got: ${builtins.toJSON gemset}"
      else if !groupsFilteringWorks then
        throw "Gemfile groups filtering regression: groupsGemset=${builtins.toJSON groupsGemset}, defaultGems=${builtins.toJSON defaultGems}, withTestGems=${builtins.toJSON withTestGems}"
      else if !pathSourceExpected.resolvesToRealDirectory then
        throw "PATH source regression: mkGemset's resolved path does not exist or is missing lib/mygem.rb -- got: ${builtins.toJSON pathSourceGemset}"
      else if !pathSourceBuildContainsRealFile then
        throw "PATH source regression: built environment is missing mygem's real lib/mygem.rb"
      else
        "echo PASS > $out"
    }
  ''
