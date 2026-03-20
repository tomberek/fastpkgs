#!/usr/bin/env bash
#! nix shell ..#jq.out ..#nix-eval-jobs.out --command bash

url="${1:-github:NixOS/nixpkgs}"

set -x

for attr in legacyPackages.{{x86_64,aarch64}-linux,aarch64-darwin}; do
	nix-eval-jobs --gc-roots-dir $PWD/gcroots --workers 8 --flake "$url#.$attr" --check-cache-status | tee $attr.json.raw
	echo done with nix-eval-jobs: $attr
	jq '{name:.name,attr:.attrPath,outputs:.outputs,isCached:.isCached}' $attr.json.raw | tee $attr.json.pre
	echo done with pre
	jq -n --sort-keys --tab 'reduce inputs as $item ({}; setpath($item.attr; $item | del(.attr)))' $attr.json.pre | tee $attr.json
	echo done with $attr.json
done


for attr in legacyPackages.{{x86_64,aarch64}-linux,aarch64-darwin}.json; do
      echo minimizing $attr
      jq -c 'walk(
	if type == "object" and has("isCached") and has("name") and has("outputs") and (length == 3)
	then
	  if .isCached == null
	  then null
	  else [ .outputs ] end
	else . end)' $attr > $attr.min &
done

