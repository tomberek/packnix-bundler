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
| `git` | No | a `Gemfile.lock` `GIT` block only records `remote`/`revision`, never a content hash, and nixpkgs' `buildRubyGem` hardcodes a `fetchgit` call that requires one (confirmed by reading `pkgs/development/ruby-modules/gem/default.nix` — no hash-free fallback exists there) |

For git-sourced gems, supply the hash yourself via `gitHashes` (see
below) — still no `bundix` invocation anywhere, just the one manual hash
per git dependency you'd need for any `fetchgit`-based nixpkgs derivation
whose upstream doesn't embed a content hash.

If a lockfile has no `CHECKSUMS` section at all (pre-Bundler-2.7), `mkGemset`
throws a clear error rather than silently failing — regenerate it with
`bundle lock --add-checksums`.

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
        # gitHashes = { "some-git-gem" = "sha256-..."; };  # only if you have git-sourced gems
      };
    };
}
```

`buildBundlerApp` is a thin wrapper around `pkgs.bundlerEnv` — every
other `bundlerEnv` argument (`groups`, `ruby`, `gemConfig`, `postBuild`,
etc.) passes straight through. The only thing replaced is where `gemset`
comes from.

Lower-level: `packnix-bundler.lib.mkGemset { lockFile = ./Gemfile.lock; }`
returns the raw gemset attrset directly, if you want to feed it to
`pkgs.bundlerEnv` yourself or inspect it.

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

## Tests

`nix flake check` runs `tests/gemset-unit.nix`: `mkGemset` against
`example/Gemfile.lock` must match a hand-written expected attrset
exactly (dependencies, groups, platforms, source, version) — the same
hash independently confirmed above to actually fetch the real gem.

## Layout

| Path | What |
|---|---|
| `flake.nix` | Inputs `nixpkgs` + `packnix`; exposes `lib.mkGemset`, `lib.buildBundlerApp`, `packages.<system>.example`, `checks.<system>.gemset-unit`. |
| `lib/mk-gemset.nix` | Parses a `Gemfile.lock` via `packnix.lib.grammars.gemfileLock`, builds a `bundled-common`-compatible gemset attrset. Handles platform-qualified spec versions (matches `bundix`'s own behavior: prefer the platform-suffix-less variant when both exist — confirmed against two real nixpkgs packages' paired `Gemfile.lock`/`gemset.nix`). |
| `lib/build-bundler-app.nix` | Thin wrapper: `mkGemset` output fed into `pkgs.bundlerEnv`. |
| `example/` | A real, `bundle`-generated `Gemfile`/`Gemfile.lock` pair with a genuine `CHECKSUMS` section. |
| `tests/gemset-unit.nix` | `mkGemset` output vs. a hand-written expected attrset. |

## Scope / known limitations

- Inherits every scope limitation of `grammar/gemfile-lock.nix` (see
  packnix's README) — e.g. Bundler `PLUGIN SOURCES` aren't parsed.
- Gemfile.lock doesn't record Bundler *groups* (only the `Gemfile` does)
  — every gem is treated as belonging to `["default"]`. If you rely on
  `bundlerEnv`'s `groups` filtering to exclude e.g. a `development`
  group's gems, this won't currently filter them out.
- Git-sourced gems need a manually-supplied hash (see above) — not a bug,
  a structural fact about what a `Gemfile.lock` records.
