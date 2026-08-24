# Builds a nixpkgs bundlerEnv-compatible gemset from a Gemfile.lock,
# using packnix's grammar/gemfile-lock.nix parser -- replaces bundix.
#
# `gem` sources are pure whenever CHECKSUMS is present (Bundler >=2.7):
# the hex sha256 there converts via builtins.convertHash to the hash
# bundlerEnv's fetchurl needs. `path` sources need no hash at all.
# `git` sources are pure too: a Gemfile.lock's GIT block always records
# a full 40-character commit revision, and builtins.fetchGit { url; rev;
# } with a full SHA is itself content-addressed and evaluates purely.
# buildRubyGem normally calls fetchgit (which needs a separately
# supplied sha256), but also accepts a caller-supplied `src` that skips
# that fetch entirely -- so this pre-fetches git sources via
# builtins.fetchGit and passes the result through as `src`.
{ packnix }:

{
  # Path to a Gemfile.lock, or its contents as a string.
  lockFile,
  # Path to the companion Gemfile (or its contents), or null to skip
  # group resolution (every gem then gets ["default"]).
  gemfile ? null,
  # Ruby platform string (e.g. "x86_64-linux-gnu") to prefer when a gem
  # has only platform-qualified spec versions and no bare fallback.
  # build-bundler-app.nix derives this from pkgs.stdenv.hostPlatform.
  platform ? null,
}:
let
  inherit (packnix.lib) packrat;
  gemfileLockGrammar = packnix.lib.grammars.gemfileLock;
  gemfileGrammar = packnix.lib.grammars.gemfile;

  contents =
    if builtins.isPath lockFile || builtins.isString lockFile then
      (if builtins.pathExists lockFile then builtins.readFile lockFile else lockFile)
    else
      throw "mkGemset: lockFile must be a path or a string";

  # A PATH source's remote: (e.g. "." or a relative subdirectory) is
  # relative to lockFile's own directory, matching how a real
  # bundix-generated gemset.nix stores it (path = ./.;). Only resolvable
  # when lockFile is an actual path.
  lockFileDir = if builtins.isPath lockFile then builtins.dirOf lockFile else null;

  doc =
    (packrat.run {
      grammar = gemfileLockGrammar.grammar;
      handlers = gemfileLockGrammar.handlers;
    } 0 contents).DOCUMENT;

  # Gemfile.lock never records Bundler groups -- only the Gemfile does.
  # Falls back to {} (every gem -> "default") when gemfile is absent or
  # fails to parse; groups are additive, not required for a build.
  gemfileContents =
    if gemfile == null then
      null
    else if builtins.isPath gemfile || builtins.isString gemfile then
      (if builtins.pathExists gemfile then builtins.readFile gemfile else gemfile)
    else
      throw "mkGemset: gemfile must be a path, a string, or null";

  gemfileItems =
    if gemfileContents == null then
      null
    else
      (packrat.run {
        grammar = gemfileGrammar.grammar;
        handlers = gemfileGrammar.handlers;
      } 0 gemfileContents).DOCUMENT;

  groupsByName = builtins.listToAttrs (
    map (item: {
      name = item.name;
      value = if item.groups == [ ] then [ "default" ] else item.groups;
    }) (if gemfileItems == false || gemfileItems == null then [ ] else gemfileItems)
  );

  # A bare version has no platform suffix. Matches bundix: when a gem
  # has both a bare and platform-qualified spec, keep only the bare one.
  isBareVersion = v: builtins.match "[0-9]+([.][0-9A-Za-z]+)*" v != null;

  # A Gemfile.lock's remote: always has a trailing slash, but nixpkgs'
  # fetchurl template adds its own leading "/" -- concatenating verbatim
  # 404s. A real gemset.nix stores remotes without the trailing slash.
  stripTrailingSlash =
    s:
    if builtins.match ".*/" s != null then builtins.substring 0 (builtins.stringLength s - 1) s else s;

  # Every spec across every GEM/GIT/PATH block, flattened and tagged
  # with its source block's type/remote/revision.
  allSpecEntries = builtins.concatMap (
    src:
    map (spec: {
      inherit spec;
      inherit (src) type remote;
      revision = src.revision or null;
    }) src.specs
  ) doc.sources;

  # Collapse a gem name's platform-qualified variants to a single
  # choice: prefer a bare version (matches bundix); otherwise the
  # variant matching `platform`; otherwise whichever came first.
  specPlatformSuffix =
    v:
    let
      m = builtins.match "[0-9]+([.][0-9A-Za-z]+)*-(.*)" v;
    in
    if m == null then null else builtins.elemAt m 1;

  specRank =
    v:
    if isBareVersion v then
      0
    else if platform != null && specPlatformSuffix v == platform then
      1
    else
      2;

  byGemName = builtins.foldl' (
    acc: entry:
    let
      name = entry.spec.name;
      existing = acc.${name} or null;
      preferNew = existing == null || specRank entry.spec.version < specRank existing.spec.version;
    in
    if preferNew then acc // { ${name} = entry; } else acc
  ) { } allSpecEntries;

  # doc.checksums is null, not missing, when CHECKSUMS is absent.
  checksumsByKey = builtins.listToAttrs (
    map (c: {
      name = "${c.name} (${c.version})";
      value = c.sha256;
    }) (if doc.checksums == null then [ ] else doc.checksums)
  );

  # "gem"/"path" only need `source`. "git" also returns `src` (the
  # pre-fetched tree) as a sibling of `source`, since buildRubyGem reads
  # attrs.src directly, not attrs.source.src.
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
          remotes = [ (stripTrailingSlash entry.remote) ];
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
        # url/rev are still read separately by buildRubyGem's install
        # phase to drive Bundler's own git-checkout emulation.
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
      # "path", resolved against lockFileDir.
      {
        source = {
          type = "path";
          path =
            if lockFileDir == null then
              throw "mkGemset: lockFile must be a path (not a bare string) to resolve PATH source '${entry.remote}'"
            else
              lockFileDir + ("/" + entry.remote);
        };
      };

  gemset = builtins.mapAttrs (
    name: entry:
    {
      # bundler is managed separately by bundlerEnv, never a real entry.
      dependencies = map (d: d.name) (builtins.filter (d: d.name != "bundler") entry.spec.dependencies);
      groups = groupsByName.${name} or [ "default" ];
      platforms = [ ];
      version = entry.spec.version;
    }
    // (mkSourceAndSrc name entry)
  ) byGemName;
in
if doc == false then throw "mkGemset: not a valid Gemfile.lock (failed to parse)" else gemset
