# Unit test: mkGemset against a small, real Bundler-generated
# Gemfile.lock (example/Gemfile.lock) must produce exactly the attrset
# shape nixpkgs' bundled-common/buildRubyGem expects. The sha256 is
# independently verified in this repo's README: builtins.fetchurl with
# this exact hash actually succeeded against the real
# rubygems.org/gems/json-2.21.2.gem.
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

  # Groups regression: fixtures/groups has `json` (no group -> default)
  # and `rspec` inside `group :test do`. Checks both that mkGemset
  # resolves the right groups AND that narrowing `groups` actually
  # excludes rspec from a real build (transitive deps like rspec-core
  # stay, since they're not directly named in the Gemfile).
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

  # PATH-source regression: fixtures/path-source declares `gem 'mygem',
  # path: 'mygem'`. Checks both that mkGemset resolves the path relative
  # to the lockfile's own directory (matching a real bundix-generated
  # gemset.nix's `path = ./.;`) and that the built environment actually
  # contains the gem's real file.
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
