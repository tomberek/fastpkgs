#!/usr/bin/env bash
#! nix shell ..#gh.out --command bash
#
# Uploads the current legacyPackages.<system>.json.min snapshots as assets on
# a new GitHub Release, so the flake can consume them as `flake = false`
# inputs instead of reading them out of the repo's own tree.
#
# Usage: scripts/upload-release.sh [tag]
#   tag defaults to "data-$(date +%Y%m%d)".
#
# Requires: gh, authenticated against github.com with push access to the repo.

set -euo pipefail

repo="${FASTPKGS_REPO:-tomberek/fastpkgs}"
tag="${1:-data-$(date +%Y%m%d)}"

files=(
  legacyPackages.x86_64-linux.json.min
  legacyPackages.aarch64-linux.json.min
  legacyPackages.aarch64-darwin.json.min
)

for f in "${files[@]}"; do
  [ -f "$f" ] || {
    echo "missing $f - run scripts/scrape.sh first" >&2
    exit 1
  }
done

set -x
gh release create "$tag" \
  --repo "$repo" \
  --title "$tag" \
  --notes "Nixpkgs cache-status snapshot data for fastpkgs." \
  "${files[@]}"

echo "Uploaded. Point flake.nix inputs at:"
for f in "${files[@]}"; do
  echo "  https://github.com/$repo/releases/download/$tag/$f"
done
echo "Then run: nix flake lock"
