with builtins;
# original :: attrset
#   default = {}
#
# mapper :: (key -> value -> value) -> attrset -> attrset
#   default = builtins.mapAttrs
#
# cond :: [ String ] -> AttrSet -> Bool
# Note that even if cond evaluates to false, f will still be applied if a leaf is reached
# f :: [ String ] -> Any -> Any
original: mapper: cond: f: set:
let
  recurse =
    attrs: path:
    let
      g =
        name: value:
        let
          path' = path ++ [ name ];
        in
        if isAttrs value && cond path' value then
          recurse (attrs.${name} or { }) path' value
        else
          f (attrs.${name} or { }) path' value;
    in
    mapper g;
in
recurse original [ ] set
