# forms data in catalog format into a fake derivation with a store path that
# can be substituted
value: path: element:
let
  outputs = element.outputs or (throw "unable to create mkFakeDerivation: no outputs");
  outputNames = builtins.attrNames outputs;
  defaultOutput =
    if outputs ? bin then
      "bin"
    else if outputs ? out then
      "out"
    else if outputs ? lib then
      "lib"
    else if outputs ? dev then
      "dev"
    else
      builtins.head outputNames;
  common = {
    name = element.name or "unnamed";
    version = element.version or null;
    pname = element.pname or null;
    meta = element.meta or { };
    system = element.system or { };
    original =
      assert common.outPath == value.outPath;
      value;
    drvPath =
      let
        p = builtins.concatStringsSep "." path;
        outs = builtins.concatStringsSep ", " outputNames;
      in
      throw ''
        Use ${p}.out because this is a fake derivation,
        or one of (${outs}) for other outputs names,
        or ${p}.original to get to the original
      '';
    outPath = outputsSet.${defaultOutput};
  }
  // outputsSet
  //
    # We want these attributes to have higher precedence than outputsSet since they are critical to
    # the use of the result, and a "type", "all", or "outputs" attribute in outputsSet could override
    # these attributes.
    # Even if "type", "all", or "outputs" from outputsSet get overriden, they will still be accessible
    # via the "all" attirbute below since this is a recursive structure
    {
      type = "derivation";
      outputs = outputNames;
      all = outputsList;
    };
  storePath =
    path:
    builtins.appendContext path {
      ${path} = {
        path = true;
      };
    };
  outputToAttrListElement = outputName: {
    name = outputName;
    # value = common // { outPath = storePath outputs.${outputName}; inherit outputName;};
    value = storePath outputs.${outputName};
  };
  outputsList = map outputToAttrListElement outputNames;
  outputsSet = builtins.listToAttrs outputsList;
in
common
