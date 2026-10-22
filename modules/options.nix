# modules/options.nix
#
# Options for `services.sillytavern-nixos`.
#
# ── Why the namespace is NOT `services.sillytavern` ───────────────────────────
#
# nixos-unstable ships its own `services.sillytavern`
# (nixos/modules/services/web-apps/sillytavern.nix), and it is in
# `module-list.nix`, so it is present in EVERY NixOS system whether or not anyone
# wants it. A consumer cannot remove a module from that list, so declaring the
# same option twice is unavoidable — NixOS fails the build with "The option
# `services.sillytavern.enable` … is already declared".
#
# The upstream module is genuinely minimal: `enable`, `user`, `group`,
# `configFile`, `port`, `listen`, `listenAddressIPv4`, `listenAddressIPv6` and
# `whitelist`. It symlinks one config file into /var/lib and passes five CLI
# flags. It has no notion of the other 46 config.yaml keys, no accounts, no
# secrets, no pinned plugins, and no way to keep a rendered config from being
# rewritten at runtime.
#
# This module is the complete replacement for it, under a name that cannot
# collide. Use one or the other — they both own `systemd.services.sillytavern`,
# so enabling both would merge two units into one.
#
# ── The shape of this file ────────────────────────────────────────────────────
#
# There are exactly three option groups here, and the split is deliberate:
#
#   package     which build of the server to run
#   config      EVERY key in SillyTavern's `config.yaml`, one Nix option each,
#               with upstream's own default value
#   cli         EVERY flag the server's yargs parser accepts
#
# `config` is complete, not a curated subset. `config.yaml` is 396 lines and 51
# top-level keys, all of which are operator concerns rather than end-user
# settings (the end-user half lives in `settings.json` inside the data root and
# is not a Nix concern — see docs/options.md). Leaving any key out would mean a
# user who needs it has to abandon Nix for one file, which is the failure mode
# this project exists to avoid.
#
# The defaults below are transcribed from `default/config.yaml` at the pinned
# version, and `lib/tests.nix` contains a check that renders this tree back to
# YAML and asserts it parses to exactly the upstream document. A key added
# upstream without being added here fails `nix flake check` rather than silently
# doing nothing.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  # The typed option tree for the `settings.json` UI surfaces.
  #
  # Built from `lib/settings-inventory.json`, which is DERIVED from upstream's
  # own source by `scripts/extract_settings_inventory.mjs` — so the option
  # tree and the settings-key guard are the same knowledge, not two lists.
  settingsTree = import ../lib/settings-tree.nix {
    inherit lib;
    inventory = builtins.fromJSON (builtins.readFile ../lib/settings-inventory.json);
  };

  # ── Shared submodules ───────────────────────────────────────────────────────

  # `thumbnails.dimensions.<kind>` is `[ width, height ]` — a TWO-ELEMENT LIST,
  # not an object.
  #
  # It was previously a `{ width, height; }` submodule, on the reading that
  # upstream's comment ("Maximum thumbnail dimensions per type [width, height]")
  # describes the shape of the MAPPING rather than of each value. It does not:
  # upstream ships `dimensions: { 'bg': [160, 90], 'avatar': [96, 144], … }`, and
  # the server reads each value as a list —
  #
  #   src/endpoints/image-metadata.js:41-58   getConfigValue('thumbnails.dimensions.bg', [160, 90])
  #   src/endpoints/thumbnails.js:215         const [configWidth, configHeight] = dimensions[type];
  #
  # so the object form renders a config the server rejects as incomplete. Verified
  # against a running 1.19.0: it reports `thumbnails.dimensions.bg.0` and `.1` as
  # missing keys, `getThumbnailResolution()` returns 0 instead of 14400, and the
  # destructuring throws `TypeError: object is not iterable` — thumbnail
  # generation fails for every image, on a DEFAULT configuration.
  #
  # `types.listOf` keeps the pair typed (two positive ints) and renders as the
  # `[160, 90]` flow sequence upstream uses. Note lib/default.nix's renderer
  # already documented this exact case.
  dimensionPair = types.listOf types.ints.positive;

  # A `requestOverrides` entry. Upstream documents the shape but ships `[]`, so
  # this submodule is transcribed from the comment block in config.yaml rather
  # than from a live example.
  requestOverride = types.submodule {
    options = {
      hosts = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "example.com"
          "127.0.0.1:5001"
        ];
        description = ''
          Hosts this override applies to. Upstream is explicit that the host
          includes the port when it is not the default (80 or 443).
        '';
      };
      headers = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          "Content-Type" = "application/json";
          "User-Agent" = "\"Googlebot/2.1 (+http://www.google.com/bot.html)\"";
        };
        description = "Headers added to requests matching `hosts`.";
      };
    };
  };

  # Resource caps for the systemd unit. All null = no cap.
  # `types.int` no longer exists in nixpkgs, so the signed 32-bit integer type is spelled
  # out as an explicit range. That is also more honest than an unbounded integer
  # for these values: they are all small counters, and a typo producing 10^12
  # should be a type error rather than a service that never times out.
  int32 = types.ints.between (-2147483648) 2147483647;

  # A JSON OBJECT. `types.anything` accepts any value at all — nested attrsets,
  # lists, scalars — so `attrsOf anything` type-checks the level the caller
  # actually writes and leaves the rest of the tree to JSON itself.
  #
  # Deliberately NOT one option per leaf. A real `settings.json` from SillyTavern
  # 1.19.0 is 19 top-level keys, five levels deep, ~300 leaves (`power_user`
  # alone has 83), and it changes shape every few upstream releases. Enumerating
  # those in NixOS options would break the build each time upstream adds a field,
  # and would be unusable for the ones nobody enumerated.
  jsonObject = types.attrsOf types.anything;

  # The partial preset tree a model layer can carry. Each bucket mirrors the
  # corresponding `presets.*` bucket, but a layer is a DELTA: it is deep-merged
  # over the layer above it, so a model layer can set one sampling value
  # without restating the other hundred.
  modelLayerPresets = types.submodule {
    options = {
      openai = mkOption {
        type = jsonObject;
        default = { };
        description = "Chat Completion preset fields (sampling, `extensions`, …).";
      };
      textGeneration = mkOption {
        type = jsonObject;
        default = { };
        description = "Text Completion preset fields.";
      };
      instruct = mkOption {
        type = jsonObject;
        default = { };
        description = "Instruct template fields.";
      };
      context = mkOption {
        type = jsonObject;
        default = { };
        description = "Context template fields.";
      };
      sysprompt = mkOption {
        type = jsonObject;
        default = { };
        description = "System prompt fields.";
      };
      reasoning = mkOption {
        type = jsonObject;
        default = { };
        description = "Reasoning template fields.";
      };
    };
  };

  # The payload of a seeded file, TAGGED, so a Nix store path and a JSON string
  # can never be silently confused for each other. Exactly one of the two must be
  # set; `modules/assertions.nix` enforces that.
  #
  # The tag is worth the extra typing. Presets are JSON *arrays* (`instruct/`,
  # `TextGen Settings/`, …), themes and world books are objects, and a theme is
  # small enough that people will reach for a store path — an untagged union
  # would have to guess which a bare string means.
  jsonFileContent = types.submodule ({ name, ... }: {
    options = {
      json = mkOption {
        type = types.anything;
        default = null;
        example = literalExpression ''[ { identifier = "deepseek"; name = "DeepSeek"; } ]'';
        description = "A JSON value written verbatim. Objects, arrays and scalars are all accepted.";
      };      path = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "./my-theme.json";
        description = ''
          A file copied verbatim from the store. Use this for presets too large
          to inline.

          May also be a DIRECTORY, in which case the tree is copied whole —
          which is the only way to seed a per-account UI extension, since
          `extensions/<name>/` is a directory of JS plus a `manifest.json`
          rather than a single file:

            files.byUser.seanc."extensions/my-ext".path = ./my-ext/;

          An existing target directory is left entirely alone under
          `seedPolicy = "missing"`, so an extension the user edited through the
          UI is theirs. Under `"overwrite"` the tree is re-copied file by file,
          but files the source no longer contains are NOT deleted: this is a
          seed, not a sync.
        '';
      };
      policy = mkOption {
        type = types.nullOr (types.enum [ "missing" "overwrite" ]);
        default = null;
        example = "overwrite";
        description = ''
          Overrides `seedPolicy` for this one file.

          `null` (the default) inherits the global `seedPolicy`.

          Reach for `overwrite` on a file the server would otherwise create for
          itself, so editing this option keeps taking effect. `customCss` and
          the four `errorPages` do exactly this: content seeding copies a
          placeholder into `_css/user.css` and `_errors/` once and never
          touches them again, so under `missing` your value would be written
          once and then frozen, and later edits would silently do nothing.

          Set it per file rather than flipping `seedPolicy` globally when only
          one entry needs to be authoritative — `overwrite` on a
          `settings.json` a user edits in the UI would fight them.
        '';
      };
      mode = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "0644";
        description = ''
          Octal file mode as a 4-digit STRING, e.g. `"0644"`.

          `null` (the default) is `0600`, owner-only, which is right for
          `settings.json` and every other seeded JSON — the per-user router
          authenticates before serving any of it, but a world-readable API key
          on disk is still a world-readable API key.

          Widen it only for a file the server hands to an UNAUTHENTICATED
          visitor. That is exactly the `customCss` / `errorPages` case, both of
          which set `"0644"` here.

          A string, not an integer, because that is what a Nix string literal
          carries and because `mode = 6440` would otherwise be silently read as
          DECIMAL 6440 rather than octal. `scripts/st_seed_files.py` rejects a
          string that is not exactly four octal digits, so this fails loudly
          rather than chmod-ing something absurd. The same check is repeated at
          evaluation time in modules/assertions.nix, so a bad value is caught by
          `nixos-rebuild` instead of at service start.
        '';
      };
    };
  });

  # ── Named-profile buckets ───────────────────────────────────────────────────
  #
  # One option per kind of named, saved item the UI offers in a dropdown.
  # They all have the same shape — a map from NAME to the item's content — and
  # they differ only in which per-user directory upstream reads them from and
  # where the dropdown's LABEL comes from.
  #
  # The label is the part that is easy to get wrong, and getting it wrong is
  # silent: the item appears in the dropdown as "undefined", or two items
  # collide under one label. So the two cases are spelled out per bucket
  # rather than left to the reader:
  #
  #   * The dropdown label is the FILE NAME — the key you write here.
  #   * The dropdown label is a `name` field INSIDE the JSON. The module
  #     fills that field in from the key when it is missing, and refuses a
  #     value that disagrees with the key.
  #
  # The per-bucket facts are not guessed: each one cites the upstream source
  # that establishes it. `lib/default.nix` carries the directory mapping, and
  # the same facts are asserted by the `presets` check in `lib/tests.nix`.
  presetBucket =
    {
      directory,
      labelFrom,
      example,
      extra,
    }:
    mkOption {
      type = types.attrsOf jsonFileContent;
      default = { };
      example = literalExpression example;
      description = ''
        Named items of this kind, keyed by NAME.

        Each is seeded as one JSON file per name, into the account's
        `${directory}` directory — which is where upstream reads this kind of
        item from.

        ${labelFrom}

        ${extra}

        The key is the item's name. It becomes the file name, with `.json`
        appended, so it must not contain a path separator.

        Use `{ json = …; }` for a value written here, or `{ path = …; }` for a
        file copied from the store — the same two forms `files` uses. The
        per-entry `policy` and `mode` knobs work here too.
      '';
    };

  presetBucketType = types.submodule ({ name, ... }: {
    options = {
      textGeneration = presetBucket {
        directory = "TextGen Settings";
        labelFrom = ''
          The dropdown label is the FILE NAME, so the key is what the user
          sees in the list. Upstream reads these from the directory listing
          (`src/endpoints/settings.js`, `readPresetsFromDirectory` with
          `removeFileExtension`).
        '';
        extra = ''
          The Text Completion presets — Settings → AI Response Configuration →
          "Presets". Each one is a flat set of sampler and generation
          parameters, and upstream ships a dozen of them
          (`default/content/presets/textgen/`).
        '';
        example = ''
          {
            "My Preset" = {
              json = {
                temperature = 0.9;
                top_p = 0.95;
              };
            };
          }
        '';
      };

      openai = presetBucket {
        directory = "OpenAI Settings";
        labelFrom = ''
          The dropdown label is the FILE NAME, so the key is what the user
          sees in the list. Upstream reads these from the directory listing
          (`src/endpoints/settings.js`, `readPresetsFromDirectory` with
          `removeFileExtension`).
        '';
        extra = ''
          The AI Response Configuration presets — the ones that carry the
          model, the custom URL and the sampling parameters for an
          OpenAI-compatible provider.
        '';
        example = ''
          {
            "My Preset" = {
              json = {
                openai_model = "gpt-5.2";
                openai_max_context = 131072;
                stream_openai = true;
              };
            };
          }
        '';
      };

      novel = presetBucket {
        directory = "NovelAI Settings";
        labelFrom = ''
          The dropdown label is the FILE NAME, so the key is what the user
          sees in the list. Upstream reads these from the directory listing
          (`src/endpoints/settings.js`, `readPresetsFromDirectory` with
          `removeFileExtension`).
        '';
        extra = ''
          The NovelAI presets — Settings → AI Response Configuration, with
          NovelAI selected as the backend.
        '';
        example = ''
          {
            "My Preset" = {
              json = {
                temperature = 1.1;
                repetition_penalty = 2.1;
              };
            };
          }
        '';
      };

      kobold = presetBucket {
        directory = "KoboldAI Settings";
        labelFrom = ''
          The dropdown label is the FILE NAME, so the key is what the user
          sees in the list. Upstream reads these from the directory listing
          (`src/endpoints/settings.js`, `readPresetsFromDirectory` with
          `removeFileExtension`).
        '';
        extra = ''
          The KoboldAI Classic presets. `koboldhorde` uses the same
          directory — `src/endpoints/presets.js` maps both API ids to it.
        '';
        example = ''
          {
            "My Preset" = {
              json = {
                temperature = 0.8;
                top_k = 40;
              };
            };
          }
        '';
      };

      instruct = presetBucket {
        directory = "instruct";
        labelFrom = ''
          The dropdown label is a `name` field INSIDE the JSON, not the file
          name — `public/scripts/preset-manager.js` computes
          `preset_names = presets.map(x => x.name)` for this group. The
          module fills that field in from the key when it is missing, so a
          preset can never appear as "undefined", and it refuses a value
          that disagrees with the key.
        '';
        extra = ''
          The Instruct templates — the prompt-format templates that say how
          the model should be talked to. Upstream calls this group
          "Advanced Formatting", together with `context`, `sysprompt` and
          `reasoning`.
        '';
        example = ''
          {
            "Alpaca" = {
              json = {
                identifier = "alpaca";
                input_sequence = "<|user|>";
                output_sequence = "<|assistant|>";
              };
            };
          }
        '';
      };

      context = presetBucket {
        directory = "context";
        labelFrom = ''
          The dropdown label is a `name` field INSIDE the JSON, not the file
          name — `public/scripts/preset-manager.js` computes
          `preset_names = presets.map(x => x.name)` for this group. The
          module fills that field in from the key when it is missing, so a
          preset can never appear as "undefined", and it refuses a value
          that disagrees with the key.
        '';
        extra = ''
          The Context templates — where the story text, the example
          separator and the chat-start marker are assembled.
        '';
        example = ''
          {
            "ChatML" = {
              json = {
                story_string = "{{trim}}";
                example_separator = "";
                chat_start = "<|im_start|>";
              };
            };
          }
        '';
      };

      sysprompt = presetBucket {
        directory = "sysprompt";
        labelFrom = ''
          The dropdown label is a `name` field INSIDE the JSON, not the file
          name — `public/scripts/preset-manager.js` computes
          `preset_names = presets.map(x => x.name)` for this group. The
          module fills that field in from the key when it is missing, so a
          preset can never appear as "undefined", and it refuses a value
          that disagrees with the key.
        '';
        extra = ''
          The system-prompt templates — Settings → AI Response
          Configuration → Prompt Manager.
        '';
        example = ''
          {
            "Roleplay - Detailed" = {
              json = {
                content = "Write {{char}} as {{user}} would.";
                post_history = "";
              };
            };
          }
        '';
      };

      reasoning = presetBucket {
        directory = "reasoning";
        labelFrom = ''
          The dropdown label is a `name` field INSIDE the JSON, not the file
          name — `public/scripts/preset-manager.js` computes
          `preset_names = presets.map(x => x.name)` for this group. The
          module fills that field in from the key when it is missing, so a
          preset can never appear as "undefined", and it refuses a value
          that disagrees with the key.
        '';
        extra = ''
          The reasoning templates — the prefix, suffix and separator a
          reasoning model is wrapped in (`<think>…</think>` and friends).
        '';
        example = ''
          {
            "Think XML" = {
              json = {
                prefix = "<think>\n";
                suffix = "\n</think>";
                separator = "\n\n";
              };
            };
          }
        '';
      };

      themes = presetBucket {
        directory = "themes";
        labelFrom = ''
          The dropdown label is a `name` field INSIDE the JSON, not the file
          name — `public/scripts/power-user.js` builds the theme list from
          `theme.name`. The module fills that field in from the key when it
          is missing, so a theme can never appear as "undefined", and it
          refuses a value that disagrees with the key.
        '';
        extra = ''
          The UI themes — the colour palette, the blur, the font scale and
          the rest of the appearance. Upstream ships a dozen
          (`default/content/themes/`).

          A theme is the closest thing to a "profile" in SillyTavern: it is
          the whole look of the interface in one named, importable,
          exportable document.
        '';
        example = ''
          {
            "Azure" = {
              json = {
                blur_strength = 11;
                main_text_color = "rgba(171, 198, 223, 1)";
              };
            };
          }
        '';
      };

      movingUi = presetBucket {
        directory = "movingUI";
        labelFrom = ''
          The dropdown label is a `name` field INSIDE the JSON, not the file
          name — `public/scripts/power-user.js` builds the list from
          `movingUIPreset.name`. The module fills that field in from the key
          when it is missing, so a layout can never appear as "undefined",
          and it refuses a value that disagrees with the key.
        '';
        extra = ''
          The Moving UI layouts — the saved positions of the draggable
          interface elements.
        '';
        example = ''
          {
            "Default" = {
              json = {
                movingUIState = { };
              };
            };
          }
        '';
      };

      quickReplies = presetBucket {
        directory = "QuickReplies";
        labelFrom = ''
          The dropdown label is a `name` field INSIDE the JSON, not the file
          name — the quick-reply extension keys its set list by the set's
          own `name`
          (`public/scripts/extensions/quick-reply/index.js`). The module
          fills that field in from the key when it is missing, so a set can
          never appear as "undefined", and it refuses a value that
          disagrees with the key.
        '';
        extra = ''
          The quick-reply sets — the named lists of canned replies and
          slash commands.
        '';
        example = ''
          {
            "My Set" = {
              json = {
                quickReplyEnabled = true;
                quickReplySlots = [
                  {
                    label = "HELP";
                    mes = "/?";
                    enabled = true;
                  }
                ];
              };
            };
          }
        '';
      };

      worlds = presetBucket {
        directory = "worlds";
        labelFrom = ''
          The dropdown label is the FILE NAME, so the key is what the user
          sees in the list. The server sends the World Info list as
          `world_names`, derived from the file names
          (`src/endpoints/settings.js`).
        '';
        extra = ''
          The World Info books — the lorebooks, each one a set of keyword
          entries injected into the prompt.
        '';
        example = ''
          {
            "Lore" = {
              json = {
                entries = {
                  "1" = {
                    uid = 1;
                    key = "keyword";
                    content = "the thing they never talk about";
                  };
                };
              };
            };
          }
        '';
      };

      workflows = presetBucket {
        directory = "user/workflows";
        labelFrom = ''
          The dropdown label is the FILE NAME, so the key is what the user
          sees in the list — upstream lists the directory
          (`getComfyWorkflows` in `src/endpoints/stable-diffusion.js`).
        '';
        extra = ''
          The saved ComfyUI workflows, for the image-generation extension.

          Note that the ComfyUI backend's own dropdown is fed by the ComfyUI
          SERVER, not by these files: these are the workflows saved locally,
          which is where the extension's import and save actions put them.
        '';
        example = ''
          {
            "SDXL" = {
              json = {
                "3" = {
                  class_type = "KSampler";
                };
              };
            };
          }
        '';
      };
    };
  });

  # One entry in an account's `secrets.json`: a provider API key, sourced from a
  # file. See the `secrets.byUser` option for why the value is a path and never a
  # literal.
  secretEntry = types.submodule ({ name, ... }: {
    options = {
      value = mkOption {
        type = types.path;
        example = literalExpression "config.age.secrets.openai_api_key.path";
        description = ''
          File whose CONTENTS are the API key. The value itself is never stored
          in Nix: only this path is, and the bytes are read at activation.

          Use `config.age.secrets.<name>.path` (decrypted to `/run/agenix/<name>`)
          so the key is encrypted at rest in the repo and readable only by the
          service account.
        '';
      };
      label = mkOption {
        type = types.str;
        default = name;
        example = "work";
        description = "Human-readable label shown in the UI's key manager. Defaults to the key name.";
      };
    };
  });

  hardware = types.submodule {
    options = {
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "4G";
        description = "systemd MemoryMax — hard cgroup cap; the unit is OOM-killed above it. null = unlimited.";
      };
      memoryHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "3G";
        description = "systemd MemoryHigh — soft throttle target. null = unlimited.";
      };
      memorySwapMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "1G";
        description = "systemd MemorySwapMax. null = unlimited.";
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "200%";
        description = "systemd CPUQuota, as a percentage of one core. null = unlimited.";
      };
      nice = mkOption {
        type = types.nullOr int32;
        default = null;
        description = "systemd Nice level. null = leave the default.";
      };
      ioWeight = mkOption {
        type = types.nullOr int32;
        default = null;
        description = "systemd IOWeight (1-10000). null = leave the default.";
      };
    };
  };

  # One pinned plugin or extension.
  #
  # Both are git repositories cloned into the PACKAGE, not into the data root —
  # upstream keeps them under the server directory (`./plugins` and
  # `./public/scripts/extensions/third-party`), and this module ships them as
  # `fetchgit` store paths so they are pinned, reproducible and read-only. See
  # the `rev`-is-required assertion in modules/assertions.nix for why a branch
  # name is not accepted.
  gitPackage = types.submodule {
    options = {
      url = mkOption {
        type = types.str;
        example = "https://github.com/example/sillytavern-plugin.git";
        description = "Git URL to clone from.";
      };
      rev = mkOption {
        type = types.str;
        example = "refs/tags/v1.2.3";
        description = ''
          Git revision to pin — a full commit SHA or a tag. Deliberately
          required rather than defaulting to a branch: a plugin that silently
          moves is a plugin whose behaviour changes under a running service, and
          a store path cannot be rebuilt reproducibly from a branch name.
        '';
      };
      submodules = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to fetch git submodules. Upstream clones plugins with
          `depth: 1` and without `--recurse-submodules`, so the built-in
          installer ignores them; this module can either match that or do the
          more useful thing.
        '';
      };
      # `fetchgit`'s own knobs, for the rare plugin that needs them.
      fetchgitExtra = mkOption {
        type = types.attrs;
        default = { };
        example = literalExpression ''
          {
            fetchSubmodules = true;
            leaveDotGit = false;
          }
        '';
        description = "Extra attributes passed straight to `builtins.fetchGit`.";
      };
    };
  };

  # One account to seed into the server's user database.
  #
  # `passwordFile` rather than `password` because the hash has to be computed
  # from the plaintext at activation time — see scripts/st_seed_users.py and the
  # "Why the seeder is Python" note in modules/config.nix.
  user = types.submodule {
    options = {
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Sean";
        description = ''
          Display name shown in the UI. Defaults to the attribute name, which
          SillyTavern uses as the `handle` and as the directory name.
        '';
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "\"\${agenix}/sillytavern-admin\"";
        description = ''
          File holding the account's plaintext password. Read at activation and
          scrypt-hashed; the plaintext never enters the Nix store, the unit
          file, or `ps` output.
        '';
      };
      admin = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this account may manage other accounts. Note that the server's
          built-in `default-user` is created automatically with `admin: true`
          and an EMPTY password, which is why the module refuses to leave it
          as the only account (see modules/assertions.nix).
        '';
      };
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Whether the account can log in.";
      };
    };
  };

in
{
  options.services.sillytavern-nixos = {
    enable = mkEnableOption "the SillyTavern LLM front-end and proxy server";

    package = mkOption {
      type = types.package;
      default = throw ''
        services.sillytavern-nixos.package: no package was supplied.

        The module normally sets this itself (see modules/sillytavern.nix),
        so reaching this message means you imported the option and config files
        directly rather than through the flake's `nixosModules`.

        Set it explicitly:

          services.sillytavern-nixos.package =
            inputs.sillytavern.packages.''${system}.sillytavern;

        Do NOT fall back to a bare `pkgs.sillytavern`. nixos-unstable ships a
        package of the same name and the same version whose entry point is
        `src/server-global.js`; that forces global mode, in which SillyTavern
        ignores --configPath and --dataRoot and stores its data under the
        service account's ~/.local/share instead of the systemd StateDirectory.
      '';
      # NOT `pkgs.sillytavern`. That is nixpkgs' package of the same name —
      # the one the error message above warns against — and it is not what the
      # module uses. The default is the module's own build of THIS
      # repository, from the filtered source, on the CONSUMER's package set.
      # See modules/sillytavern.nix and lib/source.nix.
      defaultText = literalExpression ''"this flake's own build of the SillyTavern source"'';
      description = "The SillyTavern package to run.";
    };

    # ── The data root ─────────────────────────────────────────────────────────

    # Derived, not set directly: `StateDirectory = "sillytavern"` gives
    # /var/lib/sillytavern, and the module passes that to `--dataRoot`.
    #
    # `stateDirectory` is the knob; `dataRoot` below is the resolved path, and
    # it is PUBLIC so that `nixos-option` and the generated documentation show
    # where the files actually go. It is still derived — modules/config.nix
    # assigns it with `mkDefault`, and modules/assertions.nix refuses any
    # value that is not `/var/lib/${stateDirectory}`, because the unit's only
    # writable directory is the StateDirectory.
    stateDirectory = mkOption {
      type = types.str;
      default = "sillytavern";
      description = ''
        Name of the systemd `StateDirectory`, which becomes the server's
        `--dataRoot`. Everything mutable lives under it: per-user chats,
        characters, settings, uploads, backups, thumbnails, the user key-value
        store, and the webpack cache the server rebuilds on every start.
      '';
    };

    dataRoot = mkOption {
      type = types.str;
      # `internal = true` plus an assignment in modules/config.nix, NOT
      # `readOnly = true` plus a `default`. The readOnly form declares an option
      # that has a default but no definitions, which sends the option system down
      # a merge path that fails inside nixpkgs' `lib/modules.nix` with
      # "attribute 'deprecationMessage' missing" — an error naming the option's
      # TYPE when the real problem is the readOnly-with-no-definitions shape.
      #
      # NOT `internal = true`, though: this is the DATA DIRECTORY — the one
      # option that says where SillyTavern's own files live — and hiding it
      # from `nixos-option` and the generated documentation made it look like
      # the module had no data directory at all.
      default = "/var/lib/sillytavern";
      defaultText = "/var/lib/${config.services.sillytavern-nixos.stateDirectory}";
      description = ''
        The data directory: the root of everything SillyTavern writes.

        It is DERIVED from `stateDirectory`, which is the systemd
        `StateDirectory` — so `/var/lib/sillytavern` by default — and it
        holds every account's chats, characters, settings, uploads, backups,
        thumbnails, the user key-value store, and the webpack cache the server
        rebuilds on every start.

        Changing `stateDirectory` changes this. Setting `dataRoot` to
        something else is REFUSED: the unit's only writable directory is the
        StateDirectory, so a data root outside it would be unwritable, and
        the failure would surface as a service that starts and then cannot
        save anything. Change `stateDirectory` instead.
      '';
    };

    # ── Server identity ───────────────────────────────────────────────────────

    user = mkOption {
      type = types.str;
      default = "sillytavern";
      description = "System user to run the server as.";
    };

    group = mkOption {
      type = types.str;
      default = "sillytavern";
      description = "System group to run the server as.";
    };

    # ── config.yaml ───────────────────────────────────────────────────────────
    #
    # One option per upstream key, in upstream's own order, with upstream's own
    # defaults. `docs/options.md` renders this list.
    config = {
      dataRoot = mkOption {
        type = types.str;
        default = "./data";
        description = ''
          Upstream's own default, kept for fidelity. It is ALWAYS overridden by
          the `--dataRoot` flag the module passes, so this value has no effect
          in the NixOS module; it is here so the rendered config.yaml is a
          complete, honest copy of the upstream document.

          Note that upstream resolves a relative `dataRoot` against the server
          directory, which in a Nix build is a read-only store path — which is
          one of the reasons the module passes the flag rather than relying on
          this.
        '';
      };

      listen = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to listen on all network interfaces.

          This module's default is upstream's (`false`, i.e. loopback only),
          which is the right default for a service that will be reached through
          a reverse proxy or an SSH tunnel. Setting it to `true` on a public
          interface without `enableUserAccounts` or `basicAuthMode` puts an
          unauthenticated LLM proxy on the internet; modules/assertions.nix warns
          about that combination rather than blocking it, because a service on a
          trusted LAN is a legitimate use.
        '';
      };

      listenAddress = {
        ipv4 = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = ''
            Specific IPv4 address to bind when `listen` is true. `"0.0.0.0"` and
            `""` both mean "all IPv4 interfaces".
          '';
        };
        ipv6 = mkOption {
          type = types.str;
          default = "[::]";
          description = ''
            Specific IPv6 address to bind when `listen` is true. Note the BRACKETS:
            the brackets are part of the value, because upstream builds a URL from
            it. `"[::]"` and `""` both mean "all IPv6 interfaces".
          '';
        };
      };

      protocol = {
        ipv4 = mkOption {
          type = types.enum [ "true" "false" "auto" "yes" "no" "on" "off" "1" "0" ];
          default = "true";
          example = "auto";
          description = ''
            Enable the IPv4 protocol. Rendered as upstream's string-or-bool
            hybrid: the server accepts `"auto"` to detect support, and otherwise
            coerces the value through `stringToBool`. The option type is the
            union upstream accepts rather than a plain bool, because `"auto"` has
            no boolean equivalent.
          '';
        };
        ipv6 = mkOption {
          type = types.enum [ "true" "false" "auto" "yes" "no" "on" "off" "1" "0" ];
          default = "false";
          example = "auto";
          description = "Enable the IPv6 protocol. Same string-or-bool hybrid as `protocol.ipv4`.";
        };
      };

      dnsPreferIPv6 = mkOption {
        type = types.bool;
        default = false;
        description = "Prefer AAAA records when resolving outbound hostnames.";
      };

      browserLaunch = {
        enabled = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Open a browser window on server start.

            Upstream defaults this to true because the common case is a desktop
            user running the server by hand. Under systemd there is no session
            bus and no display, so the launch silently fails (and, with
            `browser: "firefox"`, logs a spawn error every start). The NixOS
            module overrides this default to `false`; see modules/config.nix.
          '';
        };
        browser = mkOption {
          type = types.enum [ "default" "firefox" "chrome" "edge" ];
          default = "default";
          description = "Which browser to launch. Only meaningful when `browserLaunch.enabled` is true. Not supported on Android.";
        };
        hostname = mkOption {
          type = types.str;
          default = "auto";
          example = "st.example.com";
          description = ''
            Hostname used when opening the browser. `"auto"` lets the server
            choose based on which protocols it ended up listening on.
          '';
        };
        port = mkOption {
          type = int32;
          default = -1;
          example = 8000;
          description = "Port used when opening the browser. `-1` means the server's own port.";
        };
        avoidLocalhost = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Use `127.0.0.1`/`[::1]` rather than `localhost` when `hostname` is
            `"auto"`. Set this if `localhost` does not resolve on your host.
          '';
        };
      };

      port = mkOption {
        type = types.port;
        default = 8000;
        description = ''
          TCP port to listen on. This is the port a reverse proxy should point
          at, and the one `services.sillytavern-nixos.openFirewall` opens.
        '';
      };

      heartbeatInterval = mkOption {
        type = types.ints.unsigned;
        default = 0;
        example = 30;
        description = ''
          Seconds between heartbeat file updates; 0 disables it.

          SillyTavern ships `src/healthcheck.js`, a standalone script that exits
          non-zero when `<dataRoot>/heartbeat.json` has not been touched within
          two intervals. Setting this to a non-zero value makes that script
          usable, and the module wires it into the unit as an `ExecStartPost`
          probe. Primarily a Docker healthcheck mechanism upstream, but it works
          equally well as a systemd start-time canary.
        '';
      };

      enableKeepAlive = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable HTTP/HTTPS keep-alive globally. Upstream notes that disabling
          this restores older Node behaviour, which "can help if ECONNRESET and
          other network errors occur".
        '';
      };

      ssl = {
        enabled = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Serve over HTTPS/TLS directly from SillyTavern.

            Normally you do NOT want this: put a reverse proxy in front and let
            it terminate TLS. SillyTavern's own TLS is fine but it means
            certificates, renewal and cipher policy become your problem. See
            docs/installing.md.
          '';
        };
        certPath = mkOption {
          type = types.str;
          default = "./certs/cert.pem";
          description = ''
            Path to the certificate, resolved by the server relative to its own
            directory unless absolute. Inside a Nix store path the server
            directory is read-only, so an absolute path outside the store — via
            the `ssl.certFile` / `ssl.keyFile` convenience options — is what you
            want.
          '';
        };
        keyPath = mkOption {
          type = types.str;
          default = "./certs/privkey.pem";
          description = "Path to the private key. Same store-path caveat as `ssl.certPath`.";
        };
        keyPassphrase = mkOption {
          type = types.str;
          default = "";
          description = ''
            Passphrase for the private key.

            Leave empty. This value is rendered into a Nix store file, which is
            world-readable and permanent — use `ssl.keyPassphraseFile` instead,
            which is passed to the server as `SILLYTAVERN_SSL_KEYPASSPHRASE`
            (the mechanism upstream's own comment recommends) and never reaches
            the store.
          '';
        };
      };

      whitelistMode = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Require the connecting IP to appear in `whitelist`.

          `true` by default upstream. Note that with `listen = false` the server
          only accepts loopback connections anyway, so whitelisting is about
          defence in depth rather than the primary control; `enableUserAccounts`
          is the primary one.
        '';
      };

      enableForwardedWhitelist = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Also check the IP in the headers enabled under `forwardedHeaders` when
          whitelisting.

          Only correct behind a reverse proxy you control. With it on and no
          proxy in front, a client can put an arbitrary `X-Forwarded-For` in its
          request and match any entry in `whitelist`.
        '';
      };

      whitelist = mkOption {
        type = types.listOf types.str;
        default = [
          "::1"
          "127.0.0.1"
        ];
        example = [
          "::1"
          "127.0.0.1"
          "192.168.1.0/24"
          "st.example.com"
        ];
        description = ''
          Allowed IPs. Accepts bare addresses, CIDR ranges, and hostnames —
          upstream logs and ignores entries it cannot parse, so a typo is a
          silent hole rather than an error.
        '';
      };

      whitelistDockerHosts = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Auto-whitelist Docker host and gateway addresses.

          Harmless under NixOS — there is no Docker bridge here — but the module
          sets it to `false` by default because "allow the Docker subnet" has no
          meaning outside a container and its presence in a rendered config is
          confusing. See modules/config.nix.
        '';
      };

      basicAuthMode = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Require HTTP basic authentication on every endpoint.

          A blunt instrument, and a bad fit for a browser UI (the browser's basic
          auth dialog is not a login page). `enableUserAccounts` is what you want
          for SillyTavern; keep this for protecting an unauthenticated instance's
          API, or when `perUserBasicAuth` is doing the work.
        '';
      };

      basicAuthUser = {
        username = mkOption {
          type = types.str;
          default = "user";
          description = "Username for `basicAuthMode`.";
        };
        password = mkOption {
          type = types.str;
          default = "password";
          description = ''
            Password for `basicAuthMode`.

            Upstream ships `password` here, which is fine for a loopback-only dev
            instance and alarming anywhere else. Use `basicAuthUser.passwordFile`
            instead; the module refuses a non-default plaintext password set here
            (see modules/assertions.nix), because a store file is exactly the
            wrong place for one.
          '';
        };
      };

      enableCorsProxy = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Mount the CORS proxy endpoint, which lets the browser talk to arbitrary
          third-party APIs through the server.

          This is a general-purpose SSRF primitive: it will fetch any URL the
          server can reach. Pair it with `privateAddressWhitelist.enabled` if you
          enable it at all.
        '';
      };

      cors = {
        enabled = mkOption {
          type = types.bool;
          default = true;
          description = "Apply CORS headers to all routes.";
        };
        origin = mkOption {
          type = types.listOf types.str;
          default = [ "null" ];
          example = [ "https://st.example.com" ];
          description = ''
            Allowed origins. The literal string `"null"` matches the browser's
            default `file://` origin; `"*"` allows any.
          '';
        };
        methods = mkOption {
          type = types.listOf types.str;
          default = [ "OPTIONS" ];
          example = [
            "OPTIONS"
            "POST"
            "GET"
          ];
          description = "Allowed HTTP methods.";
        };
        allowedHeaders = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Allowed request headers. Empty = no restriction beyond the CORS default.";
        };
        exposedHeaders = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Response headers exposed to the browser.";
        };
        credentials = mkOption {
          type = types.bool;
          default = false;
          description = "Allow credentials (cookies, Authorization) cross-origin.";
        };
        maxAge = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = null;
          description = "Preflight cache max-age in seconds. null = no explicit max-age.";
        };
      };

      requestProxy = {
        enabled = mkOption {
          type = types.bool;
          default = false;
          description = "Route all outgoing HTTP/HTTPS requests through a proxy.";
        };
        url = mkOption {
          type = types.str;
          default = "socks5://username:password@example.com:1080";
          description = ''
            Proxy URL. Upstream accepts http, https, socks, socks5, socks4 and pac.

            Upstream's default value contains a placeholder credential, which is
            also a reminder that this option is rendered into a Nix store file.
            Use `requestProxy.urlFile` for a real proxy.
          '';
        };
        bypass = mkOption {
          type = types.listOf types.str;
          default = [
            "localhost"
            "127.0.0.1"
          ];
          description = "Hosts reached directly rather than through the proxy.";
        };
      };

      enableUserAccounts = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the multi-user login system.

          This is the access control that actually matters for a shared
          instance. Combined with `services.sillytavern-nixos.users` it lets accounts be
          declared in Nix and seeded at activation.
        '';
      };

      enableDiscreetLogin = mkOption {
        type = types.bool;
        default = false;
        description = "Hide the user list on the login screen, so accounts must be typed.";
      };

      perUserBasicAuth = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use each account's own credentials for HTTP basic auth, instead of the
          single `basicAuthUser` pair. Requires both `basicAuthMode` and
          `enableUserAccounts`.
        '';
      };

      sso = {
        autheliaAuth = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Trust Authelia's `Remote-User` header for automatic login. Requires
            Authelia in front of SillyTavern, and `sso.trustedProxies` to cover
            the proxy's address.
          '';
        };
        authentikAuth = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Trust authentik's forwarded-identity header for automatic login.
            Requires authentik in front, and `sso.trustedProxies` to cover it.
          '';
        };
        trustedProxies = mkOption {
          type = types.listOf types.str;
          default = [
            "::1"
            "127.0.0.1"
          ];
          example = [
            "127.0.0.1"
            "192.168.1.1"
            "10.0.0.0/8"
          ];
          description = ''
            Proxies whose identity headers are trusted. Supports wildcards and
            CIDR. `["*"]` trusts everything and upstream marks it NOT RECOMMENDED.

            This is a genuine authentication boundary: an entry here lets that
            address assert who anyone is.
          '';
        };
      };

      hostWhitelist = {
        enabled = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Reject requests whose `Host` header is not in `hostWhitelist.hosts`.

            Cheap protection against DNS rebinding and Host-header attacks, and
            worth enabling on any non-loopback bind.
          '';
        };
        scan = mkOption {
          type = types.bool;
          default = true;
          description = "Scan incoming requests for Host-header spoofing.";
        };
        hosts = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "st.example.com"
            ".trycloudflare.com"
          ];
          description = ''
            Allowed hosts. Do NOT include `localhost` or bare IPs — upstream
            already treats those as safe, and listing them only widens the
            surface. A leading dot makes a subdomain pattern.
          '';
        };
      };

      privateAddressWhitelist = {
        enabled = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Block server-side requests that resolve to private IP ranges, as an
            SSRF control. Upstream recommends this whenever the instance is
            reachable by untrusted users — which is also when `enableCorsProxy`
            becomes dangerous.
          '';
        };
        allowUnresolvedHosts = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Allow requests to hosts that do not resolve, instead of blocking
            them. Convenient on a network without DNS, and it reintroduces the
            hole SSRF protection closes.
          '';
        };
        log = {
          blockedRequests = mkOption {
            type = types.bool;
            default = true;
            description = "Log blocked requests at warn level.";
          };
          allowedRequests = mkOption {
            type = types.bool;
            default = false;
            description = "Log allowed requests at info level. Very noisy.";
          };
        };
        allowedRanges = mkOption {
          type = types.listOf types.str;
          default = [
            "127.0.0.0/8"
            "::1/128"
          ];
          description = "Private ranges permitted, in CIDR or wildcard form.";
        };
      };

      sessionTimeout = mkOption {
        type = int32;
        default = -1;
        description = ''
          Session lifetime in seconds. Positive = expire after that much
          inactivity; 0 = session cookie dies with the browser; negative =
          never expire (upstream uses a 400-day cookie cap).
        '';
      };

      disableCsrfProtection = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Disable CSRF protection. Upstream marks this NOT RECOMMENDED and so
          does this project: it exists because a reverse proxy that rewrites the
          Origin header can break legitimate requests, and it is the wrong fix for
          that. See docs/troubleshooting.md.
        '';
      };

      securityOverride = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Skip the startup security checks — the ones that abort when the server
          is publicly reachable with no authentication. Upstream marks this NOT
          RECOMMENDED.
        '';
      };

      logging = {
        enableAccessLog = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Write an access log.

            The log is a FILE at `<dataRoot>/access.log`
            (`src/middleware/accessLogWriter.js:10`), not in the server
            directory — so under this module it needs no redirection and lands
            in the state directory, which `StateDirectory` keeps writable.

            Each newly-seen client IP is also logged to the journal at info
            level; `logging.minLogLevel` controls that.
          '';
        };
        minLogLevel = mkOption {
          type = types.ints.unsigned;
          default = 0;
          description = "Minimum level printed to the terminal. 0 = DEBUG, 1 = INFO, 2 = WARN, 3 = ERROR.";
        };
      };

      rateLimiting = {
        preferRealIpHeader = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Identify the client by the headers in `forwardedHeaders` rather than
            the socket address, for rate limiting. Only correct behind a proxy
            you control — otherwise every client shares one address and the
            limit is global.
          '';
        };
        basicAuthMaxAttempts = mkOption {
          type = types.ints.unsigned;
          default = 5;
          description = "Failed basic-auth attempts before rate limiting kicks in. 0 = no limit.";
        };
        accountsLoginMaxAttempts = mkOption {
          type = types.ints.unsigned;
          default = 5;
          description = "Failed login attempts before rate limiting. 0 = no limit.";
        };
        accountsRecoverMaxAttempts = mkOption {
          type = types.ints.unsigned;
          default = 5;
          description = "Failed account-recovery attempts before rate limiting. 0 = no limit.";
        };
        accountsResetMaxAttempts = mkOption {
          type = types.ints.unsigned;
          default = 5;
          description = "Failed password-reset attempts before rate limiting. 0 = no limit.";
        };
      };

      forwardedHeaders = {
        xRealIp = mkOption {
          type = types.bool;
          default = true;
          description = "Trust `X-Real-IP` for the client's real address.";
        };
        xForwardedFor = mkOption {
          type = types.bool;
          default = true;
          description = "Trust `X-Forwarded-For` (first entry) for the client's real address.";
        };
        cfConnectingIp = mkOption {
          type = types.bool;
          default = false;
          description = "Trust `CF-Connecting-IP`, for Cloudflare Tunnels.";
        };
      };

      backups = {
        allowFullDataBackup = mkOption {
          type = types.bool;
          default = true;
          description = "Let users download a full archive of their data through the UI.";
        };
        common = {
          numberOfBackups = mkOption {
            type = int32;
            default = 50;
            description = "Backups kept per chat and per settings file.";
          };
        };
        chat = {
          enabled = mkOption {
            type = types.bool;
            default = true;
            description = "Back up chats automatically as they are written.";
          };
          checkIntegrity = mkOption {
            type = types.bool;
            default = true;
            description = "Verify chat file integrity before saving.";
          };
          maxTotalBackups = mkOption {
            type = int32;
            default = -1;
            description = "Total chat backups kept per user. -1 = keep all.";
          };
          throttleInterval = mkOption {
            type = types.ints.unsigned;
            default = 10000;
            description = "Milliseconds between chat backups for one user.";
          };
        };
      };

      thumbnails = {
        enabled = mkOption {
          type = types.bool;
          default = true;
          description = "Generate thumbnails for avatars, backgrounds and personas.";
        };
        format = mkOption {
          type = types.enum [ "jpg" "png" ];
          default = "jpg";
          description = ''
            Image format for new thumbnails. `"png"` keeps transparency at
            roughly double the file size. Only affects NEW thumbnails — clear the
            user's `thumbnails/` directory to regenerate existing ones.
          '';
        };
        quality = mkOption {
          type = types.ints.between 1 100;
          default = 95;
          description = "JPEG quality for new thumbnails.";
        };
        dimensions = {
          bg = mkOption {
            type = dimensionPair;
            default = [
              160
              90
            ];
            example = literalExpression "[ 192 108 ]";
            description = ''
              Thumbnail size for background images, as `[ width height ]`.

              Must be a two-element list: the server destructures it. See the note
              on `dimensionPair` above.
            '';
          };
          avatar = mkOption {
            type = dimensionPair;
            default = [
              96
              144
            ];
            description = ''
              Thumbnail size for character avatars, as `[ width height ]`. The
              server destructures this list, so both elements are required.
            '';
          };
          persona = mkOption {
            type = dimensionPair;
            default = [
              96
              144
            ];
            description = ''
              Thumbnail size for user personas, as `[ width height ]`. The
              server destructures this list, so both elements are required.
            '';
          };
        };
      };

      performance = {
        lazyLoadCharacters = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Lazy-load character cards, which helps a lot with a large card
            library. Upstream notes possible incompatibility with some
            extensions.
          '';
        };
        memoryCacheCapacity = mkOption {
          type = types.str;
          default = "100mb";
          example = "512mb";
          description = ''
            Memory ceiling for parsed character cards, as a byte-size string.
            `"0"` disables the cache.
          '';
        };
        useDiskCache = mkOption {
          type = types.bool;
          default = true;
          description = "Cache parsed character cards on disk as well.";
        };
        requestCompression = {
          enabled = mkOption {
            type = types.bool;
            default = false;
            description = "Gzip client request bodies above `minPayloadSize`.";
          };
          minPayloadSize = mkOption {
            type = types.str;
            default = "256kb";
            description = "Payload size at which compression kicks in. \"0\" compresses everything.";
          };
          maxPayloadSize = mkOption {
            type = types.str;
            default = "8mb";
            description = "Hard upper bound on compressible payload size. \"0\" = no bound.";
          };
          timeout = mkOption {
            type = types.ints.unsigned;
            default = 4000;
            description = "Compression timeout in milliseconds.";
          };
        };
      };

      cacheBuster = {
        enabled = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Clear the browser cache on first load and after image uploads, using
            a cache-busting query string.

            Upstream's own comment: this REQUIRES localhost or a domain with
            HTTPS, otherwise it will not work. On a plain-HTTP LAN address the
            browser cannot be forced to refetch, so enabling it is a no-op at best.
          '';
        };
        userAgentPattern = mkOption {
          type = types.str;
          default = "";
          example = "firefox|safari";
          description = "Only cache-bust matching user agents (a case-insensitive regex). Empty = all of them.";
        };
      };

      allowKeysExposure = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Expose stored API keys through the API.

          Off by default because it hands every logged-in user every other user's
          keys. Leave it off unless you are debugging something specific.
        '';
      };

      skipContentCheck = mkOption {
        type = types.bool;
        default = false;
        description = "Skip the check for updated default content on startup.";
      };

      whitelistImportDomains = mkOption {
        type = types.listOf types.str;
        default = [
          "localhost"
          "cdn.discordapp.com"
          "files.catbox.moe"
          "raw.githubusercontent.com"
        ];
        description = "Domains character cards and assets may be downloaded from.";
      };

      requestOverrides = mkOption {
        type = types.listOf requestOverride;
        default = [ ];
        example = literalExpression ''
          [
            {
              hosts = [ "127.0.0.1:5001" ];
              headers."User-Agent" = "\"Googlebot/2.1 (+http://www.google.com/bot.html)\"";
            }
          ]
        '';
        description = ''
          Extra headers added to outgoing requests, for the KoboldAI and Text
          Completion backends. The host string must include the port when it is
          not the default.
        '';
      };

      extensions = {
        enabled = mkOption {
          type = types.bool;
          default = true;
          description = "Enable UI extensions.";
        };
        autoUpdate = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Update extensions automatically when their release version changes.

            Requires a WRITABLE extension directory. This module installs
            extensions into the read-only Nix store, so it overrides this default
            to `false`; see modules/assertions.nix, which refuses a `true` here
            together with any declared extension.
          '';
        };
        models = {
          autoDownload = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Download the extension models below from HuggingFace on demand.

              These are ONNX models — several hundred megabytes in total — fetched
              at first use into the transformers cache under the data root. Set
              false for an air-gapped host; upstream then falls back to a locally
              available model.
            '';
          };
          classification = mkOption {
            type = types.str;
            default = "Cohee/distilbert-base-uncased-go-emotions-onnx";
            description = "HuggingFace model ID for emotion classification.";
          };
          captioning = mkOption {
            type = types.str;
            default = "Xenova/vit-gpt2-image-captioning";
            description = "HuggingFace model ID for image captioning.";
          };
          embedding = mkOption {
            type = types.str;
            default = "Cohee/jina-embeddings-v2-base-en";
            description = "HuggingFace model ID for embeddings (vector storage).";
          };
          speechToText = mkOption {
            type = types.str;
            default = "Xenova/whisper-small";
            description = "HuggingFace model ID for speech-to-text.";
          };
          textToSpeech = mkOption {
            type = types.str;
            default = "Xenova/speecht5_tts";
            description = "HuggingFace model ID for text-to-speech.";
          };
        };
      };

      git = {
        backend = mkOption {
          type = types.enum [ "auto" "system" "builtin" ];
          default = "auto";
          description = ''
            Which git implementation clones and updates extensions and plugins.

            * `"auto"` — use the system `git`, fall back to the integrated one.
            * `"system"` — require the system `git`. The package ships
              `git` in `PATH` for exactly this reason.
            * `"builtin"` — always use `isomorphic-git`, which needs no binary at
              all.

            This module installs extensions and plugins as pinned store paths, so
            in practice this only governs the "install from URL" button in the
            UI.
          '';
        };
      };

      enableDownloadableTokenizers = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Download tokenizer definitions on demand. Set false on an air-gapped
          host; upstream falls back to another locally available tokenizer.
        '';
      };

      promptPlaceholder = mkOption {
        type = types.str;
        default = "[Start a new chat]";
        description = "Injected when a strict-mode prompt does not begin with a user message.";
      };

      openai = {
        randomizeUserId = mkOption {
          type = types.bool;
          default = false;
          description = "Send a random user ID to the OpenAI completion API, to keep users from sharing a completion cache.";
        };
        captionSystemPrompt = mkOption {
          type = types.str;
          default = "";
          example = "Perform the instructions to the best of your ability.\\n";
          description = "System message prepended to caption completion prompts. Not used in image-inlining mode.";
        };
      };

      deepl = {
        formality = mkOption {
          type = types.enum [
            "default"
            "more"
            "less"
            "prefer_more"
            "prefer_less"
          ];
          default = "default";
          description = "Formality passed to the DeepL translation backend.";
        };
      };

      mistral = {
        enablePrefix = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Prefill the reply with the last assistant message. Upstream warns
            that the prefix is echoed into the completion, so a regex trim may be
            needed.
          '';
        };
      };

      ollama = {
        keepAlive = mkOption {
          type = int32;
          default = -1;
          example = 300;
          description = "Seconds to keep an Ollama model loaded after a request. -1 = indefinitely, 0 = unload immediately.";
        };
        batchSize = mkOption {
          type = int32;
          default = -1;
          example = 512;
          description = ''
            Ollama `num_batch`. -1 = the model's own default; otherwise a power of
            two.
          '';
        };
      };

      claude = {
        enableSystemPromptCache = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Cache the system prompt, for a billing discount.

            Only enable when everything before the chat history is STATIC. A
            `{{random}}` macro or a lorebook entry that is not an in-chat
            injection changes the prefix every request, and then this is a pure
            cost with no benefit — upstream says so explicitly.
          '';
        };
        cachingAtDepth = mkOption {
          type = int32;
          default = -1;
          example = 0;
          description = ''
            Cache the message history at this depth. 0 excludes the prefill and is
            the sane starting point. Any negative value disables depth caching;
            any non-integer is ignored.
          '';
        };
        extendedTTL = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Use a 1-hour cache TTL instead of the 5-minute default. Upstream's own
            note: 5m costs base price x1.25, 1h costs x2. Only worth it when the
            prefix really is static.
          '';
        };
        enableAdaptiveThinking = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Adaptive thinking for supported models (Opus 4.6+). `false` enforces
            the legacy thinking-budget mode.
          '';
        };
      };

      gemini = {
        apiVersion = mkOption {
          type = types.enum [ "v1beta" "v1alpha" ];
          default = "v1beta";
          description = "Gemini API endpoint version.";
        };
        thoughtSignatures = mkOption {
          type = types.bool;
          default = true;
          description = "Send thought signatures on requests where available. Gemini 3 and above only.";
        };
        enableSystemPromptCache = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Cache the system prompt, for OpenRouter. Same static-prefix caveat as
            `claude.enableSystemPromptCache`.
          '';
        };
        image = {
          personGeneration = mkOption {
            type = types.enum [
              "allow_adult"
              "allow_none"
              "dont_allow"
              "dont_allow_if_present"
            ];
            default = "allow_adult";
            description = ''
              Imagen's person-generation policy. Empty string would mean
              "use the API default", which this option cannot express — use
              `extraConfig.gemini.image.personGeneration = ""` for that.
            '';
          };
        };
      };

      enableServerPlugins = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Load server-side Node plugins from `./plugins`.

          Server plugins run arbitrary code in the server process with the
          service's full privileges — there is no sandbox and no permission
          model. Upstream ships this off, and so does this module.
        '';
      };

      enableServerPluginsAutoUpdate = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Update server plugins on startup.

          Needs a writable plugin directory. This module installs plugins into
          the read-only store, so it overrides the default to `false` when any
          plugin is declared. See modules/assertions.nix.
        '';
      };
    };

    # ── The command line ──────────────────────────────────────────────────────
    #
    # Every flag `src/command-line.js` declares, including the four deprecated
    # ones. Precedence is the server's, not this module's: a flag supplied here
    # OVERRIDES the corresponding `config` value, because command-line.js
    # resolves each field as `cliArgument ?? getConfigValue(...)`.
    #
    # This duplication is not an accident and not a wart — it is how the server
    # actually resolves its settings, and collapsing the two surfaces would make
    # it impossible to express "config.yaml says X but the flag says Y", which is
    # a real thing operators do.
    #
    # Every flag defaults to `null`, meaning "do not pass it", which leaves the
    # `config` value in charge. The one exception is `global`, which must be
    # `false` for the StateDirectory to apply at all.
    cli = {
      global = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use the global XDG data and config paths instead of the server
          directory.

          Mutually exclusive with `cli.configPath` and `cli.dataRoot`, which the
          server ignores in this mode (it warns and carries on). The module
          asserts `false`, because global mode resolves its paths through
          `env-paths` and would place the data root in `~/.local/share` — outside
          the StateDirectory, outside the service account's home, and not
          something systemd can manage.
        '';
      };

      configPath = mkOption {
        type = types.str;
        default = "";
        description = ''
          Path to `config.yaml`. The module fills this in with the rendered store
          path unless you override it; setting it by hand is how you point at a
          config you manage outside Nix.
        '';
      };

      dataRoot = mkOption {
        type = types.str;
        default = "";
        description = ''
          Root directory for user data. The module fills this in with
          `--dataRoot /var/lib/sillytavern` unless you override it. Overriding it
          without also changing `StateDirectory` leaves the directory outside the
          unit's writable set.
        '';
      };

      enableIPv6 = mkOption {
        type = types.nullOr (types.enum [ "true" "false" "auto" "yes" "no" "on" "off" "1" "0" ]);
        default = null;
        description = "Override `protocol.ipv6`. Same string-or-bool hybrid.";
      };

      enableIPv4 = mkOption {
        type = types.nullOr (types.enum [ "true" "false" "auto" "yes" "no" "on" "off" "1" "0" ]);
        default = null;
        description = "Override `protocol.ipv4`. Same string-or-bool hybrid.";
      };

      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Override `port`.";
      };

      dnsPreferIPv6 = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Override `dnsPreferIPv6`.";
      };

      browserLaunchEnabled = mkOption {
        type = types.nullOr (types.bool);
        default = null;
        description = "Override `browserLaunch.enabled`.";
      };

      browserLaunchHostname = mkOption {
        type = types.nullOr (types.str);
        default = null;
        description = "Override `browserLaunch.hostname`.";
      };

      browserLaunchPort = mkOption {
        type = types.nullOr (int32);
        default = null;
        description = "Override `browserLaunch.port`. -1 = the server's own port.";
      };

      browserLaunchAvoidLocalhost = mkOption {
        type = types.nullOr (types.bool);
        default = null;
        description = "Override `browserLaunch.avoidLocalhost`.";
      };

      listen = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Override `listen`.";
      };

      listenAddressIPv6 = mkOption {
        type = types.nullOr (types.str);
        default = null;
        description = "Override `listenAddress.ipv6`. Keep the brackets.";
      };

      listenAddressIPv4 = mkOption {
        type = types.nullOr (types.str);
        default = null;
        description = "Override `listenAddress.ipv4`.";
      };

      corsProxy = mkOption {
        type = types.nullOr (types.bool);
        default = null;
        description = "Override `enableCorsProxy`.";
      };

      disableCsrf = mkOption {
        type = types.nullOr (types.bool);
        default = null;
        description = "Override `disableCsrfProtection`.";
      };

      ssl = mkOption {
        type = types.nullOr (types.bool);
        default = null;
        description = "Override `ssl.enabled`.";
      };

      certPath = mkOption {
        type = types.nullOr (types.str);
        default = null;
        description = "Override `ssl.certPath`.";
      };

      keyPath = mkOption {
        type = types.nullOr (types.str);
        default = null;
        description = "Override `ssl.keyPath`.";
      };

      keyPassphrase = mkOption {
        type = types.str;
        default = "";
        description = ''
          Passphrase for the TLS private key, as a command-line flag.

          This lands in the unit file and in `ps` output, which any local user can
          read. Use `ssl.keyPassphraseFile`, which reaches the server through
          `SILLYTAVERN_SSL_KEYPASSPHRASE` instead. The module warns when this is
          set to a non-empty value.
        '';
      };

      whitelist = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Override `whitelistMode`.";
      };

      basicAuthMode = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Override `basicAuthMode`.";
      };

      enableKeepAlive = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Override `enableKeepAlive`.";
      };

      requestProxyEnabled = mkOption {
        type = types.nullOr (types.bool);
        default = null;
        description = "Override `requestProxy.enabled`.";
      };

      requestProxyUrl = mkOption {
        type = types.nullOr (types.str);
        default = null;
        description = "Override `requestProxy.url` — also lands in the unit file. Prefer `requestProxy.urlFile`.";
      };

      requestProxyBypass = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          Override `requestProxy.bypass`.

          Cannot express an EMPTY list: yargs has no way to take a zero-length
          array on the command line, and emitting the flag with no value would
          make it swallow the next flag. An empty list here therefore means "do
          not pass the flag", leaving `requestProxy.bypass` in charge. Use
          `extraConfig` if you genuinely need an empty bypass list with a proxy
          URL supplied by flag.
        '';
      };

      heartbeatInterval = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        description = "Override `heartbeatInterval`.";
      };

      # ── Deprecated flags ────────────────────────────────────────────────────
      #
      # Kept because the server still accepts them, and "nothing left stranded"
      # includes the arguments upstream tells you not to use. Each is mapped onto
      # its replacement by command-line.js, and passing BOTH a deprecated flag and
      # its replacement silently prefers the replacement.

      autorun = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "DEPRECATED: use `cli.browserLaunchEnabled`.";
      };

      autorunHostname = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "DEPRECATED: use `cli.browserLaunchHostname`.";
      };

      autorunPortOverride = mkOption {
        type = types.nullOr int32;
        default = null;
        description = "DEPRECATED: use `cli.browserLaunchPort`.";
      };

      avoidLocalhost = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "DEPRECATED: use `cli.browserLaunchAvoidLocalhost`.";
      };
    };

    # ── Secrets ───────────────────────────────────────────────────────────────
    #
    # Each of these is the file-backed twin of a `config` option whose value is a
    # credential. Nothing here reaches the Nix store.

    ssl.keyPassphraseFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "\"\${agenix}/sillytavern-tls-passphrase\"";
      description = ''
        File holding the TLS private key's passphrase, delivered to the server as
        `SILLYTAVERN_SSL_KEYPASSPHRASE`.
      '';
    };

    basicAuthUser.passwordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "\"\${agenix}/sillytavern-basic-auth\"";
      description = ''
        File holding the HTTP basic auth password, delivered as
        `SILLYTAVERN_BASICAUTHUSER_PASSWORD`. Use `"user:password"` form for the
        combined `Authorization` value, or just the password.
      '';
    };

    requestProxy.urlFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "\"\${agenix}/sillytavern-proxy-url\"";
      description = ''
        File holding the outbound proxy URL — the one that genuinely contains a
        credential — delivered as `SILLYTAVERN_REQUESTPROXY_URL`.
      '';
    };

    # ── Accounts ──────────────────────────────────────────────────────────────

    users = mkOption {
      type = types.attrsOf user;
      default = { };
      example = literalExpression ''
        {
          seanc = {
            name = "Sean";
            passwordFile = ''${agenix}/sillytavern-seanc;
            admin = true;
          };
          guest = { };
        }
      '';
      description = ''
        Accounts to seed into the server's user database at activation.

        The attribute NAME is the account handle, which is also its directory name
        under the data root and the lowercased username an SSO provider must send.

        Seeding is CREATE-ONLY: a handle that already exists is left completely
        alone, so a password changed through the UI survives the next rebuild.
        Remove a handle from this list to stop it being managed; the account and
        its data stay in the state directory.

        This requires `config.enableUserAccounts = true`, and is meaningless
        without it — the module asserts both.

        ⚠ A user declared WITHOUT `passwordFile` gets an EMPTY password, and in
        SillyTavern an empty password means PASSWORDLESS, not disabled. The
        login check is `if (user.password && user.password !== …)`, so the
        comparison is skipped and login succeeds with any password at all.
        Verified against a running server. Such an account is only safe behind
        `config.sso.*` or `enableDiscreetLogin`; without one of those, the module
        refuses it unless you set `allowPasswordlessUsers`.

        `default-user` is reserved: the server creates it itself on first start,
        with `admin: true` and an empty password.

        See docs/users.md for the node-persist layout this has to write.
      '';


    };
    allowPasswordlessUsers = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Acknowledge that some `users` entries have no `passwordFile`, and so can
        be logged into without a password.

        Off by default, because an account with an empty password is
        PASSWORDLESS in SillyTavern rather than disabled: the login check is
        `if (user.password && user.password !== …)`, so an empty stored password
        skips the comparison entirely.

        Set this to true only when every passwordless account is protected by
        `config.sso.autheliaAuth`, `config.sso.authentikAuth`, or
        `config.enableDiscreetLogin` on a trusted network.
      '';
    };

    # ── JSON-driven state: settings.json, presets, themes, world books ────────
    #
    # Everything above configures the SERVER. This group configures the JSON it
    # persists, which is where the real application state lives and which is
    # otherwise invisible to Nix.
    #
    # The surface is exactly this, verified by booting 1.19.0 against an empty
    # data root and listing what it wrote (~150 files):
    #
    #   settings.json                 26 KB, 19 keys, depth 5  → `settings`
    #   stats.json                    runtime counters, NEVER seeded
    #   backups/settings_*.json       automatic rollback copies, NEVER seeded
    #   instruct/, context/, sysprompt/, reasoning/,
    #   TextGen Settings/, KoboldAI Settings/,
    #   OpenAI Settings/, NovelAI Settings/   presets, each a JSON array
    #   themes/, worlds/, QuickReplies/, movingUI/, user/workflows/
    #
    # Presets and the rest are all just files, so they share one mechanism
    # (`files`) rather than an option per directory.

    settings = {
      common = mkOption {
        type = jsonObject;
        default = { };
        example = literalExpression ''
          {
            main_api = "custom";
            oai_settings = {
              custom_url = "https://llm.example.com/v1";
              stream_openai = true;
              openai_max_context = 32768;
            };
            power_user = {
              font_scale = 1.2;
              fast_ui_mode = false;
            };
          }
        '';
        description = ''
          Seeded into EVERY account's `settings.json`, deep-merged.

          This is the only deep-merged option here: `settings.json` is rewritten
          by the server on nearly every UI interaction, so it is merged rather
          than replaced to avoid destroying keys this module knows nothing about.

          Note that `main_api` and friends are the account's *connection*
          settings. Pointing these at a host is a real, working configuration —
          see `settings.common.main_api` and
          `settings.common.oai_settings.custom_url` for the server-side
equivalents.
        '';
      };

      byUser = mkOption {
        type = types.attrsOf jsonObject;
        default = { };
        # NESTED, not dotted. A key like `"oai_settings.openai_max_context"` type-checks
        # here, is written to settings.json verbatim, and is then silently
        # ignored by the server, which reads settings by direct property
        # access. `modules/assertions.nix` now rejects the dotted form.
        example = literalExpression ''{ seanc = { oai_settings = { openai_max_context = 131072; }; }; }'';
        description = ''
          Per-account `settings.json` overrides, keyed by account HANDLE.

          Deep-merged over `settings.common`, so a per-account value wins on a
          leaf both declare. A handle that is not also a declared account is
          ignored with a warning rather than creating a stray directory.
        '';
      };
    };

    files = {
      common = mkOption {
        type = types.attrsOf jsonFileContent;
        default = { };
        example = literalExpression ''
          {
            "sysprompt/Roleplay - Detailed.json".json = {
              name = "Roleplay";
              content = "Write {{char}} as {{user}} would.";
              identifier = "sillytavern-nixos";
            };
            "themes/Azure.json".json = { palette = { blur = 0; }; };
            "TextGen Settings/Default.json".path = ./presets/textgen-default.json;
          }
        '';
        description = ''
          Extra JSON files to seed, as paths relative to each account's
          directory under the data root.

          The attribute NAME is the relative path, spaces included, exactly as
          the directory is named in the data root. Use `{ json = …; }` for a
          value written here and `{ path = …; }` for a file copied from the
          store.
        '';
      };

      byUser = mkOption {
        type = types.attrsOf (types.attrsOf jsonFileContent);
        default = { };
        example = literalExpression ''{ seanc.themes."Azure.json".json = { palette.accent = "#f00"; }; }'';
        description = ''
          Per-account `files`, keyed by account HANDLE and then by relative path.
          Merged over `files.common`.
        '';
      };
    };

    # ── Named profiles: the things the UI offers in a dropdown ────────────────
    #
    # `files` above is the RAW layer: you name a path, and the path is what
    # gets written. It is complete — every named item in SillyTavern is
    # reachable through it — but it makes the user know upstream's directory
    # names, and it makes every item an anonymous path rather than a named
    # thing.
    #
    # This group is the NAMED layer. SillyTavern's UI is full of dropdowns of
    # saved, named, importable/exportable items: the Text Completion presets,
    # the AI Response Configuration presets, the Instruct / Context / Sysprompt
    # / Reasoning templates, the themes, the lorebooks, the quick-reply sets,
    # the Moving UI layouts, the ComfyUI workflows. Each is one JSON file per
    # item, in a per-user directory, named after the item.
    #
    # So each of those gets a bucket here, keyed by NAME:
    #
    #   presets.common.instruct."Alpaca".json = { … };
    #   presets.byUser.seanc.themes."Azure".json = { … };
    #
    # The directory is derived from the bucket, so nobody has to know that the
    # Text Completion presets live in a directory called "TextGen Settings".
    #
    # `files` and `presets` are two views of the same files, not two sets of
    # files: declaring the same path in both is an error, not a merge.
    presets = {
      common = mkOption {
        type = presetBucketType;
        default = { };
        example = literalExpression ''
          {
            instruct."Alpaca".json = {
              identifier = "alpaca";
              input_sequence = "<|user|>";
              output_sequence = "<|assistant|>";
            };
            themes."Azure".json = {
              blur_strength = 11;
            };
          }
        '';
        description = ''
          Named profiles seeded into EVERY account, keyed by bucket and then
          by name.

          Each bucket is one kind of item — the Text Completion presets, the
          themes, the lorebooks — and each name is one saved item. See the
          individual buckets for what each one is and where its name ends up.

          The same buckets as `presets.byUser`, and merged with it the same way
          `files.common` and `files.byUser` are.
        '';
      };

      byUser = mkOption {
        type = types.attrsOf presetBucketType;
        default = { };
        example = literalExpression ''
          {
            seanc = {
              sysprompt."Roleplay - Detailed".json = {
                content = "Write {{char}} as {{user}} would.";
              };
            };
          }
        '';
        description = ''
          Per-account named profiles, keyed by account HANDLE, then by bucket,
          then by name.

          Merged over `presets.common`, so a per-account item wins over a
          common one with the same bucket and name.
        '';
      };
    };

    # ── Model layers: settings that follow the active model ───────────────────
    #
    # A SillyTavern account has ONE `settings.json` and ONE `oai_settings`
    # object, and the browser rewrites that file on nearly every UI
    # interaction. There is no server-side "active model" and no place to put
    # a second settings object. So this option does not try to make
    # `settings.json` itself multi-model; it GENERATES the things upstream
    # already switches by name:
    #
    #   * one Chat Completion preset per model (`OpenAI Settings/<name>.json`),
    #     carrying sampling parameters and the preset's `extensions` map;
    #   * the matching Text Completion / Instruct / Context / Sysprompt /
    #     Reasoning presets, when a layer declares them;
    #   * one `(model, character)` Chat Completion preset per declared
    #     character, so a character can override a model's preset;
    #   * `user/files/st-model-layers.json`, a manifest a client extension can
    #     read to pick the right Connection Profile and preset when the active
    #     model or chat changes.
    #
    # The hierarchy is resolved at EVAL time by `lib/model-layers.nix`:
    #
    #   catalog.<id> → byUser.<handle>.models.<id> → …characters.<name>
    #
    # `openai_max_context` is generated from `contextSize`, not written by
    # hand, so it cannot drift from the value the backend is told to use. The
    # runtime resolver is NOT part of this option group yet: until it exists,
    # the generated presets appear in the UI's dropdowns and are selected the
    # same way any other preset is.
    modelLayers = {
      enable = mkEnableOption ''
        per-model and per-character preset generation
      '';

      catalog = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              presetName = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "gemma-4-e4b";
                description = ''
                  The name of the generated presets, and the name of the
                  Connection Profile in the manifest. Defaults to the model id
                  with `/` replaced by `-`.

                  It becomes a FILE NAME, so it cannot contain `/`, `\` or a
                  control character.
                '';
              };

              contextSize = mkOption {
                type = types.ints.positive;
                default = 4096;
                example = 16384;
                description = ''
                  The model's context window, in tokens. This is the single
                  source of `openai_max_context` in every generated Chat
                  Completion preset for this model, including character
                  variants.

                  When the model is also served by
                  `services.llama-cpp-nixos.models.<id>.ctxSize`, set both from the
                  same value. The two modules do not read each other, so the
                  matching is a documented contract rather than a cross-module
                  read; `lib/tests.nix` pins the rendered pairing.
                '';
              };

              connection = {
                api = mkOption {
                  type = types.enum [ "custom" ];
                  default = "custom";
                  description = ''
                    The SillyTavern chat-completion source. Only `custom` is
                    supported in this version, which is what an
                    OpenAI-compatible llama.cpp server is.
                  '';
                };
                url = mkOption {
                  type = types.str;
                  example = "http://127.0.0.1:9931/v1";
                  description = ''
                    Base URL of the OpenAI-compatible endpoint, INCLUDING
                    `/v1`. SillyTavern appends the endpoint path to this.
                  '';
                };
                model = mkOption {
                  type = types.str;
                  example = "gemma-4-e4b";
                  description = ''
                    The model id SillyTavern sends in the request's `"model"`
                    field. For `services.llama-cpp-nixos` this MUST equal the key
                    under `services.llama-cpp-nixos.models`, because that key is the
                    router's INI section name and the router routes on it.
                  '';
                };
                secretId = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "llama";
                  description = ''
                    The label of a `secrets.byUser.<handle>.<label>` entry to
                    use as this connection's API key. `null` means keyless.
                  '';
                };
              };

              presets = mkOption {
                type = modelLayerPresets;
                default = { };
                description = ''
                  Host-wide preset deltas for this model. Every account gets
                  these unless its own layer overrides a leaf.
                '';
              };
            };
          }
        );
        default = { };
        description = ''
          The model catalogue: one entry per model whose settings should be
          generated. The attribute NAME is the model id, and it must match
          `services.llama-cpp-nixos.models.<id>` when both modules are used.
        '';
      };

      byUser = mkOption {
        type = types.attrsOf (
          types.submodule {
            options.models = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    presets = mkOption {
                      type = modelLayerPresets;
                      default = { };
                      description = ''
                        This account's overrides for the model's presets,
                        deep-merged over `catalog.<id>.presets`. A leaf here
                        wins; siblings declared above survive.
                      '';
                    };
                    characters = mkOption {
                      type = types.attrsOf (
                        types.submodule {
                          options.presets = mkOption {
                            type = modelLayerPresets;
                            default = { };
                            description = ''
                              This character's overrides, deep-merged over the
                              account's model layer. A character always gets a
                              Chat Completion preset (so selecting it carries
                              the model's settings); the other buckets are
                              generated only when they are declared here.
                            '';
                          };
                        }
                      );
                      default = { };
                      description = ''
                        Per-character layers, keyed by the character's DISPLAY
                        name — the same string upstream's `autoSelectPreset`
                        compares against a preset name
                        (`public/scripts/preset-manager.js:47-76`).
                      '';
                    };
                  };
                }
              );
              default = { };
              description = ''
                Models this account has a layer for, keyed by the model id.
                Every id must exist in `modelLayers.catalog`; an unknown id is
                an evaluation error, not a silently ignored directory.
              '';
            };
          }
        );
        default = { };
        description = ''
          Per-account model layers, keyed by account HANDLE. The handle must be
          a declared account (or `default-user`), for the same reason
          `settings.byUser` does.
        '';
      };
    };

    # ── Locally-run models ────────────────────────────────────────────────────
    #
    # SillyTavern runs SOME models itself, in-process: the transformers.js
    # pipelines behind the extensions — classification, captioning, embeddings,
    # speech-to-text and text-to-speech — plus the tokenizers they pull in.
    #
    # Everything else belongs to the inference server, NOT to SillyTavern: a
    # GGUF file behind llama.cpp, an Ollama tag, a KoboldCpp checkpoint. From
    # here you point SillyTavern AT that server —
    # `settingsExtra.oaiSettings.chat_completion_source`, `.custom_url` and
    # `.custom_model` — and the weights live wherever that server keeps them.
    # Nothing in this group changes that, and nothing here can make SillyTavern
    # serve a local LLM by itself: it has no inference engine.
    #
    # The ONNX weights it does run are, by upstream's default, DOWNLOADED from
    # HuggingFace on first use into a cache directory. Upstream hardcodes that
    # path — `src/transformers.js:134`:
    #
    #   const cacheDir = path.join(globalThis.DATA_ROOT, '_cache');
    #
    # with no config key and no environment variable, so the module has to
    # reach it the only way it can: by making that path point somewhere else,
    # or by putting the weights where transformers.js looks FIRST.
    #
    # transformers.js resolves a model file from TWO places, in this order
    # (`src/utils/hub.js` in the `sillytavern-transformers` package):
    #
    #   1. the FS cache   — `<cache_dir>/<model-id>/<file>`
    #   2. the local path — `<localModelPath>/<model-id>/<file>`
    #
    # and `localModelPath` is `<the transformers.js package>/models/` — INSIDE
    # the package, which in a Nix build is a read-only store path.
    #
    # Hence the two ways to declare a model here, which differ in where the
    # bytes live:
    #
    #   `byId`      the weights become part of the PACKAGE, in the store
    #   `directory` the weights live in a directory you point at
    models = {
      byId = mkOption {
        type = types.attrsOf types.path;
        default = { };
        example = literalExpression ''
          {
            "Xenova/whisper-small" = pkgs.fetchFromGitHub {
              owner = "Xenova";
              repo = "whisper-small";
              rev = "e8e0c1d19bf7f0d4a4a3f2b0d1a0e0f0a0b0c0d0";
              hash = "sha256-…";
            };
          }
        '';
        description = ''
          Model weights SillyTavern runs itself, keyed by their upstream model
          id — the same string upstream's `config.extensions.models.*` options
          take, e.g. `"Xenova/whisper-small"`.

          Each value is a DIRECTORY in HuggingFace layout: `config.json`,
          `tokenizer.json`, `onnx/…` and whatever else the model needs. The
          whole HuggingFace repository snapshot works, because that layout is
          exactly what transformers.js asks for.

          The directory is installed into the PACKAGE, at
          `node_modules/sillytavern-transformers/models/<model id>/` — the
          `localModelPath` transformers.js searches when a file is not already
          in the cache. So:

          * the weights are in the Nix store: content-addressed, garbage
            collected with the package, never re-downloaded;
          * the server needs no network and no writable model directory;
          * `config.extensions.models.autoDownload` does not have to be turned
            off — the local file is found before any download is attempted.

          The value must be a STORE PATH. A path outside the store cannot be
          linked into a store path (the link would dangle the moment the
          garbage collector ran), and the module refuses one rather than
          producing a package that breaks later.

          The model id must match the one the server asks for. It is also the
          key upstream's `config.extensions.models.*` options use, so the two
          must agree:

            services.sillytavern-nixos = {
              models.byId."Xenova/whisper-small" = …;
              config.extensions.models.speechToText = "Xenova/whisper-small";
            };
        '';
      };

      directory = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "/var/lib/sillytavern-models";
        description = ''
          A directory of model weights, used as the model's data directory at
          runtime.

          Its contents must be in transformers.js cache layout — one
          subdirectory per model id, each holding that model's files:

            <directory>/Xenova/whisper-small/config.json
            <directory>/Xenova/whisper-small/onnx/…

          The module points upstream's hardcoded cache path
          (`<dataRoot>/_cache`) at this directory, so the server finds the
          weights exactly where it would have found downloaded ones.

          Use this for weights you manage OUTSIDE Nix — a directory on another
          disk, a mount, a set of files you fetched by hand. Use `models.byId`
          instead for weights that should be part of the Nix store.

          A writable directory keeps `config.extensions.models.autoDownload`
          working: the server can still download a model it does not find
          locally, into this directory. A READ-ONLY one (a store path) cannot
          be written to, so the module forces `autoDownload` off in that case
          — a download into the store would fail with EROFS.

          The directory must exist when the service starts; the module creates
          the link, not the directory, and fails loudly if the target is
          missing.
        '';
      };
    };

    seedPolicy = mkOption {
      type = types.enum [ "missing" "overwrite" ];
      default = "missing";
      example = "overwrite";
      description = ''
        What happens to a seeded file that already exists.

        `"missing"` (the default) writes a file only if it is absent, and is what
        you want almost always: every seeded file is owned by the UI afterwards,
        so an edit made in SillyTavern survives the next `nixos-rebuild`.

        `"overwrite"` restores the declared value on every activation, making
        presets and themes effectively read-only. Note it is NOT a constant:
        SillyTavern still rewrites `settings.json` at runtime, so anything the UI
        changes afterwards diverges again until the next rebuild.

        Either way, `stats.json` and `backups/` are never written — they are
        server runtime state, not configuration.
      '';
    };

    # ── Instance-wide custom CSS ──────────────────────────────────────────────
    #
    # SillyTavern loads `css/user.css` on every page (`public/index.html:46`) and
    # serves it from the DATA ROOT, not the package:
    #
    #   src/middleware/userCss.js:10
    #     path.resolve(path.join(globalThis.DATA_ROOT, '_css', 'user.css'))
    #
    # It is the only stylesheet SillyTavern exposes to every visitor without a
    # login, and there is no other way to get a file there from outside the app.
    #
    # It is NOT the same thing as `settings.common.power_user.custom_css`, which
    # is the in-browser editor's textarea and is already seedable. Two
    # mechanisms, two files; this one is instance-wide, theirs is per-account.

    customCss = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "./ui-overrides.css";
      description = ''
        A stylesheet installed as `<dataRoot>/_css/user.css` on every activation.

        Applies to the whole instance: every visitor of every account gets it,
        and it is served without authentication.

        ⚠ NIX-AUTHORITATIVE: while this option is set the file is
        OVERWRITTEN on every activation, and `seedPolicy` does not apply to it.
        That is deliberate and it is the opposite of how every other file in
        this module behaves. The reasoning is that create-only semantics would
        protect nothing here: nothing ever UPDATES this file.

        The server does write it, but exactly once. Content seeding copies
        `default/content/user.css` to `<dataRoot>/_css/user.css` on first start
        (`seedContent` in `src/endpoints/content-manager.js` — `force: false`,
        and the copy is skipped outright when the target already exists), and
        nothing ever overwrites it afterwards. `_css` is also the global
        content-manager target for `CONTENT_TYPES.STYLESHEET`, but the only
        routes that write there are `importURL` and `importUUID`, and there is no
        UI for either — `grep -rn contentmanager public/` finds nothing.

        So under `"missing"` the file would be written once by the server and
        then never change again, and editing this option would silently do
        nothing — the exact failure mode this option exists to fix.

        Note this is a different file from `settings.common.power_user.custom_css`,
        the in-browser editor's textarea, which lands in `settings.json` and is
        seeded create-only like everything else.

        Leaving this `null` means the module NEVER TOUCHES the file: an existing
        `_css/user.css` is left completely alone, whether hand-written, imported
        through the content manager, or seeded by the server itself on first
        start. Removing this option from your configuration does NOT delete a
        previously-seeded file — it stops managing it and leaves it in place.
      '';
    };

    # ── Branded error pages ──────────────────────────────────────────────────
    #
    # The mirror of `customCss`, and it exists for the same reason: upstream
    # ships four HTML pages that it serves to UNAUTHENTICATED visitors on
    # exactly the paths an operator most wants branded — a failed SSO login, a
    # rejected host header, a blocked IP, a 404. They were unreachable from Nix
    # before this option: `st_seed_files.py` refused `_errors/` outright
    # (RESERVED_TOP_LEVEL) and `dataRootFiles` was fed from `customCss` alone.
    #
    # The four names are the ones upstream hardcodes, at four separate sites:
    #   forbidden-by-whitelist.html  src/middleware/whitelist.js:59
    #   host-not-allowed.html        src/middleware/hostWhitelist.js:14
    #   unauthorized.html           src/endpoints/users-public.js
    #   url-not-found.html           src/server-main.js:456
    # and are seeded from `default/content/index.json` on first start. Declaring
    # one here overrides that copy.
    #
    # LITERAL KEYS, not an `attrsOf`, on purpose: `dataRootFiles` must only ever
    # be populated from fixed paths, so no user expression can put an arbitrary
    # path in it. `assertions.nix` re-checks that on every evaluation. This is
    # the same invariant that stopped `files.common` from being folded in.
    errorPages = {
      unauthorized = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "./pages/unauthorized.html";
        description = ''
          Installed as `<dataRoot>/_errors/unauthorized.html`. Served when a
          login attempt fails or the session is missing.

          Same semantics as `customCss`: Nix-authoritative, overwritten on every
          activation, `seedPolicy` does not apply. Nothing ever UPDATES these
          files after the content-manager's first-start copy.
        '';
      };

      forbiddenByWhitelist = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "./pages/blocked.html";
        description = ''
          Installed as `<dataRoot>/_errors/forbidden-by-whitelist.html`. Served
          to a client whose address is not in `config.whitelist`, by the
          whitelist middleware before any authentication happens.

          Note the filename contains a hyphen and the option name does not —
          upstream's name is `forbidden-by-whitelist`, not
          `forbiddenByWhitelist`.
        '';
      };

      hostNotAllowed = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Installed as `<dataRoot>/_errors/host-not-allowed.html`. Served when
          the request's `Host` header fails `config.hostWhitelist` — the common
          case being a reverse proxy forwarding a hostname you did not allow.
        '';
      };

      urlNotFound = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Installed as `<dataRoot>/_errors/url-not-found.html`. Served for any
          unmatched route, so this one is what a visitor sees for a typo'd URL
          or a stale bookmark.
        '';
      };
    };

    # ── Top-level settings.json keys ──────────────────────────────────────────
    #
    # These are the top-level keys in per-account `settings.json` that the UI
    # manages but that had no first-class option. `settings.common` is a
    # free-form JSON blob and could already carry them, but undiscoverable.
    # These options are typed, documented, and deep-merged into every account's
    # `settings.json` alongside `settings.common`.

    settingsExtra = {
      mainApi = mkOption {
        type = types.str;
        default = "openai";
        description = ''
          The AI provider selected in the UI (Settings → AI Configuration).
          This is the account's *connection* setting — the server-side
          equivalent is `config.oai_settings.custom_url` and friends.
        '';
      };

      maxContext = mkOption {
        type = types.int;
        default = 4096;
        description = ''
          Default max context size (in tokens) for new chats. The UI exposes
          this as a quick-setting; the server clamps it to the model's limit.
        '';
      };

      background = {
        url = mkOption {
          type = types.str;
          default = "";
          description = ''
            URL of the background image. Empty means the default background.
          '';
        };
        name = mkOption {
          type = types.str;
          default = "";
          description = ''
            Display name for the background (used in the background picker).
          '';
        };
        fitting = mkOption {
          type = types.str;
          default = "cover";
          description = ''
            How the background image fits the viewport. One of "cover",
            "contain", "stretch", "center".
          '';
        };
        animation = mkOption {
          type = types.str;
          default = "none";
          description = ''
            Animation applied to the background. One of "none", "pan", "zoom".
          '';
        };
        sortOrder = mkOption {
          type = types.int;
          default = 0;
          description = ''
            Sort order in the background gallery. Lower values appear first.
          '';
        };
        thumbnailColumns = mkOption {
          type = types.int;
          default = 4;
          description = ''
            Number of thumbnail columns in the background gallery.
          '';
        };
      };

      proxies = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              default = "";
              description = "Display name for the proxy.";
            };
            url = mkOption {
              type = types.str;
              default = "";
              description = "Proxy URL (e.g. http://proxy.example.com:8080).";
            };
            password = mkOption {
              type = types.str;
              default = "";
              description = "Proxy password, if required.";
            };
    };
  });


        default = [ ];
        description = ''
          List of proxy configurations. The UI exposes these under
          Settings → Connection → Proxies. `selected_proxy` below points at
          one of these by index.
        '';
      };

      selectedProxy = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Index into `settingsExtra.proxies` of the active proxy. 0 means
          "no proxy" (the default).
        '';
      };

      swipes = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether swipe actions (swipe left/right to navigate message history)
          are enabled. The UI exposes this as a toggle under Settings →
          Chat/Message Handling.
        '';
      };

      username = mkOption {
        type = types.str;
        default = "";
        description = ''
          The account's display name. Empty means the account handle is used.
          This is separate from the account *handle* (which is the directory
          name and login credential).
        '';
      };

      extensionSettings = mkOption {
        type = types.attrs;
        default = { };
        example = literalExpression ''
          {
            disabledExtensions = [ "caption" ];
            expressionOverrides = [ "expression-1" ];
          }
        '';
        description = ''
          Free-form `extension_settings` object from `settings.json`. This is
          the largest settings surface (216 leaves) and most of it is
          extension-specific. Known keys include:

          - `disabledExtensions` — list of extension names to disable
          - `expressionOverrides` — list of expression override IDs
          - `memory` — memory extension settings (chunk size, etc.)
          - `apiUrl` / `apiKey` — extension API credentials
          - `autoConnect` — auto-connect to extension on startup

          Anything set here is deep-merged into every account's
          `settings.json` under `extension_settings`.
        '';
      };

      # ── The seven UI subtrees, typed ───────────────────────────────────────
      #
      # `settings.common` can carry every one of these, and always could. What
      # it could not do is TELL you what they are: the names, the types and
      # upstream's defaults were nowhere in the repository, so a typo was
      # accepted and did nothing.
      #
      # These options are that knowledge, made into options. The tree is
      # generated from `lib/settings-inventory.json`, which is derived from
      # upstream's own source — so a setting added upstream appears here
      # automatically, and one removed upstream stops being accepted.
      #
      # Three things to know:
      #
      #   * Option names are upstream's own, verbatim (`font_scale`, not
      #     `fontScale`). These mirror a JSON document.
      #   * Every leaf is `nullOr <type>` with `default = null`, and `null`
      #     means "not declared" — the account keeps upstream's own default.
      #     Upstream computes some defaults at runtime (a theme colour is read
      #     out of the CSS), and pinning them would freeze them.
      #   * The merge order is unchanged: `settingsExtra` (this) is the BASE
      #     layer, `settings.common` overrides it, and `settings.byUser`
      #     overrides both. So the same leaf can be set in either place, and
      #     the more specific one wins.
      #
      # `settings.common` remains free-form, and the module still refuses a
      # path upstream does not have — see `docs/settings-surface.md`.

      # The User Settings panel: appearance, message handling, prompt macros,
      # personas. 182 leaf fields.
      powerUser = mkOption {
        type = settingsTree.surfaceType "power_user";
        default = { };
        example = literalExpression ''
          {
            font_scale = 1.2;
            fast_ui_mode = false;
            chat_truncation = 200;
          }
        '';
        description = ''
          The `power_user` object in the account's `settings.json` — the
          **User Settings** panel: interface, chat and message handling, prompt
          macros, personas, and the stscript editor's preferences.

          182 leaf fields, all declared individually below with upstream's own
          names, types and defaults. `null` (the default) means "not
          declared", and the account keeps upstream's default.
        '';
      };

      # The AI Response Configuration panel: model, connection, sampling.
      # 106 leaf fields.
      oaiSettings = mkOption {
        type = settingsTree.surfaceType "oai_settings";
        default = { };
        example = literalExpression ''
          {
            openai_max_context = 32768;
            temp_openai = 0.7;
            custom_url = "https://llm.example.com/v1";
          }
        '';
        description = ''
          The `oai_settings` object in the account's `settings.json` — the
          **AI Response Configuration** panel: model selection, connection
          settings, sampling parameters, and the prompt templates.

          106 leaf fields, all declared individually below with upstream's own
          names, types and defaults.

          Note that the *server*-side equivalents live in `config.*` (see
          `config.openaiModel`, `config.customUrl`); these are the account's
          own copy of the same choices.
        '';
      };

      # The Text Completion panel. 61 leaf fields — one per text-generation
      # preset key.
      textGenerationSettings = mkOption {
        type = settingsTree.surfaceType "textgenerationwebui_settings";
        default = { };
        example = literalExpression ''
          {
            temp = 0.9;
            top_p = 0.95;
            rep_pen = 1.1;
          }
        '';
        description = ''
          The `textgenerationwebui_settings` object in the account's
          `settings.json` — the **Text Completion** panel.

          61 leaf fields, taken from the union of the shipped text-generation
          presets. The presets themselves are files
          (`files.byUser."TextGen Settings/<name>.json"`); these options set
          the *active* values.
        '';
      };

      # The NovelAI panel. 24 leaf fields.
      naiSettings = mkOption {
        type = settingsTree.surfaceType "nai_settings";
        default = { };
        example = literalExpression ''
          {
            temperature = 1.1;
            repetition_penalty = 2.1;
          }
        '';
        description = ''
          The `nai_settings` object in the account's `settings.json` — the
          **NovelAI** panel.

          24 leaf fields, all declared individually below with upstream's own
          names, types and defaults.
        '';
      };

      # The KoboldAI Classic panel. 20 leaf fields.
      kaiSettings = mkOption {
        type = settingsTree.surfaceType "kai_settings";
        default = { };
        example = literalExpression ''
          {
            temp = 0.8;
            top_k = 40;
          }
        '';
        description = ''
          The `kai_settings` object in the account's `settings.json` — the
          **KoboldAI Classic** panel.

          20 leaf fields, all declared individually below with upstream's own
          names, types and defaults.
        '';
      };

      # The AI Horde panel. 4 leaf fields.
      hordeSettings = mkOption {
        type = settingsTree.surfaceType "horde_settings";
        default = { };
        example = literalExpression ''
          {
            auto_adjust_context_length = true;
          }
        '';
        description = ''
          The `horde_settings` object in the account's `settings.json` — the
          **AI Horde** panel.

          4 leaf fields, all declared individually below with upstream's own
          names, types and defaults.
        '';
      };

      # The World Info (lorebook) panel. 13 leaf fields — the *policy* for
      # how lorebooks are scanned, not the lorebooks themselves.
      worldInfoSettings = mkOption {
        type = settingsTree.surfaceType "world_info_settings";
        default = { };
        example = literalExpression ''
          {
            world_info_depth = 4;
            world_info_budget = 500;
            world_info_recursive = true;
          }
        '';
        description = ''
          The `world_info_settings` object in the account's `settings.json` —
          the **World Info** panel: how lorebooks are scanned and injected.

          13 leaf fields, all declared individually below with upstream's own
          names, types and defaults. The lorebooks themselves are files
          (`files.byUser."worlds/<name>.json"`); these are the rules applied
          to them.
        '';
      };
    };

    # ── Local speech: the TTS extension ───────────────────────────────────────
    #
    # The browser-side TTS extension keeps its state at
    # `extension_settings.tts`, and its **OpenAI Compatible** provider does NOT
    # call the endpoint from the browser: it POSTs to SillyTavern's own
    # `/api/openai/custom/generate-voice`, which proxies server-side
    # (`src/endpoints/openai.js`). That is why the endpoint can be a loopback
    # address even when the browser is remote, and why CORS is irrelevant here.
    #
    # When `services.breeze-tts-nixos` is enabled in the same system, the
    # provider is pointed at it automatically. The read is guarded with `or`, so
    # importing this module alone behaves exactly as before, and an explicit
    # `settingsExtra.extensionSettings.tts` always wins over the generated
    # defaults.
    tts = {
      autoConfigure = mkOption {
        type = types.bool;
        default = true;
        description = ''
          When a Breeze TTS backend is enabled in the same system (or
          `tts.endpoint` is set), write the OpenAI-Compatible provider settings
          into every account's `extension_settings.tts`.

          Set `false` to manage `extension_settings.tts` entirely yourself
          through `settingsExtra`; nothing is written in that case.
        '';
      };

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          `extension_settings.tts.enabled` — speak assistant replies as they
          arrive. Off by default: turning it on changes what the UI does on
          load, and a wrongly-pointed endpoint should not start talking before
          you have chosen a voice.
        '';
      };

      endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://127.0.0.1:8137/v1/audio/speech";
        description = ''
          The full `/v1/audio/speech` URL. `null` derives it from the Breeze
          backend's `port`; set it explicitly to point at a server on another
          host, or when the Breeze module is not imported.
        '';
      };

      provider = mkOption {
        type = types.str;
        default = "OpenAI Compatible";
        description = "The TTS provider to select. Upstream's provider name is `OpenAI Compatible`.";
      };

      model = mkOption {
        type = types.str;
        default = "tts-1";
        description = "The `model` field. SillyTavern requires one; the Breeze server ignores it.";
      };

      voices = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "narrator"
          "harbour"
        ];
        description = ''
          `available_voices`: the voice ids the UI offers. Empty leaves the
          dropdown empty, which still works for reference-free voice design
          (the request sends no voice). Register voices on the server with
          `POST /v1/voices` and list their ids here.

          Voices declared under `services.breeze-tts-nixos.voices` are added
          automatically when the provider is `OpenAI Compatible`; this list is
          for runtime-registered voices and is unioned with them.
        '';
      };

      autoGeneration = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "`extension_settings.tts.auto_generation`. null leaves upstream's default.";
      };
    };

    # ── Provider API keys ─────────────────────────────────────────────────────
    #
    # 1.19 moved every provider key OUT of `settings.json` and into a
    # per-account `secrets.json`, shaped
    #   { "<key>": [ { id, value, label, active }, … ] }
    # because a key must be rotatable without losing the old one, and only the
    # `active` entry is sent upstream. The keys are the `SECRET_KEYS` table in
    # public/scripts/secrets.js — `api_key_openai`, `api_key_claude`,
    # `api_key_novel`, and ~20 more.
    #
    # This option exists so those keys are Nix-driven. There is no other route:
    # `files.byUser."secrets.json"` is rejected, and putting a key in
    # `settings.json` does not work because the server no longer reads it there.

    secrets = {
      byUser = mkOption {
        type = types.attrsOf (types.attrsOf secretEntry);
        default = { };
        example = literalExpression ''
          {
            seanc = {
              api_key_openai = {
                value = config.age.secrets.openai_api_key.path;
                label = "personal";
              };
              api_key_claude.value = config.age.secrets.anthropic_api_key.path;
            };
            # The single-account case still needs an account, even though the
            # server would also accept `default-user`.
            default-user.api_key_openai.value = config.age.secrets.openai_api_key.path;
          }
        '';
        description = ''
          Provider API keys to seed into each account's `secrets.json`, keyed by
          account HANDLE and then by SillyTavern's own `SECRET_KEYS` name.

          `value` is a PATH to a file containing the key, never the key itself —
          a literal would be copied into the Nix store, which is world-readable.
          Source it from agenix (`config.age.secrets.<name>.path`, decrypted to
          `/run/agenix/<name>`) or any other file you control.

          Each entry is written as an `{id, value, label, active: true}` record,
          matching what the UI's key manager reads, so the key is usable in the
          browser exactly as if it had been typed there.

          Seeding is idempotent and does not disturb the UI: a key already active
          with this value is left alone, and under the default
          `seedPolicy = "missing"` a key you added through the UI is never
          overridden. `overwrite` deactivates the previous entry — it does not
          delete it, so the UI's key history still works.
        '';
      };
    };

    # ── Plugins and extensions ────────────────────────────────────────────────

    plugins = mkOption {
      type = types.attrsOf gitPackage;
      default = { };
      example = literalExpression ''
        {
          dice-roll = {
            url = "https://github.com/example/SillyTavern-Dice-Roll.git";
            rev = "refs/tags/v1.0.0";
          };
        }
      '';
      description = ''
        Server plugins, installed as pinned `fetchgit` store paths under the
        package's `plugins/`.

        Requires `config.enableServerPlugins = true`. Server plugins execute
        arbitrary code in the server process with no sandbox, so this module ships
        them disabled and never turns them on for you.
      '';
    };

    extensions = mkOption {
      type = types.attrsOf gitPackage;
      default = { };
      example = literalExpression ''
        {
          # vector-storage = {
          #   url = "https://github.com/example/SillyTavern-VectorStorage.git";
          #   rev = "refs/tags/v3.0.0";
          # };
        }
      '';
      description = ''
        UI extensions, installed as pinned `fetchgit` store paths under the
        package's `public/scripts/extensions/third-party/`.

        Extensions are read-only in this deployment, which is why the module
        forces `config.extensions.autoUpdate = false` — the UI's "update
        extensions" button would fail against a store path. Update them by
        changing `rev` here and rebuilding.
      '';
    };

    # ── Everything else ───────────────────────────────────────────────────────

    extraConfig = mkOption {
      type = types.attrs;
      default = { };
      example = literalExpression ''
        {
          # An option that this module does not know about yet, because it was
          # added upstream after this pin. Anything set here is deep-merged over
          # `config` and rendered like everything else.
          someNewUpstreamOption = true;
        }
      '';
      description = ''
        Free-form `config.yaml` keys, deep-merged over `config` as the LAST step.

        The escape hatch that guarantees nothing is stranded: if upstream adds a
        key before this module models it, set it here instead of dropping to a
        hand-edited file. Rendered with the same YAML writer, so it is still fully
        declarative and still diffs.

        It is NOT validated. A typo produces a config key the server ignores.
      '';
    };

    # Advanced: override any config key through the environment variable
    # SillyTavern would read it from (`keyToEnv`: uppercased, dots to
    # underscores, `SILLYTAVERN_` prefix). See docs/options.md.
    extraConfigEnv = mkOption {
      type = types.attrsOf (types.oneOf [ types.str int32 types.bool ]);
      default = { };
      example = literalExpression ''
        {
          SILLYTAVERN_THUMBNAILS_QUALITY = "80";
        }
      '';
      description = ''
        Extra `SILLYTAVERN_*` environment variables, applied to the unit as-is.

        `getConfigValue` checks the environment BEFORE the config file, so this
        outranks everything in `config` and `extraConfig`. It exists because the
        env-var mapping is genuinely useful for one-off overrides — and because
        the type coercion in `getConfigValue` is inconsistent for list and object
        values (`cors.origin` is read with a STRING default, so a JSON array in
        the environment arrives as a string), which makes the environment the
        wrong place for those. Prefer `config`; use this when you know why.
      '';
    };

    environment = mkOption {
      type = types.attrsOf (types.oneOf [ types.str (types.listOf types.str) int32 types.bool ]);
      default = { };
      example = literalExpression ''
        {
          # SillyTavern reads the standard proxy variables too.
          no_proxy = "localhost,127.0.0.1";
        }
      '';
      description = ''
        Extra environment variables for the unit, unrelated to configuration —
        `NODE_EXTRA_CA_CERTS`, proxy variables, `TZ`. For config keys, use
        `extraConfigEnv`.
      '';
    };

    proxyUpstreams = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            default = "sillytavern";
            description = "Upstream name.";
          };
          port = mkOption {
            type = types.port;
            default = config.services.sillytavern-nixos.config.port;
            description = "Port the reverse proxy should connect to.";
          };
          path = mkOption {
            type = types.str;
            default = "/";
            description = "Path prefix. SillyTavern serves from the root, so this is `/` unless a proxy adds one.";
          };
          stripPrefix = mkOption {
            type = types.bool;
            default = false;
            description = "Whether the proxy strips `path` before forwarding.";
          };
          displayName = mkOption {
            type = types.str;
            default = "SillyTavern";
            description = "Human-readable name, for a proxy's admin UI.";
          };

          # ── The four things a proxy in front of SillyTavern gets wrong ────
          #
          # None of these open a socket. They exist so the values the proxy
          # MUST be configured with are declared in one place, next to the
          # server options they interact with, instead of being rediscovered
          # as a 413 or a blank page in production. See
          # docs/installing.md "Behind a reverse proxy" for what breaks when
          # each is wrong.

          hosts = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "st.example.com" ];
            description = ''
              Host names this upstream answers to.

              SillyTavern inspects the `Host` header when
              `config.hostWhitelist.enabled` is true
              (`src/middleware/hostWhitelist.js:26`), and behind a reverse proxy
              that header is the PUBLIC name, not `localhost`. Enabling the
              whitelist without listing the public name rejects every request.

              An assertion requires this to be non-empty whenever
              `config.hostWhitelist.enabled` is true. Empty is correct for a
              loopback-only instance behind no proxy.
            '';
          };

          maxBodySize = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "512m";
            description = ''
              Maximum request body the proxy should accept.

              `null` means "the proxy's own default", which is almost always
              WRONG: `src/server-main.js` configures body parsers with a `500mb`
              limit, because character cards, backgrounds, chat imports and
              `settings.json` are all uploaded as JSON. nginx's
              `client_max_body_size` defaults to **1 MB**, so the documented
              topology fails with a bare `413 Request Entity Too Large` on the
              first avatar upload and nothing in the SillyTavern log explains
              it.

              Unrelated to `config.performance.requestCompression`, which
              compresses OUTBOUND requests to LLM providers.
            '';
          };

          forwardedFor = mkOption {
            type = types.enum [ "append" "replace" "off" ];
            default = "replace";
            description = ''
              Whether the proxy REPLACES or APPENDS to `X-Forwarded-For`.

              `config.enableForwardedWhitelist` defaults to **true**, and
              `src/express-common.js` prefers `x-real-ip`, then
              `cf-connecting-ip`, then the FIRST entry of `x-forwarded-for`.
              An appending proxy lets a client send its own `X-Forwarded-For`,
              whose first entry is attacker-chosen — so `whitelist` and
              `rateLimiting.preferRealIpHeader` then trust a spoofed address.

              `replace` means forward the immediate peer's address
              (nginx `$remote_addr`, Caddy's default). `off` means do not emit
              the header at all, which is only safe together with
              `config.enableForwardedWhitelist = false`.
            '';
          };

          readTimeout = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "1h";
            description = ''
              Proxy read timeout for this upstream.

              `null` leaves the proxy's default, and most defaults (60s for
              nginx `proxy_read_timeout`) are far shorter than a long LLM
              generation streaming tokens over SSE. The symptom is a
              mid-answer `502`, which looks like the model failing rather than
              the proxy giving up.

              This is an INACTIVITY timeout: it resets on every chunk written, so
              it needs to exceed the longest gap between tokens, not the whole
              response.
            '';
          };
        };
      });
      default = [ ];
      example = literalExpression ''[ self.lib.mkProxyUpstream { inherit config; } ]'';
      description = ''
        Reverse-proxy upstreams describing this instance.

        Deliberately just DATA: this project does not depend on any particular
        reverse-proxy module, so it cannot open a proxy hole for you. Wire it
        into whatever you use:

          proxy.upstreams = lib.mkMerge (
            map inputs.sillytavern.lib.mkProxyUpstream
              config.services.sillytavern-nixos.proxyUpstreams);

        `self.lib.mkProxyUpstream { inherit config; }` builds a default entry
        from the live `config.port`, and is the form to use when you are NOT
        mapping over the list above.

        `hosts`, `maxBodySize`, `forwardedFor` and `readTimeout` are carried
        through to the emitted upstream so a consumer's proxy module can
        interpolate them. They are declarative facts about the deployment, not
        something this module can enforce on a proxy it does not control.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open `config.port` in the firewall.

        `false` by default because the intended topology is a reverse proxy or an
        SSH tunnel reaching a loopback bind. Turning this on exposes an HTTP
        service with no TLS of its own to every network the host is on.
      '';
    };

    # ── systemd ───────────────────────────────────────────────────────────────

    startupTimeout = mkOption {
      type = types.ints.unsigned;
      default = 180;
      description = ''
        Seconds systemd waits for the unit to reach `active`.

        The server recompiles its frontend bundle with webpack before it starts
        listening (`runWebpackCompiler` in src/server-main.js), so the first
        start after an upgrade is genuinely slow — tens of seconds on a cold
        cache, longer on a slow disk. The default here is generous for that.
      '';
    };

    shutdownTimeout = mkOption {
      type = types.ints.unsigned;
      default = 30;
      description = ''
        Seconds systemd waits after SIGTERM before sending SIGKILL.

        The server handles SIGTERM and SIGINT gracefully (`exitProcess` in
        src/server-main.js) and stops accepting new requests first, so this is
        only a backstop for a hung shutdown.
      '';
    };

    restartTriggers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra `systemd.RestartTrigger=` units.

        For the usual case of "restart when the upstream package changes", the
        module already sets the trigger on the package's unit automatically;
        this is for anything else.
      '';
    };

    hardware = mkOption {
      type = hardware;
      default = { };
      description = "Resource limits for the systemd unit. All null = no limit.";
    };

systemdOverrides = mkOption {
        type = types.attrs;
        default = { };
        example = literalExpression ''
          {
            # Anything in here is written into the unit file verbatim, so it is
            # NOT validated. Systemd directive names and case, exactly.
            # The two halves of the unit are DIFFERENT option sets, and getting
            # that wrong fails loudly at eval rather than silently:
            #
            #   `serviceConfig.*` -> a systemd [Service] directive. `Restart`,
            #     `LimitNOFILE`, `ReadWritePaths`, `Environment`… all go here.
            #
            #   unit-level       -> NixOS' `systemd.services.<name>` options.
            #     `description`, `after`, `wantedBy`, `restartTriggers`…
            #     Putting `Restart` HERE fails with "The option
            #     systemd.services.sillytavern.Restart does not exist", because
            #     NixOS only declares `Restart` inside `serviceConfig`.
            serviceConfig.ReadWritePaths = [ "/var/lib/sillytavern/extra" ];
          }
        '';
        description = ''
          Raw systemd unit options, merged last.

          The escape hatch for the unit, equivalent in spirit to `extraConfig`
          for `config.yaml`. Not validated.

          A `serviceConfig` given here is MERGED into the one this module
          builds, key by key — it adds to or replaces individual directives, and
          the rest of the unit (ExecStart, User, StateDirectory, the hardening
          block) is left intact. That is the only safe way to use this option.

          It was previously applied to the whole unit instead, and attrset `//`
          replaces rather than merges — so a single `serviceConfig` key here
          silently discarded the entire block. Verified live: with
          `systemdOverrides = { serviceConfig.ReadWritePaths = [ "/tmp/x" ]; };`
          the resulting `serviceConfig` was reduced to exactly
          `[ "ExecStartPre" "ReadWritePaths" ]` — a unit with no `ExecStart`
          (so it never starts), no `User`, no `StateDirectory`, and no
          hardening, while `nixos-rebuild` stayed green.
        '';
      };

    # ── TLS convenience ───────────────────────────────────────────────────────

    ssl = {
      certFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "\"\${config.networking.x509.certificates.myserver}.crt\"";
        description = ''
          Certificate file, copied into the package's `certs/` directory and
          pointed at by an ABSOLUTE `ssl.certPath`.

          SillyTavern resolves a relative `certPath` against its own directory,
          which is the read-only store. Copying the file in at build time is what
          makes a relative path work at all, and an absolute path is what makes it
          unambiguous.

          Only for people who really are terminating TLS in SillyTavern; a reverse
          proxy is the better answer. See docs/installing.md.
        '';
      };

      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "\"\${config.networking.x509.certificates.myserver}.key\"";
        description = "Private key file. Same caveats as `ssl.certFile`.";
      };
    };
  };
}
