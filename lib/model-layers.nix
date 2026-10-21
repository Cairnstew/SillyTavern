# lib/model-layers.nix
#
# Turns the declarative `modelLayers` tree into two artifacts:
#
#   1. preset buckets in the same shape `mkPresetFiles` consumes, so the
#      existing seeder writes them with no new Python;
#   2. a per-account manifest that a future client extension reads to choose
#      the profile and preset for the active model and character.
#
# The merge order is the whole point:
#
#   catalog.<id>.presets                     host-wide defaults for a model
#     → byUser.<handle>.models.<id>.presets  this user's model overrides
#       → …characters.<name>.presets         this character's overrides
#
# Each layer is a partial tree, not a whole preset. `deepMerge` is passed in
# rather than imported so there is exactly one definition of "deep merge" in
# the project (`lib/default.nix`), and lists keep their documented
# replace-wholesale semantics.
#
# The generator is PURE and does not read the module config. `modules/config.nix`
# decides which handles exist; this file decides what each handle's files look
# like.
{ lib, deepMerge }:

let
  inherit (lib)
    genAttrs
    mapAttrs
    mergeAttrsList
    optionalAttrs
    ;

  # The six buckets a model layer can carry. Deliberately the same names as
  # `presets.*` in modules/options.nix; `mkPresetFiles` maps them to upstream's
  # directories.
  buckets = [
    "openai"
    "textGeneration"
    "instruct"
    "context"
    "sysprompt"
    "reasoning"
  ];

  # A name that becomes a FILE NAME inside an account directory. Linux allows
  # almost anything, but a `/` would create a subdirectory, a backslash is a
  # Windows separator, and a control character is not representable in a
  # reliable way. Leading/trailing spaces and dots are refused because they
  # are the classic way a name becomes invisible or ambiguous.
  badChars = [
    "/"
    "\\"
    "\n"
    "\r"
    "\t"
  ];

  safeComponent =
    value:
    value != ""
    && value != "."
    && value != ".."
    && !(lib.hasPrefix "." value)
    && !(lib.hasPrefix " " value)
    && !(lib.hasSuffix " " value)
    && !(lib.hasSuffix "." value)
    && builtins.stringLength value <= 160
    && lib.all (char: !(lib.hasInfix char value)) badChars;

  # The model id becomes a preset name by default. `/` is the only character
  # that is actually unsafe in a file name, and HuggingFace-style ids use it.
  # An explicit `presetName` is always allowed and is what the manifest reports.
  defaultPresetName = id: builtins.replaceStrings [ "/" "\\" ] [ "-" "-" ] id;

  # A stable id for the Connection Profile. The extension APPENDS a profile
  # with this id when it is missing; it never rewrites the array, because the
  # array is user-owned state (`extension_settings.connectionManager.profiles`).
  #
  # The slug alone is not unique: `/`, `:` and a space all collapse to `-`, so
  # `a/b` and `a:b` would share a profile and the extension would silently
  # apply the wrong one. A short hash of the ORIGINAL id keeps the id readable
  # and makes a collision a hash collision rather than a naming accident.
  profileId =
    id:
    let
      slug = builtins.replaceStrings [ "/" ":" " " "\\" ] [ "-" "-" "-" "-" ] id;
      digest = builtins.substring 0 8 (builtins.hashString "sha256" id);
    in
    "st-nix-${slug}-${digest}";

  presetEntry = body: {
    json = body;
    # Base presets are Nix-authored but user-editable by design: `missing`
    # means a preset the operator changed in the UI survives `nixos-rebuild`.
    policy = "missing";
    # `normaliseFiles` reads `policy` and `mode` unconditionally, so every
    # entry it sees must carry both. `null` means "leave the default".
    mode = null;
  };

  mergedBucket = entry: userModel: bucket:
    deepMerge (entry.presets.${bucket} or { }) (userModel.presets.${bucket} or { });

  # Resolve one model for one user.
  resolveModel =
    id: entry: userModel:
    let
      presetName = if entry.presetName != null then entry.presetName else defaultPresetName id;

      merged = bucket: mergedBucket entry userModel bucket;

      # The connection is the second thing this generator OWNS, for the same
      # reason as `contextSize`: `connection.*` is the one declarative source of
      # the endpoint, so a preset body must not be able to disagree with it.
      # The assertion in modules/assertions.nix refuses a conflicting value.
      #
      # These keys belong in the PRESET BODY because that is the only per-model
      # slot SillyTavern has: an account has ONE `oai_settings`, so a second
      # model's endpoint has nowhere else to live. Upstream applies them when the
      # preset is selected — `onSettingsPresetChange` (`public/scripts/openai.js`)
      # walks `settingsToUpdate` and writes `custom_url`, `custom_model` and
      # `chat_completion_source` into `oai_settings` — but ONLY while
      # `oai_settings.bind_preset_to_connection` is true. That toggle is NOT part
      # of `settingsToUpdate`, so it cannot be set from a preset body; it is a
      # global key whose upstream default is `true`. If an account has turned it
      # off, selecting the preset applies sampling and nothing else.
      connectionBody = {
        chat_completion_source = entry.connection.api;
        custom_url = entry.connection.url;
        custom_model = entry.connection.model;
      };

      # The context size is the other owned value. Both are written last, so a
      # preset body cannot silently disagree with the backend's `c = <ctxSize>`.
      openaiBody = (merged "openai") // connectionBody // {
        openai_max_context = entry.contextSize;
      };

      hasContent = bucket: merged bucket != { };

      modelBuckets = {
        openai = {
          "${presetName}" = presetEntry openaiBody;
        };
      } // genAttrs (builtins.filter (b: b != "openai") buckets) (
        bucket: optionalAttrs (hasContent bucket) {
          "${presetName}" = presetEntry (merged bucket);
        }
      );

      character =
        char: charCfg:
        let
          charName = "${presetName} ~ ${char}";
          charMerged = bucket: deepMerge (merged bucket) (charCfg.presets.${bucket} or { });
          charBucket = bucket:
            if bucket == "openai" then {
              "${charName}" = presetEntry (
                (charMerged "openai") // connectionBody // {
                  openai_max_context = entry.contextSize;
                }
              );
            } else if (charCfg.presets.${bucket} or { }) != { } then {
              "${charName}" = presetEntry (charMerged bucket);
            } else {
              # The character does not touch this bucket. It falls back to the
              # model's preset, which is why the manifest omits it.
              };
        in
        {
          inherit charName;
          buckets = genAttrs buckets charBucket;
          # Only the buckets that actually produced a file.
          names = genAttrs (builtins.filter (b: charBucket b != { }) buckets) (_: charName);
        };

      characters = mapAttrs character (userModel.characters or { });
    in
    {
      inherit presetName;
      # Character presets live in the SAME bucket maps as the model's, because
      # they are files in the same directory. Merging them here is what makes
      # `<presetName> ~ <character>.json` appear at all.
      presets = genAttrs buckets (
        bucket:
        mergeAttrsList (
          [ modelBuckets.${bucket} or { } ]
          ++ map (character: character.buckets.${bucket} or { }) (lib.attrValues characters)
        )
      );
      chars = characters;
      manifest = {
        connection = {
          id = profileId id;
          name = presetName;
          inherit (entry.connection) api url model secretId;
          preset = presetName;
        };
        presets = {
          openai = presetName;
        } // genAttrs (builtins.filter (b: b != "openai" && hasContent b) buckets) (_: presetName);
        characters = mapAttrs (_char: c: c.names) characters;
        contextSize = entry.contextSize;
      };
    };

  resolveForHandle =
    { catalog, user ? { } }:
    let
      userModels = user.models or { };
      resolved = mapAttrs (id: entry: resolveModel id entry (userModels.${id} or { })) catalog;
      resolvedList = lib.attrValues resolved;
    in
    {
      # One map per bucket, merged across models. Two models with the same
      # presetName would collide here; modules/assertions.nix refuses that
      # before it can happen.
      presets = genAttrs buckets (
        bucket: mergeAttrsList (map (model: model.presets.${bucket} or { }) resolvedList)
      );

      manifest = {
        version = 1;
        models = mapAttrs (_id: model: model.manifest) resolved;
      };
    };
in
{
  inherit buckets safeComponent defaultPresetName profileId resolveForHandle;
}
