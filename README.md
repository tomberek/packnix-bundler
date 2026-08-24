# packnix-bundler

A pure-Nix Ruby gem/bundler builder: reads a `Gemfile.lock` directly and
builds a working `bundlerEnv`-equivalent, **without running
[`bundix`](https://github.com/nix-community/bundix)** and without any
network access at Nix-eval time for RubyGems-sourced dependencies.

Built on [`packnix`](https://github.com/tomberek/packnix)'s
`grammar/gemfile-lock.nix` — a packrat parser for Bundler's lockfile
format, verified against 134 real `Gemfile.lock` files.

## Why

Today, nixpkgs' `bundlerEnv` needs a `gemset.nix` that `bundix` generates
offline, using network access (or `nix-prefetch-git`) to compute each
gem's fetch hash. But Bundler ≥2.7 lockfiles have a `CHECKSUMS` section —
a hex sha256 per gem — and that hash is *exactly* what `bundix` ends up
storing, just re-encoded. Verified end-to-end in this repo (not just
asserted):

```console
$ nix eval --expr 'builtins.convertHash {
    hash = "1f1d3b7cf2b3ba1a69beca0bb6db13d5438b80bff3cd54cdaaa620b9b07c1c6a";
    hashAlgo = "sha256"; toHashFormat = "nix32"; }'
"0shwgjqbj856mb6m9kgkpy08nhym2gdvc2yaprlimfmky9y3n78z"

$ nix eval --impure --expr 'builtins.fetchurl {
    url = "https://rubygems.org/gems/json-2.21.2.gem";
    sha256 = "0shwgjqbj856mb6m9kgkpy08nhym2gdvc2yaprlimfmky9y3n78z"; }'
"/nix/store/yf7mkb4kzgii8i0nwqxwvbnqsgypnqvj-json-2.21.2.gem"
```

That hash — taken straight from a real `Gemfile.lock`'s `CHECKSUMS`
section, converted with the pure builtin `builtins.convertHash` (no `nix
hash convert` shell-out needed) — actually fetches the real gem, verified
by Nix's own fixed-output-derivation content check. No `bundix`, no
`nix-prefetch-git`, no external tool anywhere in that chain.

## What's pure and what isn't

| source type | pure? | why |
|---|---|---|
| `gem` (RubyGems) | Yes, if `CHECKSUMS` is present | hash comes straight from the lockfile |
| `path` | Always | nixpkgs' `pathDerivation` needs no hash at all |
| `git` | Yes | a `Gemfile.lock` `GIT` block always records a full 40-character commit `revision`, and `builtins.fetchGit { url; rev; }` with a full commit SHA is itself content-addressed and evaluates purely — confirmed: no `--impure` needed for `nix eval`, `nix build`, or `nix flake check`. `mkGemset` pre-fetches the tree and passes it to `buildRubyGem` as `src`, which skips that function's usual (hash-requiring) `fetchgit` call entirely (`gem/default.nix`'s `src = attrs.src or (...)`) |

If a lockfile has no `CHECKSUMS` section at all (pre-Bundler-2.7),
`mkGemset` throws a clear error rather than silently failing for
RubyGems-sourced deps — regenerate it with `bundle lock
--add-checksums`.

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    packnix-bundler.url = "github:tomberek/packnix-bundler";
  };
  outputs = { nixpkgs, packnix-bundler, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.myApp = packnix-bundler.lib.buildBundlerApp {
        inherit pkgs;
        name = "my-ruby-app";
        gemdir = ./.;  # directory containing Gemfile + Gemfile.lock
      };
    };
}
```

`buildBundlerApp` is a thin wrapper around `pkgs.bundlerEnv` — every
other `bundlerEnv` argument (`groups`, `ruby`, `gemConfig`, `postBuild`,
etc.) passes straight through. The only thing replaced is where `gemset`
comes from. `groups` filtering actually works: `mkGemset` parses the
project's `Gemfile` (via packnix's `grammar/gemfile.nix`) to recover
each gem's real Bundler group (`group :test do...end` blocks, inline
`group:`/`groups:` kwargs) — see [Groups filtering](#groups-filtering)
below.

Lower-level: `packnix-bundler.lib.mkGemset { lockFile = ./Gemfile.lock; }`
returns the raw gemset attrset directly, if you want to feed it to
`pkgs.bundlerEnv` yourself or inspect it. If you call it directly (not
via `buildBundlerApp`) and your lockfile has a gem with *only*
platform-qualified spec versions (no bare fallback — see the `chefdk`
writeup below), also pass `platform` (a Ruby-style platform string, e.g.
`"x86_64-linux-gnu"`); `buildBundlerApp` derives and passes this for you
automatically from `pkgs.stdenv.hostPlatform`. Also pass `gemfile` (a
path, or its contents as a string) for real `groups` values — omit it
(or if it fails to parse) and every gem falls back to `["default"]`,
same as not having group information at all.

## Groups filtering

`Gemfile.lock` never records which Bundler *group* a gem belongs to —
only the `Gemfile` does. Without that information, nixpkgs'
`bundlerEnv`'s `groups` argument (meant to let you exclude e.g. a
`development`/`test` group from a production build) is a silent no-op:
every gem ends up tagged `["default"]`, which always satisfies
`groupMatches` regardless of what `groups` a caller passes (confirmed by
reading `bundled-common/functions.nix`).

`mkGemset` fixes this by parsing the actual `Gemfile` (packnix's
`grammar/gemfile.nix` — a real, if intentionally scoped-down, Bundler
DSL parser; see that file's header for exact scope/limitations, e.g.
`gemspec`/`eval_gemfile`/`Dir.glob` aren't modeled) and resolving each
gem's real group set, so that:

```nix
packnix-bundler.lib.buildBundlerApp {
  inherit pkgs;
  name = "my-ruby-app";
  gemdir = ./.;
  groups = [ "default" ]; # excludes anything declared inside `group :test do ... end`
}
```

genuinely excludes a gem declared only inside `group :test do ... end`
from the built environment, not just from `gemset.nix`'s bookkeeping.

Verified end-to-end in `tests/gemset-unit.nix` (part of `nix flake
check`): a fixture Gemfile with `rspec` inside `group :test do...end`
actually disappears from a build's installed gems when `groups =
["default"]`, and reappears when `groups = ["default" "test"]` — not
just that `mkGemset`'s output attrset has the right `groups` field.

## Verified example

`example/` is a real Ruby project (`Gemfile`/`Gemfile.lock` produced by
an actual `bundle lock --add-checksums` run, not hand-written).
`nix build .#example` fetches the real `json` gem from rubygems.org
using the hash extracted from `CHECKSUMS`, and produces a working gem
environment — no `bundix`, no `gemset.nix` committed anywhere in this
repo.

```console
$ nix build .#example
$ ls result/lib/ruby/gems/*/gems/
json-2.21.2
```

`examples/git-source/` demonstrates a git-sourced gem
([`anystyle`](https://github.com/inukshuk/anystyle), pinned to a real
commit) — `nix build .#git-source` fetches it via `builtins.fetchGit`
using the `revision` already in the lockfile, no separate hash needed
anywhere, no `--impure` flag.

## Real-world comparison: nixpkgs' `bundler-audit` and `chefdk`

[`pkgs/tools/security/bundler-audit`](https://github.com/NixOS/nixpkgs/tree/master/pkgs/tools/security/bundler-audit)
is a small, real nixpkgs package using `bundlerEnv` today. Its 3 checked-in
files:

| file | lines | purpose |
|---|---:|---|
| `Gemfile` | 2 | what bundler resolved |
| `Gemfile.lock` | 16 | the resolved dependency graph |
| `gemset.nix` | 23 | **generated offline by `bundix`** — the piece this repo replaces |

Its committed `Gemfile.lock` predates Bundler 2.7 (no `CHECKSUMS`
section) — as of this writing, **no `bundlerEnv`-using package in
nixpkgs has one yet** (checked by scanning every `bundlerEnv` caller in
a full nixpkgs checkout). So `examples/bundler-audit/` in this repo is
the same package's `Gemfile`, with its lockfile regenerated using a
current Bundler (`bundle lock --add-checksums`) to actually exercise the
pure path:

```console
$ nix build .#bundler-audit
$ ./result/bin/bundler-audit version
bundler-audit 0.9.3
```

Same real package, same `pkgs.bundlerEnv` underneath (via
`buildBundlerApp`) — but **`gemset.nix` doesn't exist at all** in this
version. `mkGemset` derives the equivalent attrset from `Gemfile.lock`
directly, at eval time, with the exact same shape `bundix` would have
produced (dependencies, groups, platforms, source, version — see
`lib/mk-gemset.nix`'s header for the field-by-field mapping).

One real wrinkle this surfaced: `bundler-audit`'s `Gemfile.lock` lists
`bundler` itself as one of `bundler-audit`'s direct dependencies (normal
— most gems declare a `bundler` version constraint). But nixpkgs'
`bundlerEnv` manages `bundler` specially and never expects it as an
ordinary gemset entry — the real, `bundix`-generated `gemset.nix` above
confirms this by omitting `bundler` from `bundler-audit`'s `dependencies`
list even though the lockfile has it. `mkGemset` replicates that
filtering; without it, `pkgs.bundlerEnv`'s own dependency-expansion logic
throws `attribute 'bundler' missing` trying to resolve a `bundler`
gemset entry that (correctly) doesn't exist.

`examples/chefdk/` is [`pkgs/development/tools/chefdk`](https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/tools/chefdk),
a much bigger real package (290 gems, native extensions like `ffi-yajl`)
— re-locked the same way (`bundle lock --add-checksums`):

```console
$ nix build .#chefdk
$ ./result/bin/chef --version
ChefDK version: 4.13.3
```

Building this surfaced two real bugs the smaller examples didn't:

1. **Double-slash fetch URLs.** A `Gemfile.lock`'s `remote:` line always
   has a trailing slash (`https://rubygems.org/`); nixpkgs' `fetchurl`
   template appends its own leading `/`, so concatenating verbatim
   produces `https://rubygems.org//gems/...` — which genuinely 404s
   against the real server. The small examples never hit this because
   their gems happened to already be substitutable from a binary cache
   (same store path regardless of the broken URL); `chefdk`'s 290 gems
   include enough not-already-cached ones to expose it directly.
   `mkGemset` now strips the trailing slash to match what a real
   `bundix`-generated `gemset.nix` stores.
2. **Wrong platform variant for native-only gems.** Some gems (`ffi`,
   `nokogiri`) ship *only* platform-qualified spec versions in a
   locally-resolved lockfile (e.g. `ffi (1.17.4-x86_64-linux-gnu)`), with
   no plain fallback version at all. `mkGemset` used to pick whichever
   variant appeared first in the file — on this machine, that happened
   to be `aarch64-linux-gnu`, producing a gemset entry Bundler's runtime
   couldn't find installed (`Could not find ffi-1.17.4-aarch64-linux-gnu
   ... in locally installed gems`). `buildBundlerApp` now derives the
   correct Ruby-style platform string from `pkgs.stdenv.hostPlatform`
   (e.g. `x86_64-linux-gnu`) and passes it to `mkGemset` as `platform`,
   which picks the matching variant when no bare version exists.

## Tests

`nix flake check` runs `tests/gemset-unit.nix`: `mkGemset` against
`example/Gemfile.lock` must match a hand-written expected attrset
exactly (dependencies, groups, platforms, source, version) — the same
hash independently confirmed above to actually fetch the real gem.

## Layout

| Path | What |
|---|---|
| `flake.nix` | Inputs `nixpkgs` + `packnix`; exposes `lib.mkGemset`, `lib.buildBundlerApp`, `packages.<system>.{example,bundler-audit,git-source,chefdk}`, `checks.<system>.gemset-unit`. Per-system outputs via `builtins.mapAttrs (system: pkgs: ...) nixpkgs.legacyPackages` (nixpkgs' own top-level `flake.nix` idiom — see the file's comment) rather than a hardcoded systems list. |
| `lib/mk-gemset.nix` | Parses a `Gemfile.lock` via `packnix.lib.grammars.gemfileLock`, builds a `bundled-common`-compatible gemset attrset. Picks the right spec variant when a gem has multiple platform-qualified versions (prefer a bare version if one exists, matching `bundix`; otherwise the variant matching the optional `platform` argument — see the `chefdk` writeup below), strips a `Gemfile.lock` remote's trailing slash (also surfaced by `chefdk`), filters `bundler` out of every gem's `dependencies` (confirmed against a real `bundix`-generated `gemset.nix`), pre-fetches git-sourced gems via `builtins.fetchGit`, and (given an optional `gemfile`) resolves real Bundler group membership per gem via `packnix.lib.grammars.gemfile` — see [Groups filtering](#groups-filtering). |
| `lib/build-bundler-app.nix` | Thin wrapper: derives a Ruby-style platform string from `pkgs.stdenv.hostPlatform`, feeds `mkGemset`'s output (including the `gemfile` it already resolves for `bundlerEnv` itself) into `pkgs.bundlerEnv`. |
| `example/` | A real, `bundle`-generated `Gemfile`/`Gemfile.lock` pair with a genuine `CHECKSUMS` section. |
| `examples/bundler-audit/` | nixpkgs' real `bundler-audit` package's `Gemfile`, lockfile regenerated with `--add-checksums` — see the comparison below. |
| `examples/git-source/` | A git-sourced gem (`anystyle`, pinned to a real commit). |
| `examples/chefdk/` | nixpkgs' real `chefdk` package (290 gems) — see the comparison below. |
| `tests/gemset-unit.nix` | `mkGemset` output vs. a hand-written expected attrset, plus the groups-filtering regression test (`tests/fixtures/groups/`) — see [Groups filtering](#groups-filtering). |

## Scope / known limitations

- Inherits every scope limitation of `grammar/gemfile-lock.nix` AND
  `grammar/gemfile.nix` (see packnix's README) — e.g. Bundler `PLUGIN
  SOURCES` aren't parsed, and a `Gemfile` using `gemspec`/
  `eval_gemfile`/`Dir.glob ... do |f| ... end` to declare groups falls
  back to `["default"]` for every gem, same as not passing `gemfile` at
  all.
- Git-sourced gems are fetched at *evaluation* time via
  `builtins.fetchGit`, not via a substitutable fixed-output derivation
  like `fetchgit` — repeat evaluations re-run the fetch (git's local
  caching softens this) rather than hitting a binary-cache substitute.
