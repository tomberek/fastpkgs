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
     that matters past the scrape** — see the next step for what happens
     to it. The rest are large, throwaway files created fresh each time
     the scrape runs.

2. **Rebuild fake derivations** (`flake.nix`, `mkFakeDerivation.nix`,
   `mapAttrsRecursiveCondFunc.nix`): When the flake is evaluated, it reads
   the `.min` JSON snapshot — fetched via a `flake = false` input, not read
   from the repo tree (see step 3) — and walks through it recursively
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

3. **Publish and consume the snapshots as release assets** (`scripts/upload-release.sh`,
   `flake.nix`): The `.min` files aren't committed to the repo. Instead,
   `scripts/upload-release.sh` uploads them as assets on a new GitHub
   Release, and `flake.nix` declares one `flake = false` input per system
   (`data-x86_64-linux`, `data-aarch64-linux`, `data-aarch64-darwin`)
   pointing at that release's download URLs. `flake.lock` pins their exact
   content hash, just like any other flake input. To publish a fresh
   snapshot: run `scripts/scrape.sh`, then `scripts/upload-release.sh
   <tag>`, update the URLs in `flake.nix` to the new tag, and run `nix
   flake lock`.

4. **Expose it as flake outputs** (`flake.nix`): The flake's outputs —
   `packages`, `legacyPackages`, and `apps`, one set per system — are all
   built from the `.min` snapshots (via those data inputs) using
   `lib.packagesFromJSON`. `originalPackages` holds the real, unchanged
   nixpkgs input, in case you want to compare against it or fall back to
   it. `packages.<system>.default` bundles the three systems' `.min`
   snapshots together with the flake's own files into one archive,
   `fast.tar.xz` — this is the file this repo is meant to publish as a
   release.

## Repo layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | The flake's outputs: the fake package/app sets, the data-input declarations, and the default release tarball. |
| `mkFakeDerivation.nix` | Builds one fake derivation attrset from one entry in the snapshot. |
| `mapAttrsRecursiveCondFunc.nix` | A general-purpose, conditional, recursive `mapAttrs`, used to walk the snapshot tree. |
| `default.nix` | A `flake-compat` shim, so the flake also works with older, non-flake Nix commands. |
| `scripts/scrape.sh` | Regenerates the `legacyPackages.<system>.json*` snapshot files by running `nix-eval-jobs`. |
| `scripts/upload-release.sh` | Publishes the `.min` snapshots as assets on a new GitHub Release. |
| `gcroots/` | A directory `nix-eval-jobs` uses to hold GC roots while scraping. It's local only and never committed. |

Only a handful of files are tracked in git: `flake.nix`, `flake.lock`, the
two helper `.nix` files, and the two scripts. Nothing under
`legacyPackages.*.json*` is committed — those are either large scratch
output from running the scraper locally (`.raw`, `.pre`, the uncompressed
`.json`), or the `.min` snapshot, which is hosted as a GitHub Release asset
and pulled in through `flake.lock` instead (see "How it works" above).
`gcroots/` is likewise local-only scratch output.

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

To publish a fresh snapshot after scraping (needs push access to the repo
and a `gh` login):

```sh
scripts/upload-release.sh data-YYYYMMDD
```

Then update the URLs in `flake.nix`'s `data-*` inputs to the new tag, and
run `nix flake lock` to pin them.

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
- For the best experience, use a Nix version that includes
  [NixOS/nix#15726](https://github.com/NixOS/nix/pull/15726). Without it,
  commands like `nix build .#hello.out` can fail outright instead of
  falling back to another location (like `legacyPackages`) when an
  attribute doesn't resolve the way Nix expects — which fake derivations,
  by their nature, can run into.
- Publishing a new snapshot is a two-step, manual process: run
  `scripts/upload-release.sh`, then hand-edit the tag baked into
  `flake.nix`'s `data-*` input URLs and re-run `nix flake lock`. Nothing
  automates that edit yet.
