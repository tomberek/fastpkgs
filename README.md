# fastpkgs

`fastpkgs` is a Nix flake. It lets you name a nixpkgs package by its
attribute path (like `legacyPackages.x86_64-linux.hello`) and get back a
real, usable store path — **without making Nix evaluate nixpkgs**.

Here's the problem it solves. Normally, `nix build nixpkgs#somePackage` has
to evaluate that package's derivation first (and often a lot of its
dependencies too) before Nix even knows what to build or fetch. If all you
want is "give me the cached binary for this package," that evaluation step
is wasted work. `fastpkgs` skips it. Ahead of time, and offline, it checks
which packages are already cached and records their store paths. Then, when
you load the flake, it rebuilds lightweight stand-ins — "fake derivations" —
straight from that saved data.

> **Status:** WIP — the interface (attribute names, output shapes) is still
> changing.

## How it works

1. **Scrape** (`scripts/scrape.sh`): This script runs
   [`nix-eval-jobs`](https://github.com/nix-community/nix-eval-jobs) against
   a real nixpkgs flake (by default `github:NixOS/nixpkgs`), once for each
   of three systems: `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.
   For every attribute under `legacyPackages.<system>`, it notes the name,
   the output names, and whether that derivation's outputs are already sitting
   in the configured binary cache (checked with `--check-cache-status`). For
   each system, this produces:
   - `legacyPackages.<system>.json.raw` — the full, unfiltered output from
     `nix-eval-jobs`, including error messages for any attribute that fails
     to evaluate.
   - `legacyPackages.<system>.json.pre` — the same data, trimmed down to just
     `{name, attr, outputs, isCached}`.
   - `legacyPackages.<system>.json` — that trimmed data reshaped into a
     nested tree that matches the real package attribute layout. For
     example, `pkgs.foo.bar` turns into `{"foo":{"bar": {...}}}`.
   - `legacyPackages.<system>.json.min` — a shrunk-down version: anything
     not cached is dropped (shown as `null`), and anything cached is
     reduced to just `[outputs]`. **This is the only one of these files
     that actually gets committed** to the repo. The rest are large,
     throwaway files created fresh each time the scrape runs.

2. **Rebuild fake derivations** (`flake.nix`, `mkFakeDerivation.nix`,
   `mapAttrsRecursiveCondFunc.nix`): When the flake is evaluated, it reads
   the `.min` JSON snapshot and walks through it recursively
   (`mapAttrsRecursiveCondFunc.nix` is a general-purpose helper for walking
   a tree conditionally) to rebuild a tree shaped just like nixpkgs'
   `legacyPackages`. Each cached entry at the bottom of that tree becomes a
   "fake derivation" (built by `mkFakeDerivation.nix`): basically an attrset
   whose `outPath` and other output attributes point at the real store
   paths recorded in the snapshot. It uses `builtins.appendContext` so Nix
   treats those paths as genuine and substitutable. It also has a
   `drvPath` attribute, but reading that just throws a helpful error,
   because there's no real `.drv` behind a fake derivation — these only
   work for pulling an already-built copy, not for building from source.
   You can still reach the real, original nixpkgs package through
   `.original`.

3. **Expose it as flake outputs** (`flake.nix`): The flake's outputs —
   `packages`, `legacyPackages`, and `apps`, one set per system — are all
   built from the `.min` snapshots using `lib.packagesFromJSON`.
   `originalPackages` holds the real, unchanged nixpkgs input, in case you
   want to compare against it or fall back to it.
   `packages.<system>.default` bundles the three systems' `.min` snapshots
   together with the flake's own files into one archive, `fast.tar.xz` —
   this is the file this repo is meant to publish as a release.

## Repo layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | The flake's outputs: the fake package/app sets, the code that loads the snapshot, and the default release tarball. |
| `mkFakeDerivation.nix` | Builds one fake derivation attrset from one entry in the snapshot. |
| `mapAttrsRecursiveCondFunc.nix` | A general-purpose, conditional, recursive `mapAttrs`, used to walk the snapshot tree. |
| `default.nix` | A `flake-compat` shim, so the flake also works with older, non-flake Nix commands. |
| `scripts/scrape.sh` | Regenerates the `legacyPackages.<system>.json*` snapshot files by running `nix-eval-jobs`. |
| `legacyPackages.<system>.json.min` | The committed, shrunk-down cache-status snapshots — this is the actual data the repo ships. |
| `gcroots/` | A directory `nix-eval-jobs` uses to hold GC roots while scraping. It's local only and never committed. |

Only a handful of files are tracked in git: `flake.nix`, `flake.lock`, the
two helper `.nix` files, `scripts/scrape.sh`, and the three `*.json.min`
snapshot files. The `.raw`, `.pre`, and full (uncompressed) `.json` files,
along with `gcroots/`, are just large leftover files from running the
scraper on your own machine — they aren't meant to be kept.

## Usage

To build or fetch a package by its nixpkgs attribute path, pulling from the
snapshot instead of evaluating nixpkgs:

```sh
nix build .#legacyPackages.x86_64-linux.hello
```

To look at the real, underlying nixpkgs derivation instead of the fake one:

```sh
nix eval .#legacyPackages.x86_64-linux.hello.original
```

To build the release tarball (it bundles the `.min` snapshots for all three
systems):

```sh
nix build .#default
```

To regenerate the snapshots yourself (you'll need a configured binary cache
to check against, and it takes a while, since it has to evaluate all of
nixpkgs):

```sh
nix run .#local.x86_64-linux.scrape -- github:NixOS/nixpkgs
```

Running this replaces the `legacyPackages.<system>.json*` files for all
three systems in your current directory.

## Caveats

- A package only shows up with a real output if it happened to be cached in
  the binary cache you had configured when you ran `scrape.sh`. Anything
  that wasn't cached at scrape time just becomes `null` in the snapshot,
  and is left out of `packages`/`legacyPackages` entirely.
- Fake derivations don't have a real `.drv` file behind them, so you can't
  build them from source — you can only fetch an already-built copy.
  Trying to read `.drvPath` throws an error telling you to use `.out` (or
  whichever output name you need) or `.original` instead.
- The snapshot is just a one-time check of cache status against one
  specific nixpkgs revision (the one pinned in `flake.lock`). As the binary
  cache changes over time, the snapshot becomes outdated, and you'll need
  to re-run the scrape.
