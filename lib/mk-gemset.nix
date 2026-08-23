# Builds a nixpkgs-compatible `gemset` attrset directly from a
# `Gemfile.lock`, using packnix's `grammar/gemfile-lock.nix` parser --
# the pure-Nix replacement for what `bundix` computes today (see this
# repo's README for the full story).
#
# `gemset` here means exactly what `pkgs.bundlerEnv { gemset = ...; }`
# (nixpkgs' `pkgs/development/ruby-modules/bundled-common`) expects: one
# attrset entry per gem name, each with `dependencies`/`groups`/
# `platforms`/`source`/`version` -- confirmed against
# `bundled-common/functions.nix`'s `filterGemset`/`composeGemAttrs` and
# `gem/default.nix`'s `buildRubyGem` (which is what actually consumes
# `source.{sha256,url,rev,remotes,path}` per source type).
#
# What's genuinely pure (no network access at Nix-eval time) vs. not:
#   - `type = "gem"` (RubyGems-sourced) sources: FULLY pure whenever the
#     lockfile has a CHECKSUMS section (Bundler >=2.7) -- the hex sha256
#     there converts via `builtins.convertHash` to exactly the hash
#     `bundlerEnv`'s `fetchurl` needs, verified against a real nixpkgs
#     package's paired Gemfile.lock/gemset.nix (see packnix's README).
#   - `type = "path"` sources: always pure, no hash needed at all
#     (nixpkgs' `pathDerivation` just treats the path as already-resolved).
#   - `type = "git"` sources: NOT pure. A Gemfile.lock's GIT block only
#     ever records `remote`/`revision` (confirmed via packnix's own
#     136-file corpus survey) -- never a content hash -- and nixpkgs'
#     `buildRubyGem` hardcodes a `fetchgit` call requiring `sha256` with
#     no hash-free fallback (confirmed by reading
#     `pkgs/development/ruby-modules/gem/default.nix`). So git-sourced
#     gems need a hash supplied via the `gitHashes` argument below --
#     still no `bundix` invoked anywhere, just one manual hash per git
#     dependency (the normal nixpkgs experience for any `fetchgit`-based
#     derivation whose upstream lockfile doesn't embed a content hash).
{ packnix }:

{
  # Path to a Gemfile.lock, OR its already-read contents as a string.
  lockFile,
  # { "<gem name>" = "sha256-..."; ... } -- required for any GIT-sourced
  # gem in the lockfile; a missing entry throws a clear error naming the
  # gem, rather than failing deep inside fetchgit with a confusing message.
  gitHashes ? { },
}:
let
  inherit (packnix.lib) packrat;
  gemfileLockGrammar = packnix.lib.grammars.gemfileLock;

  contents =
    if builtins.isPath lockFile || builtins.isString lockFile then
      (if builtins.pathExists lockFile then builtins.readFile lockFile else lockFile)
    else
      throw "mkGemset: lockFile must be a path or a string";

  doc =
    (packrat.run {
      grammar = gemfileLockGrammar.grammar;
      handlers = gemfileLockGrammar.handlers;
    } 0 contents).DOCUMENT;

  # A "bare" version has no platform suffix (e.g. "1.17.2", or
  # "1.16.0.rc1" -- Ruby pre-release versions use dots, never hyphens;
  # confirmed against the full corpus: every hyphen inside a spec's
  # version text is a platform qualifier, never part of the version
  # itself). Matches nixpkgs' `bundix` behavior exactly: when a gem name
  # has multiple spec entries (one bare, others platform-qualified for
  # prebuilt native extensions), bundix keeps only the bare one --
  # confirmed by cross-referencing two real nixpkgs packages' paired
  # Gemfile.lock/gemset.nix (discourse, gitlab), both of which store just
  # the bare-version hash for gems like `ffi` that ship platform-specific
  # variants.
  isBareVersion = v: builtins.match "[0-9]+([.][0-9A-Za-z]+)*" v != null;

  # Every spec across every GEM/GIT/PATH block, flattened, each tagged
  # with its source block's type/remote/revision/ref -- a gem name can in
  # principle appear in more than one block (not observed in the corpus,
  # but not structurally forbidden either), so this is a flat list to
  # fold over rather than an eager per-block attrset.
  allSpecEntries = builtins.concatMap (
    src:
    map (spec: {
      inherit spec;
      inherit (src) type remote;
      revision = src.revision or null;
    }) src.specs
  ) doc.sources;

  # One entry per gem NAME (not per spec/version) -- collapses
  # platform-qualified variants down to the bare one, per isBareVersion
  # above. If a gem name has ONLY platform-qualified variants and no bare
  # one at all (not observed in the corpus, but a real possibility for a
  # native-extension-only gem), keep the first variant encountered rather
  # than silently dropping the gem -- better to build with an unverified
  # platform-specific hash than to omit a dependency the project actually
  # needs.
  byGemName = builtins.foldl' (
    acc: entry:
    let
      name = entry.spec.name;
      existing = acc.${name} or null;
      preferNew =
        existing == null || (!isBareVersion existing.spec.version && isBareVersion entry.spec.version);
    in
    if preferNew then acc // { ${name} = entry; } else acc
  ) { } allSpecEntries;

  # `doc.checksums` is `null` (not a missing attribute) when the
  # lockfile has no CHECKSUMS section at all -- grammar/gemfile-lock.nix's
  # documentHandler always sets the key, just to `null` when absent -- so
  # `doc.checksums or [ ]` would never trigger; must check for `null`
  # explicitly.
  checksumsByKey = builtins.listToAttrs (
    map (c: {
      name = "${c.name} (${c.version})";
      value = c.sha256;
    }) (if doc.checksums == null then [ ] else doc.checksums)
  );

  mkSource =
    name: entry:
    if entry.type == "gem" then
      let
        key = "${name} (${entry.spec.version})";
        hex = checksumsByKey.${key} or null;
      in
      {
        type = "gem";
        remotes = [ entry.remote ];
        sha256 =
          if hex == null then
            throw "mkGemset: no CHECKSUMS entry for '${key}' -- this Gemfile.lock either predates Bundler 2.7's CHECKSUMS section, or is missing an entry for this gem. Regenerate the lockfile with a Bundler version that writes CHECKSUMS."
          else
            builtins.convertHash {
              hash = hex;
              hashAlgo = "sha256";
              toHashFormat = "nix32";
            };
      }
    else if entry.type == "git" then
      {
        type = "git";
        url = entry.remote;
        rev = entry.revision;
        fetchSubmodules = false;
        sha256 =
          gitHashes.${name}
            or (throw "mkGemset: gem '${name}' is sourced from git (${entry.remote}); supply a hash via gitHashes.\"${name}\" (see README) -- Gemfile.lock never records a content hash for git sources, so this can't be derived from the lockfile alone.");
      }
    else
      # "path"
      {
        type = "path";
        path = entry.remote;
      };

  gemset = builtins.mapAttrs (name: entry: {
    # `bundler` is never a real gemset entry -- bundlerEnv manages it
    # separately (see bundled-common/default.nix's `hasBundler` check),
    # so a spec that depends on `bundler` (as most real gems do, since
    # Bundler itself is usually a declared dependency) must have it
    # filtered out here too, or nixpkgs' own `filterGemset`/`getAttrs`
    # throws "attribute 'bundler' missing" trying to resolve it as an
    # ordinary gemset entry. Confirmed against the real, bundix-generated
    # gemset.nix for nixpkgs' bundler-audit package: its Gemfile.lock
    # lists `bundler` as a direct dependency of bundler-audit, but the
    # committed gemset.nix's `dependencies` list omits it -- bundix
    # applies exactly this filter too, not something specific to us.
    dependencies = map (d: d.name) (builtins.filter (d: d.name != "bundler") entry.spec.dependencies);
    groups = [ "default" ]; # Gemfile.lock doesn't record Bundler groups (only the Gemfile does) -- every gem is treated as belonging to every requested group.
    platforms = [ ];
    source = mkSource name entry;
    version = entry.spec.version;
  }) byGemName;
in
if doc == false then throw "mkGemset: not a valid Gemfile.lock (failed to parse)" else gemset
