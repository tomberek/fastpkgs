{
  inputs.flake-compat = {
    url = "github:NixOS/flake-compat";
    flake = false;
  };
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2fcb964de67fcf60b43471c55d5d99e61a9ccb5a";

  # Cache-status snapshots, hosted as release assets instead of committed to
  # the repo tree. Regenerate with scripts/scrape.sh, publish with
  # scripts/upload-release.sh, then `nix flake lock` to pin the new tag.
  # The "file+" prefix tells Nix to fetch this as a single flat file rather
  # than an archive to unpack.
  inputs.data-x86_64-linux = {
    url = "file+https://github.com/tomberek/fastpkgs/releases/download/data-20260813/legacyPackages.x86_64-linux.json.min";
    flake = false;
  };
  inputs.data-aarch64-linux = {
    url = "file+https://github.com/tomberek/fastpkgs/releases/download/data-20260813/legacyPackages.aarch64-linux.json.min";
    flake = false;
  };
  inputs.data-aarch64-darwin = {
    url = "file+https://github.com/tomberek/fastpkgs/releases/download/data-20260813/legacyPackages.aarch64-darwin.json.min";
    flake = false;
  };

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

    # Maps each system to the flake input holding that system's snapshot data.
    lib.dataInputs = {
      x86_64-linux = _.data-x86_64-linux;
      aarch64-linux = _.data-aarch64-linux;
      aarch64-darwin = _.data-aarch64-darwin;
    };

    lib.packagesFromJSON =
      helper:
      builtins.mapAttrs
        (
          system: pkgs:
          (
            helper _.self.originalPackages.legacyPackages.${system} _.self.lib.dataInputs.${system}.outPath
            // {
              # Default build is to build a release.
              default = _.self.originalPackages.legacyPackages.${system}.callPackage (
                {
                  gnutar,
                  runCommand,
                  self ? _.self.outPath,
                  dataInputs ? _.self.lib.dataInputs,
                }:
                runCommand "fast.tar.xz"
                  {
                    src = self;
                    nativeBuildInputs = [ gnutar ];
                  }
                  ''
                    mkdir toplevel
                    ${builtins.concatStringsSep "\n" (
                      builtins.attrValues (
                        builtins.mapAttrs (
                          sys: input:
                          "cp ${input.outPath} toplevel/legacyPackages.${sys}.json.min"
                        ) dataInputs
                      )
                    )}
                    cp -t toplevel $src/flake.lock $src/*.nix
                    tar -cJf $out toplevel
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

    packages = _.self.lib.packagesFromJSON _.self.lib.mkFakePackageSetFromListToPaths;
    legacyPackages = _.self.lib.packagesFromJSON _.self.lib.mkFakePackageSetFromList;

    originalPackages = _.nixpkgs;

    inputs = _;

    apps = _.self.lib.packagesFromJSON _.self.lib.mkFakeAppSetFromListToPaths;

    local.x86_64-linux.scrape = {
      type = "app";
      program = ./scripts/scrape.sh;
    };
  };
}
