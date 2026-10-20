# lib/settings-tree.nix
#
# Builds a TYPED option tree for one `settings.json` surface, from the
# inventory that `scripts/extract_settings_inventory.mjs` derives from
# upstream's own source.
#
# WHY
#
# `settings.common` is a free-form blob. Every one of the 410 real settings
# was reachable through it, and none of them were *knowable*: nothing
# enumerated the names, the types, or the upstream defaults, so a typo was
# accepted silently and did nothing.
#
# This library turns the inventory into option declarations, so the same
# knowledge that powers the key guard also powers the option tree. There is
# no second list to keep in step: a field added upstream appears in the
# inventory, and therefore appears here, and therefore becomes an option.
#
# THE SHAPE OF THE OPTIONS
#
#   * Every leaf is `nullOr <type>` with `default = null`.
#
#     `null` means "not declared" — the account keeps upstream's own default.
#     That matters: upstream's defaults are computed at runtime (a theme
#     colour is read out of the CSS), and pinning them here would freeze
#     them, so an upstream change would stop taking effect.
#
#   * Object paths become nested submodules.
#
#   * Free-form maps (`personas`, `bias_presets`, `*.extensions`, …) become
#     `attrsOf anything`: their keys are data, not structure.
#
#   * Option names are upstream's OWN, verbatim — `font_scale`, not
#     `fontScale`. These options mirror a JSON document, and a mirror that
#     renames things is a mirror you have to translate in your head. The
#     camelCase convention used by the older `settingsExtra` members maps a
#     Nix name onto a JSON key; here the JSON key IS the name.
#
# PRUNING
#
# `prune` is the other half. A submodule's value contains every declared
# option, so an untouched tree is 182 nulls. `prune` strips the nulls and the
# empty objects they leave behind, and what remains is exactly what the
# operator declared — which is what gets written to `settings.json`.
{ lib, inventory }:

let
  inherit (lib) types;

  # The inventory's leaf types, mapped onto Nix types.
  #
  # `unknown` means the value is an upstream constant the extractor could not
  # resolve statically (an enum member, a prompt template). `null` means
  # upstream's own default is null. Neither has a type to enforce, so both
  # become `anything` — the guard still refuses the *path*, which is the
  # thing that actually matters.
  leafType =
    name:
    if name == "bool" then
      types.bool
    else if name == "int" || name == "float" then
      # JavaScript has ONE number type: every number is a double, and an
      # integral default says nothing about the field. `font_scale` defaults
      # to `1` and is meant to be set to `1.2`; `max_context` defaults to
      # `4096` and is meant to be set to `8192`. Both are numbers, so both
      # accept an integer or a float.
      types.number
    else if name == "str" then
      types.str
    else if name == "array" then
      types.listOf types.anything
    else
      types.anything;

  # How upstream's default is rendered in an option description.
  defaultText =
    field:
    let
      value = field.value;
    in
    if field.type == "unknown" then
      "an upstream constant (its exact value is resolved at runtime)"
    else if field.type == "null" then
      "null"
    else if field.type == "array" then
      "a list"
    else if field.type == "bool" then
      if value then "true" else "false"
    else if field.type == "str" then
      ''"${value}"''
    else
      toString value;

  # ── The tree ───────────────────────────────────────────────────────────────
  #
  # A node is one of:
  #   { leaf = <field>; children = {}; open = false; }   a setting
  #   { leaf = null; children = { … }; open = false; }   a fixed object
  #   { leaf = null; children = { … }; open = true; }    a free-form map
  emptyNode = {
    leaf = null;
    children = { };
    open = false;
  };

  insert =
    node: segments: field:
    if segments == [ ] then
      node // { leaf = field; }
    else
      let
        name = builtins.head segments;
        rest = lib.tail segments;
        child = node.children.${name} or emptyNode;
      in
      node // {
        children = node.children // {
          ${name} = insert child rest field;
        };
      };

  # Mark a path as a free-form map. The path exists (the inventory only
  # lists real paths), so this can only widen it.
  markOpen =
    node: segments:
    if segments == [ ] then
      node // { open = true; }
    else
      let
        name = builtins.head segments;
        rest = lib.tail segments;
        child = node.children.${name} or emptyNode;
      in
      node // {
        children = node.children // {
          ${name} = markOpen child rest;
        };
      };

  tree =
    surface:
    let
      fields = (inventory.surfaces.${surface} or { fields = [ ]; }).fields;
      opens = (inventory.surfaces.${surface} or { openPaths = [ ]; }).openPaths;
      withFields = lib.foldl' (node: field: insert node (lib.splitString "." field.path) field) emptyNode fields;
      withOpens = lib.foldl' (node: path: markOpen node (lib.splitString "." path)) withFields opens;
    in
    withOpens;

  # ── Option declarations ────────────────────────────────────────────────────
  #
  # Recursive: a node with children becomes a submodule whose options are
  # built from those children.
  optionsFor =
    surface: children:
    lib.mapAttrs
      (name: child:
        let
          path = "${surface}.${name}";
          mk = lib.mkOption;
        in
        if child.open then
          mk {
            type = types.nullOr (types.attrsOf types.anything);
            default = null;
            description = ''
              The `${path}` map in the account's `settings.json`.

              This map is keyed by DATA, not by structure — `personas` by
              persona name, `bias_presets` by preset name — so any key is
              allowed here. The module cannot know what you would call your
              presets, and refusing to guess is the point.
            '';
          }
        else if child.leaf != null then
          mk {
            type = types.nullOr (leafType child.leaf.type);
            default = null;
            description = ''
              The `${path}` setting in the account's `settings.json`.

              Upstream's default: ${defaultText child.leaf}.

              `null` means "not declared", and the account keeps upstream's own
              default. Declaring a value here makes it Nix's to hand: it is
              written to `settings.json` on every activation, and the UI can
              change it until the next one.
            '';
          }
        else
          mk {
            type = types.submoduleWith {
              modules = [
                {
                  options = optionsFor surface child.children;
                }
              ];
              shorthandOnlyDefinesConfig = false;
            };
            default = { };
            description = ''
              The `${path}` object in the account's `settings.json`.

              Upstream's own fields are declared individually below; anything
              upstream does not have is refused at evaluation time.
            '';
          })
      children;
in
rec {
  # The option declarations for one surface, as a submodule type.
  #
  # `submoduleWith` rather than `submodule`, and `shorthandOnlyDefinesConfig
  # = false` rather than the default `true`, for ONE reason: strictness.
  #
  # `types.submodule` treats a definition as *config* — a free-form attrset
  # that is merged over the declared options. A typo in it is then not an
  # error; it is an unknown key in `config`, which the module system has no
  # opinion about. The whole point of this tree is that a typo is loud.
  #
  # With `shorthandOnlyDefinesConfig = false`, a definition is treated as a
  # MODULE, and the module system checks every attribute against the declared
  # options: an unknown one fails with "The option `…font_scal' does not
  # exist".
  #
  # The declarations themselves must be under `options = { … }` for the same
  # reason: a submodule module that returns a bare attrset is defining config,
  # not options.
  surfaceType =
    surface:
    types.submoduleWith {
      modules = [
        {
          options = optionsFor surface (tree surface).children;
        }
      ];
      shorthandOnlyDefinesConfig = false;
    };

  # The Nix type of one leaf, by its path.
  #
  # Exposed so a test can assert on the type MAPPING without going through
  # the module system: a type error inside a submodule is thrown while the
  # submodule's own fixpoint is computed, which `builtins.tryEval` cannot
  # catch (it is eager), so the only way to test it is to ask the type
  # directly.
  typeOfPath =
    surface: path:
    let
      node = tree surface;
      walk =
        node: segments:
        if segments == [ ] then
          node
        else
          walk (node.children.${builtins.head segments} or emptyNode) (lib.tail segments);
      found = walk node (lib.splitString "." path);
    in
    if found.leaf != null then
      types.nullOr (leafType found.leaf.type)
    else if found.open then
      types.nullOr (types.attrsOf types.anything)
    else
      types.nullOr (types.attrsOf types.anything);

  # Strip the nulls (and the empty objects they leave behind) from a declared
  # tree, so that what is written to `settings.json` is exactly what the
  # operator declared — and nothing else.
  prune =
    value:
    if lib.isAttrs value then
      let
        pruned = lib.mapAttrs (_: v: prune v) value;
      in
      lib.filterAttrs (_: v: v != null && !(lib.isAttrs v && v == { })) pruned
    else
      value;
}
