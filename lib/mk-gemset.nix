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
# What's genuinely pure (no network access at Nix-eval time, i.e. no
# `--impure` flag needed anywhere) vs. not:
#   - `type = "gem"` (RubyGems-sourced) sources: FULLY pure whenever the
#     lockfile has a CHECKSUMS section (Bundler >=2.7) -- the hex sha256
#     there converts via `builtins.convertHash` to exactly the hash
#     `bundlerEnv`'s `fetchurl` needs, verified against a real nixpkgs
#     package's paired Gemfile.lock/gemset.nix (see packnix's README).
#   - `type = "path"` sources: always pure, no hash needed at all
#     (nixpkgs' `pathDerivation` just treats the path as already-resolved).
#   - `type = "git"` sources: ALSO fully pure -- see below. A
#     Gemfile.lock's GIT block always records a full 40-character commit
#     `revision` (confirmed via packnix's own 136-file corpus survey),
#     and `builtins.fetchGit { url; rev; }` with a full commit SHA is
#     itself content-addressed and evaluates correctly under Nix's
#     default pure-evaluation mode -- confirmed directly: no `--impure`
#     needed for `nix eval`, `nix build`, or `nix flake check` when
#     `rev` is a full SHA (this only fails for a `ref`/branch name, or a
#     `rev` shorter than a full commit hash, neither of which a
#     Gemfile.lock ever produces). nixpkgs' `buildRubyGem` normally calls
#     `fetchgit` (which DOES need a separately-supplied `sha256`, with no
#     hash-free path -- confirmed by reading
#     `pkgs/development/ruby-modules/gem/default.nix`), but it also
#     accepts a caller-supplied `src` that skips that fetch entirely
#     (`src = attrs.src or (...)` in that same file) -- so `mkGemset`
#     pre-fetches git sources itself via `builtins.fetchGit` and passes
#     the result through as each gemset entry's top-level `src`, letting
#     every other part of `buildRubyGem` (native extension compilation,
#     binstubs, etc.) run completely unmodified.
{ packnix }:

{
  # Path to a Gemfile.lock, OR its already-read contents as a string.
  lockFile,
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

  # For "gem"/"path" sources, only `source` is needed (mirrors bundix's
  # own gemset.nix shape exactly). For "git" sources, this ALSO returns
  # `src` -- the pre-fetched tree -- which must be spliced into the
  # gemset entry as a sibling of `source`, not inside it: `buildRubyGem`
  # reads `attrs.src` directly (`gem/default.nix`'s `src = attrs.src or
  # (...)`), not `attrs.source.src`.
  mkSourceAndSrc =
    name: entry:
    if entry.type == "gem" then
      let
        key = "${name} (${entry.spec.version})";
        hex = checksumsByKey.${key} or null;
      in
      {
        source = {
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
        };
      }
    else if entry.type == "git" then
      {
        # `url`/`rev` are still required here even though `src` already
        # supplies the fetched tree -- `gem/default.nix`'s install phase
        # separately re-reads `attrs.source.url`/`attrs.source.rev` to
        # drive Bundler's own git-checkout emulation (confirmed by
        # reading that file: lines quoting `${attrs.source.url}` and
        # `${attrs.source.rev}` directly into the install script).
        # `sha256`/`fetchSubmodules` are NOT needed -- those only matter
        # to the `fetchgit` call this bypasses by supplying `src`
        # directly.
        source = {
          type = "git";
          url = entry.remote;
          rev = entry.revision;
        };
        src = builtins.fetchGit {
          url = entry.remote;
          rev = entry.revision;
        };
      }
    else
      # "path"
      {
        source = {
          type = "path";
          path = entry.remote;
        };
      };

  gemset = builtins.mapAttrs (
    name: entry:
    {
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
      version = entry.spec.version;
    }
    // (mkSourceAndSrc name entry)
  ) byGemName;
in
if doc == false then throw "mkGemset: not a valid Gemfile.lock (failed to parse)" else gemset
