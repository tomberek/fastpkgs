{
  inputs.flake-compat = {
    url = "github:NixOS/flake-compat";
    flake = false;
  };
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2fcb964de67fcf60b43471c55d5d99e61a9ccb5a";

  outputs = _: {
    # WIP: still working on the interface

    lib.mkFakeDerivation = import ./mkFakeDerivation.nix;

    # Assumes [ outputs ] structure in each element
    lib.mkFakeDerivationFromList =
      v: p: e:
      (_.self.lib.mkFakeDerivation v p {
        isCached = true;
        outputs = builtins.elemAt e 0;
      });
    lib.mkFakeOutPathFromList =
      v: p: e:
      (_.self.lib.mkFakeDerivationFromList v p e).outPath;
    lib.mkFakeAppFromList = v: p: e: {
      type = "app";
      program =
        let
          a = (_.self.lib.mkFakeDerivationFromList v p e).outPath;
          b = builtins.elemAt (builtins.match "[^-]*-(.*)" (builtins.unsafeDiscardStringContext a)) 0;
          c = (builtins.parseDrvName b).name;
        in
        "${a}/bin/${c}";
    };

    lib.mapAttrsRecursiveCondFunc = import ./mapAttrsRecursiveCondFunc.nix;
    lib.mkFakePackageSetHelper =
      filter: func: original: path:
      _.self.lib.mapAttrsRecursiveCondFunc original builtins.mapAttrs filter func (
        builtins.fromJSON (builtins.readFile path)
      );

    lib.fromAttrs =
      path: x:
      if (x ? isCached && x.isCached == true) then
        false
      else if x ? isCached then
        throw "The attribute '${builtins.concatStringsSep " " path}' exists, but is not cached in your substituter."
      else
        true;

    lib.fromList =
      path: x:
      if (builtins.isList x) then
        false
      else if x == null then
        throw "The attribute '${builtins.concatStringsSep " " path}' exists, but is not cached in your substituter."
      else
        true;

    lib.mkFakePackageSet = _.self.lib.mkFakePackageSetHelper _.self.lib.fromAttrs _.self.lib.mkFakeDerivation;
    lib.mkFakePackageSetFromList = _.self.lib.mkFakePackageSetHelper _.self.lib.fromList _.self.lib.mkFakeDerivationFromList;
    lib.mkFakePackageSetFromListToPaths = _.self.lib.mkFakePackageSetHelper _.self.lib.fromList _.self.lib.mkFakeOutPathFromList;
    lib.mkFakeAppSetFromListToPaths = _.self.lib.mkFakePackageSetHelper _.self.lib.fromList _.self.lib.mkFakeAppFromList;

    lib.packagesFromJSON =
      helper: suffix:
      builtins.mapAttrs
        (
          system: pkgs:
          (
            helper _.self.originalPackages.legacyPackages.${system} (
              ./. + "/legacyPackages.${system}.json" + suffix
            )
            // {
              # Default build is to build a release.
              default = _.self.originalPackages.legacyPackages.${system}.callPackage (
                {
                  jq,
                  gnutar,
                  runCommand,
                  self ? _.self.outPath,
                }:
                runCommand "fast.tar.xz"
                  {
                    src = self;
                    nativeBuildInputs = [
                      jq
                      gnutar
                    ];
                  }
                  ''
                    mkdir toplevel

                    for i in legacyPackages.{{x86_64,aarch64}-linux,aarch64-darwin}.json; do
                      echo minimizing $i
                      jq -c 'walk(
                        if type == "object" and has("isCached") and has("name") and has("outputs") and (length == 3)
                        then 
                          if .isCached == null
                          then null
                          else [ .outputs ] end
                        else . end)' $src/$i > toplevel/$i.min &
                    done
                    wait
                    echo compressing
                    cp -t toplevel $src/flake.lock $src/*.nix
                    tar -cJf $out toplevel
                    echo done
                  ''
              ) { };
            }
          )
        )
        {
          x86_64-linux = { };
          aarch64-linux = { };
          aarch64-darwin = { };
        };

    packages = _.self.lib.packagesFromJSON _.self.lib.mkFakePackageSetFromListToPaths ".min";
    legacyPackages = _.self.lib.packagesFromJSON _.self.lib.mkFakePackageSetFromList ".min";

    originalPackages = _.nixpkgs;

    inputs = _;

    apps = _.self.lib.packagesFromJSON _.self.lib.mkFakeAppSetFromListToPaths ".min";

    local.x86_64-linux.scrape = {
      type = "app";
      program = ./scripts/scrape.sh;
    };
  };
}
