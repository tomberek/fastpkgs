#!/usr/bin/env bash
#! nix shell ..#jq.out ..#nix-eval-jobs.out --command bash

url="${1:-github:NixOS/nixpkgs}"
systems="${2:-x86_64-linux aarch64-linux aarch64-darwin}"
workers="${NIX_EVAL_JOBS_WORKERS:-8}"

set -x

# Written to files, not teed to stdout: nix-eval-jobs emits a full stack
# trace per removed/aliased attribute (there are thousands in nixpkgs), and
# streaming that live can be enough output to get a CI job killed.
for sys in $systems; do
	attr=legacyPackages.$sys
	nix-eval-jobs --gc-roots-dir $PWD/gcroots --workers "$workers" --flake "$url#.$attr" --check-cache-status > $attr.json.raw
	echo done with nix-eval-jobs: $attr
	jq '{name:.name,attr:.attrPath,outputs:.outputs,isCached:.isCached}' $attr.json.raw > $attr.json.pre
	echo done with pre
	jq -n --sort-keys --tab 'reduce inputs as $item ({}; setpath($item.attr; $item | del(.attr)))' $attr.json.pre > $attr.json
	echo done with $attr.json
done


for sys in $systems; do
      attr=legacyPackages.$sys.json
      echo minimizing $attr
      jq -c 'walk(
	if type == "object" and has("isCached") and has("name") and has("outputs") and (length == 3)
	then
	  if .isCached == null
	  then null
	  else [ .outputs ] end
	else . end)' $attr > $attr.min &
done
wait

