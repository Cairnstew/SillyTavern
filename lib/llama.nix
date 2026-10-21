# lib/llama.nix
#
# The `.ini` file llama.cpp's router reads from `--models-preset`
# (`LLAMA_ARG_MODELS_PRESET`). Pure: no `pkgs`, no `config`, so it can be
# exercised from `lib/tests.nix` without evaluating a system.
#
# The format is documented in `tools/server/README.md` of llama.cpp:
#
#   version = 1
#
#   [*]                       global defaults for every model
#   c = 8192
#
#   [some-model-id]           the section name IS the model id the API routes on
#   model = /abs/path.gguf
#   c = 16384
#   ngl = all                 keys are CLI flags without the leading dashes
#
# Two properties are load-bearing here and are asserted by the module:
#
#   * a section name becomes `"model"` in a chat-completions request, so it has
#     to survive both INI parsing and a JSON string unchanged;
#   * a key is a CLI flag name (or its `LLAMA_ARG_*` spelling), so it cannot be
#     an arbitrary attribute name.
#
# The renderer deliberately does NOT decide which keys a model gets. That is
# `modules/llama.nix`'s job, because resolving a `weights` source to a store
# path needs `pkgs`, and a pure renderer must not.
{ lib }:

let
  # INI has no typed scalars worth relying on: llama.cpp parses the right-hand
  # side as a string and converts per flag. Booleans are spelled the way the
  # docs spell them; lists are the comma-separated form `--tensor-split 3,1`
  # uses; everything else is `toString`.
  renderValue =
    value:
    if builtins.isBool value then
      (if value then "true" else "false")
    else if builtins.isList value then
      lib.concatStringsSep "," (map renderValue value)
    else
      toString value;

  # A key is a CLI flag without its leading dashes, or an environment-variable
  # spelling. Both are drawn from this alphabet. A dotted key is legal
  # (`model-draft` has a dash, not a dot, but future flags may) and an
  # underscore is needed for the `LLAMA_ARG_*` form.
  validKey = key: builtins.match "[A-Za-z0-9_.-]+" key != null;

  # A section name must not contain an INI delimiter or a control character.
  # `[`/`]` would end the header early; `#`/`;` would turn the rest of the line
  # into a comment; a newline would start a new line. Everything else, including
  # `/` and `:`, is legitimate — HuggingFace-style ids use both.
  validSection = name: name != "" && builtins.match "[^][#;\n\r\t]+" name != null;

  renderSection =
    name: args:
    assert validSection name;
    "[${name}]\n"
    + lib.concatStringsSep "" (
      lib.mapAttrsToList (
        key: value:
        assert validKey key;
        "${key} = ${renderValue value}\n"
      ) (lib.filterAttrs (_: value: value != null) args)
    );
in
{
  inherit renderValue validKey validSection;

  # `models` is already resolved:
  #
  #   { <model-id> = { args = { model = <path>; c = <int>; … }; }; }
  #
  # so this function never guesses at a weights source. `globalArgs`, when
  # non-empty, becomes the `[*]` section; llama.cpp lets a per-model key
  # override it, which is the precedence the module documents.
  renderModelsPreset =
    { globalArgs ? { }, models }:
    "version = 1\n"
    + (
      if globalArgs == { } then
        ""
      else
        "\n[*]\n"
        + lib.concatStringsSep "" (
          lib.mapAttrsToList (key: value: "${key} = ${renderValue value}\n") globalArgs
        )
    )
    + lib.concatStringsSep "" (
      lib.mapAttrsToList (id: model: "\n${renderSection id model.args}") models
    );
}
