# lib/default.nix
#
# Shared, NixOS-module-free helpers for packaging and running SillyTavern.
#
# Everything in here is pure: it takes values and returns strings or attrsets,
# and it never reads `config` or instantiates `pkgs`. That makes it directly
# unit-testable (`nix flake check`, via the `libHelpers` check) and reusable
# from a consumer's own module, which `self.lib` exposes.
#
# The three renderers are the load-bearing part of this project:
#
#   renderYaml        config.yaml   — the complete declarative config surface
#   renderEnvFile     Environment=  — secrets, which must never touch the store
#   renderCliArgv     argv          — the command line, which outranks config.yaml
#
# WHY A YAML RENDERER AND NOT `builtins.toJSON`
#
# SillyTavern's config.yaml is read by the `yaml` npm package. JSON is a subset
# of YAML 1.2, so a JSON document would technically parse — but `yaml` defaults
# to YAML 1.2 *core schema* parsing where `yes`, `no`, `on` and `off` are
# STRINGS, not booleans. Rendering JSON sidesteps that, but it produces an
# unreadable file and, more importantly, breaks the one thing a human actually
# does with this file: read it and compare it against the upstream
# `default/config.yaml` to work out what a given option does. A rendered
# block-style YAML file that mirrors upstream's shape is worth the extra code.
#
# WHY SECRETS DO NOT GO THROUGH renderYaml
#
# Everything renderYaml produces is a Nix store path: world-readable, greppable
# by anyone who can read /nix/store, and preserved forever by the garbage
# collector. `ssl.keyPassphrase`, `basicAuthUser.password` and
# `requestProxy.url` all routinely carry credentials — the upstream defaults
# literally contain `socks5://username:password@example.com:1080`. Writing
# those into a store file is how a proxy password leaks, so every secret in
# this project has a `…File` option that is read at service start instead. See
# `renderEnvValue` and the `secretEnvValue` section of modules/config.nix.
{ lib }:

let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    escape
    filter
    splitString
    ;

  # ── Keys that must never be written to a store file ─────────────────────────
  # These are the dotted config.yaml paths whose values are credentials. They
  # are filtered out of the rendered YAML *as defence in depth*: the module
  # asserts that they are empty, so a bare import that bypasses the assertion
  # still cannot leak one into the store.
  secretConfigPaths = [
    "ssl.keyPassphrase"
    "basicAuthUser.password"
    "requestProxy.url"
  ];

  # ── Named-profile buckets ───────────────────────────────────────────────────
  #
  # The UI offers a dropdown of SAVED, NAMED items in a dozen places: the Text
  # Completion presets, the AI Response Configuration presets, the Instruct /
  # Context / Sysprompt / Reasoning templates, the themes, the lorebooks, the
  # quick-reply sets, the Moving UI layouts, the ComfyUI workflows.
  #
  # Every one of them is the same thing on disk: ONE JSON FILE PER ITEM, in a
  # per-user directory under the data root, named after the item. That is why
  # they can all be described by a single `presets` option group instead of
  # thirteen near-identical ones.
  #
  # `presetDirectories` is the mapping from a Nix bucket name to the directory
  # upstream reads it from. The authority is `USER_DIRECTORY_TEMPLATE` in
  # `src/constants.js`; the two places that consume it are
  # `getPresetSettingsByAPI` in `src/endpoints/presets.js` and
  # `getUserTargetByType` in `src/endpoints/content-manager.js`.
  #
  # The names are the upstream DIRECTORY names, spelled the way upstream
  # spells them, because these strings end up as paths. `TextGen Settings` has
  # a space and a capital S; `movingUI` is camel-cased; `QuickReplies` is one
  # word. Getting any of them wrong produces a file the server never reads.
  presetDirectories = {
    # The four backend preset managers. `src/endpoints/presets.js` maps the
    # API id to the directory: `textgenerationwebui` -> textGen_Settings,
    # `openai` -> openAI_Settings, `novel` -> novelAI_Settings,
    # `kobold`/`koboldhorde` -> koboldAI_Settings.
    textGeneration = "TextGen Settings";
    openai = "OpenAI Settings";
    novel = "NovelAI Settings";
    kobold = "KoboldAI Settings";

    # The "Advanced Formatting" group: instruct / context / sysprompt /
    # reasoning. `src/endpoints/presets.js` gives all four their own
    # directory, and `public/scripts/preset-manager.js` calls them the
    # "Advanced Formatting" group for UI purposes.
    instruct = "instruct";
    context = "context";
    sysprompt = "sysprompt";
    reasoning = "reasoning";

    # Themes, Moving UI layouts and quick-reply sets.
    themes = "themes";
    movingUi = "movingUI";
    quickReplies = "QuickReplies";

    # World Info books, and the ComfyUI workflows.
    worlds = "worlds";
    workflows = "user/workflows";
  };

  # The API ids whose preset-manager label is read from a `name` field INSIDE
  # the JSON, rather than from the file name.
  #
  # Read off the client, not guessed:
  #
  #   * `public/scripts/preset-manager.js` `getPresetList()` — for `context`,
  #     `instruct`, `sysprompt` and `reasoning` it computes
  #     `preset_names = presets.map(x => x.name)`, while the four backend
  #     presets take their names from the server's `*_setting_names`, which
  #     `src/endpoints/settings.js` builds from the FILE names.
  #   * `public/scripts/power-user.js` — the theme and Moving UI dropdowns are
  #     built from `theme.name` and `movingUIPreset.name`.
  #   * `public/scripts/extensions/quick-reply/src/QuickReplySet.js` — the
  #     quick-reply set dropdown is built from `qrs.name`.
  #
  # World Info is the exception on the other side: the server sends
  # `world_names`, which `src/endpoints/settings.js` derives from the FILE
  # names, so a world's label is its file name.
  #
  # The `presets` check re-derives this from the same sources, so an upstream
  # change here fails the build rather than leaving a bucket whose presets
  # would appear in the dropdown as "undefined".
  presetLabelFromContentApiIds = [
    "context"
    "instruct"
    "reasoning"
    "sysprompt"
  ];

  # The buckets whose dropdown label is read from a `name` field INSIDE the
  # JSON, rather than from the file name.
  presetNameFromContentBuckets =
    lib.map (apiId: presetApiIds.${apiId}) presetLabelFromContentApiIds
    ++ [
      "movingUi"
      "quickReplies"
      "themes"
    ];

  # The `USER_DIRECTORY_TEMPLATE` KEY each bucket reads from.
  #
  # `presetDirectories` above holds the directory NAME; this holds the name of
  # the constant that holds it. The two are different strings — the key is
  # `textGen_Settings` and the directory is `TextGen Settings` — and upstream
  # uses the key in `directories.textGen_Settings` while the directory is what
  # ends up on disk.
  #
  # The `presets` check in `lib/tests.nix` reads upstream's
  # `src/constants.js` and `src/endpoints/presets.js` and asserts that this
  # mapping and `presetDirectories` still agree with them, so an upstream
  # rename fails the build instead of producing files the server never reads.
  presetDirectoryKeys = {
    textGeneration = "textGen_Settings";
    openai = "openAI_Settings";
    novel = "novelAI_Settings";
    kobold = "koboldAI_Settings";
    instruct = "instruct";
    context = "context";
    sysprompt = "sysprompt";
    reasoning = "reasoning";
    themes = "themes";
    movingUi = "movingUI";
    quickReplies = "quickreplies";
    worlds = "worlds";
    workflows = "comfyWorkflows";
  };

  # The API ids upstream's preset manager uses, and the bucket each one is.
  #
  # `src/endpoints/presets.js` `getPresetSettingsByAPI` is the authority: it
  # switches on the API id and returns the directory. `koboldhorde` falls
  # through to `kobold` there, and `public/scripts/preset-manager.js` does the
  # same before it looks the manager up.
  presetApiIds = {
    textgenerationwebui = "textGeneration";
    openai = "openai";
    novel = "novel";
    kobold = "kobold";
    koboldhorde = "kobold";
    instruct = "instruct";
    context = "context";
    sysprompt = "sysprompt";
    reasoning = "reasoning";
  };

  # The upstream facts, in the shape the `presets` check compares against.
  #
  # `template` is the constant key -> the directory it holds, for the buckets
  # this module knows about. `apiTemplateKeys` is the API id -> the constant
  # key it reads from.
  #
  # The upstream `USER_DIRECTORY_TEMPLATE` has thirty-odd entries and this
  # module claims thirteen of them; the check compares the module's subset
  # against upstream's, not the whole table.
  presetFacts = {
    template = lib.mapAttrs' (
      bucket: key: lib.nameValuePair key presetDirectories.${bucket}
    ) presetDirectoryKeys;
    apiTemplateKeys = lib.mapAttrs' (
      apiId: bucket: lib.nameValuePair apiId presetDirectoryKeys.${bucket}
    ) presetApiIds;

    # Which buckets take their dropdown label from inside the JSON. The
    # `presets` check re-derives this from the client source and compares.
    labelFromContent = {
      apiIds = presetLabelFromContentApiIds;
      themes = lib.elem "themes" presetNameFromContentBuckets;
      movingUi = lib.elem "movingUi" presetNameFromContentBuckets;
      quickReplies = lib.elem "quickReplies" presetNameFromContentBuckets;
    };
  };

  # Turn a `presets` tree into the `files` tree it stands for.
  #
  # The point of the `presets` group is that the user writes a NAME and the
  # directory is derived, so nobody has to know that the Text Completion
  # presets live in a directory called "TextGen Settings". This is the
  # translation, and it is the only place the derivation happens.
  #
  # The `.json` extension is appended here, so the option's keys are bare
  # names.
  #
  # For the buckets whose label comes from the JSON, the `name` field IS the
  # label. It is injected from the key when absent, so the user writes the
  # name ONCE and a preset can never appear in the dropdown as "undefined"
  # because the field was forgotten. An explicit `name` in the content WINS
  # over the key — the assertion in `modules/assertions.nix` then checks the
  # two agree, because a preset whose label and file name disagree is a
  # preset nobody can find.
  mkPresetFiles =
    presets:
    # Flattened: one `{ "<directory>/<name>.json" = entry; }` map, whatever
    # bucket each entry came from. The buckets are a NAMESPACE, not a level
    # of nesting, because upstream reads them from sibling directories.
    lib.mergeAttrsList (
      # `lib.map` passes ONE argument, so the bucket is bound by the lambda
      # and the entries are looked up inside it. A two-argument lambda here
      # would be partially applied and `mergeAttrsList` would be handed a
      # function.
      lib.map (bucket:
        lib.mapAttrs' (name: entry:
          lib.nameValuePair "${presetDirectories.${bucket}}/${name}.json" (
            if
              lib.elem bucket presetNameFromContentBuckets
              && entry.json != null
              && lib.isAttrs entry.json
            then
              entry // {
                json = {
                  name = name;
                } // entry.json;
              }
            else
              entry
          )
        ) presets.${bucket}
      ) (lib.attrNames presets)
    );

  # ── YAML scalar rendering ───────────────────────────────────────────────────
  #
  # Strings are ALWAYS double-quoted rather than emitted bare. SillyTavern's
  # config.yaml is full of scalars that look like other types: the IPv6
  # wildcards `::1` and `[::]` (a bare `[::]` is a YAML *flow sequence*), the
  # CIDR ranges `127.0.0.0/8`, the byte sizes `100mb` (which must not become
  # `100` when something coerces it), the mime-ish `allow_adult`, and the
  # empty string `""`. Quoting unconditionally removes the entire class of bug
  # where a value round-trips through a hand-rolled emitter as a different type
  # than it went in as.
  #
  # `escape` handles the two characters that are load-bearing inside a YAML
  # double-quoted scalar: the backslash itself, and the double quote. Control
  # characters are not escaped, which is a real (if theoretical) gap — see the
  # "contains a newline" assertion in modules/assertions.nix, which is where that
  # is actually enforced rather than papered over here.
  renderYamlString = s: ''"${escape [ "\"" "\\" ] s}"'';

  # A YAML scalar that is not a string. Bools are lowercased (YAML 1.1 and 1.2
  # both accept `true`/`false`; the `yaml` package also accepts `True`, but
  # lowercasing keeps the output byte-identical to upstream's).
  renderYamlScalar =
    v:
    if v == null then
      "null"
    else if builtins.isBool v then
      if v then "true" else "false"
    else if builtins.isInt v || builtins.isFloat v then
      toString v
    else
      renderYamlString (toString v);

  # ── renderYaml ──────────────────────────────────────────────────────────────
  #
  # Block-style YAML for an arbitrarily nested attrset of scalars, lists,
  # attrsets, and lists of any of those (config.yaml's `requestOverrides` is a
  # list of `{ hosts, headers }` objects).
  #
  # `depth` is the nesting DEPTH of the mapping being emitted, and it starts at 0
  # for a document root. The top level is NOT indented; each level of nesting
  # adds two spaces. Everything below threads an explicit `pad` STRING rather
  # than a depth, because the one case that cannot be expressed as "depth + 1"
  # is a mapping that starts on a `- ` sequence line — there the first key has
  # to sit at `pad + "  - "` and every sibling at `pad + "    "`.
  #
  # Built by explicit string concatenation rather than a `''` template with
  # interpolated fragments, because Nix strips a template's minimum indentation
  # but does NOT re-indent an interpolated value — so a multi-line fragment
  # lands with whatever indentation its own template had.
  #
  # Ordering is `lib.sort` by key so the output is deterministic: Nix attrsets
  # have no defined iteration order for a human, and a config file that
  # reshuffles itself between evaluations produces spurious diffs.
  renderYaml =
    depth: value:
    let
      # `lib.replicate` returns a LIST, so it has to be concatenated — using it
      # directly as `pad` makes every interpolation below fail with
      # "cannot coerce a list to a string: [ ]".
      pad = lib.concatStrings (lib.replicate (depth * 2) " ");

      sortedEntries = attrs: map (name: { inherit name; value = attrs.${name}; }) (lib.sort (a: b: a < b) (lib.attrNames attrs));

      # One `key: value` (or `key:` + nested block) line, rendered at `at`.
      renderEntry =
        at: name: v:
        if builtins.isList v then
          renderSeqAt at name v
        else if builtins.isAttrs v then
          if v == { } then "${at}${name}: {}" else "${at}${name}:\n" + renderMapping (at + "  ") v
        else
          "${at}${name}: ${renderYamlScalar v}";

      # A mapping's lines, each at `at`. Used for both document roots and
      # nested blocks.
      renderMapping =
        at: attrs:
        concatStringsSep "\n" (map (e: renderEntry at e.name e.value) (sortedEntries attrs));

      # A sequence's lines, rendered at `at` (the column of the OWNING key).
      #
      # An empty block sequence is `name: []`. `name:` alone is a null, not an
      # empty list, and the server calls `.map()` / iterates these.
      #
      # Sequence items are indented two spaces PAST their key rather than
      # sitting in the key's own column. Indentless sequences are legal YAML,
      # but they are ambiguous after a scalar sibling: given
      #
      #     maxAge: null
      #     - "OPTIONS"
      #
      # a real YAML parser reads that as a block sequence belonging to
      # `maxAge`, and `cors.methods` disappears. (Caught by round-tripping the
      # whole rendered file through the `yaml` npm package SillyTavern actually
      # uses — not by reading it.) Indenting costs two spaces and removes the
      # class of bug entirely. It also matches upstream's own style, so a
      # rendered file still diffs cleanly against `default/config.yaml`.
      #
      # Items go through `renderYamlScalar`, not `renderYamlString`, so that
      # integer lists stay integers — `thumbnails.dimensions.bg` is `[160, 90]`
      # and quoting it would make the server's `parseInt` on a string the only
      # thing keeping it working. (Also caught by the round-trip.)
      renderSeqAt =
        at: name: v:
        if v == [ ] then
          "${at}${name}: []"
        else
          "${at}${name}:\n" + concatStringsSep "\n" (map (item: renderSeqItem (at + "  ") item) v);

      # One `- …` line at `at`, where `at` is the column of the dash.
      renderSeqItem =
        at: item:
        if builtins.isAttrs item && item != { } then
          # A mapping inside a sequence. The dash occupies two columns, so every
          # key of the item lines up at `at + "  "`; the first rides on the dash
          # line and the rest follow:
          #
          #     requestOverrides:
          #       - hosts:
          #           - "example.com"
          #         headers:
          #           Content-Type: "application/json"
          #
          # `inner` is where the item's keys go. It must be `at + "  "`, NOT
          # `at + "    "`: a YAML parser requires every key of one mapping to
          # start at the same column, and with the wider pad `hosts` lands two
          # columns right of `headers` and the file fails to parse with
          # "All mapping items must start at the same column".
          let
            inner = at + "  ";
            entries = sortedEntries item;
            first = builtins.head entries;
            rest = builtins.tail entries;
          in
          "${at}- " + lib.removePrefix inner (renderEntry inner first.name first.value)
          + concatStringsSep "" (map (e: "\n" + renderEntry inner e.name e.value) rest)
        else
          "${at}- ${renderYamlScalar item}";
    in
    if builtins.isAttrs value && value != { } then renderMapping pad value else renderYamlScalar value;

  # ── systemd EnvironmentFile rendering ───────────────────────────────────────
  #
  # systemd's `EnvironmentFile=` parser is *not* shell and *not* POSIX: it takes
  # `KEY=VALUE`, where VALUE is a sequence of zero or more single-quoted,
  # double-quoted or unquoted shell-like words. Inside double quotes it honours
  # `\` escapes; inside single quotes it does not.
  #
  # We always double-quote and escape `\` and `"`. That is the only quoting
  # mode where a value containing a newline, a `$` or a `\` is unambiguous —
  # which matters because these are secrets a human typed, and a password
  # containing a double quote is not exotic.
  #
  # Control characters other than newline are rejected upstream of here
  # (modules/assertions.nix); a literal newline inside a double-quoted
  # EnvironmentFile value is not representable, so it is caught there too.
  renderEnvValue = v: ''"${escape [ "\\" "\"" ] (toString v)}"'';

  # A single `KEY=value` line.
  renderEnvLine = name: value: "${name}=${renderEnvValue value}";

  # Rendered `EnvironmentFile=` content from an attrset of NAME -> string.
  # Sorted for the same determinism reason as renderYaml.
  renderEnvFile =
    entries:
    concatStringsSep "\n" (map (name: renderEnvLine name entries.${name}) (lib.sort (a: b: a < b) (lib.attrNames entries)));

  # ── keyToEnv — the config-path -> environment-variable mapping ──────────────
  #
  # Mirrors `src/util.js`:
  #
  #   keyToEnv = (key) => 'SILLYTAVERN_' + String(key).toUpperCase().replace(/\./g, '_')
  #
  # This is deliberately a reimplementation rather than something derived from
  # the JS: the JS uppercases with JavaScript's `String.prototype.toUpperCase`,
  # which for the ASCII-only key space of config.yaml is identical to Nix's
  # `toUpperCase`. The mapping does NOT split camelCase, so
  # `browserLaunch.enabled` becomes `SILLYTAVERN_BROWSERLAUNCH_ENABLED` and
  # `enableCorsProxy` becomes `SILLYTAVERN_ENABLECORSPROXY` — note the missing
  # underscore before CORSPROXY. Getting this wrong is silent, which is exactly
  # why it lives in one place; the `libHelpers` check in lib/tests.nix pins the
  # mapping against upstream's real function, over every key path in
  # default/config.yaml, so a "harmless" cleanup fails the build BY NAME.
  # (It did once — see RUN-LOG.md.)
  keyToEnv =
    key: "SILLYTAVERN_" + lib.toUpper (builtins.replaceStrings [ "." ] [ "_" ] key);

  # ── node-persist key layout ─────────────────────────────────────────────────
  #
  # SillyTavern does NOT store users in a JSON file. `src/users.js` initialises
  # a node-persist store at `$DATA_ROOT/_storage` and each datum is a file whose
  # NAME is the hex sha256 of its key:
  #
  #   $DATA_ROOT/_storage/<sha256hex(key)>    ->  {"key":…,"value":…,"ttl":…}
  #
  # (Verified against node-persist 4.0.4: `getDatumPath` is
  # `path.join(dir, sha256(key))` with `sha256 = crypto.createHash('sha256')
  # .update(key).digest('hex')`, and `setItem` writes `JSON.stringify({key, value,
  # ttl})`.) The user key is `user:<handle>` (`KEY_PREFIX = 'user:'`).
  #
  # `userKeyFor` builds that key. The digest itself is computed in Python by
  # scripts/st_seed_users.py, because Nix has no sha256 over strings without
  # going through a derivation — and the seeder needs the same digest anyway.
  userKeyFor = handle: "user:${handle}";

  # ── CLI rendering ───────────────────────────────────────────────────────────
  #
  # yargs boolean flags accept `--flag` and `--flag=false`, and yargs number /
  # string flags accept `--flag value`. Emitting the explicit `--flag=<value>`
  # form for *everything* is the only encoding that round-trips: `--whitelist`
  # alone is indistinguishable from "not passed" to a reader, and the server
  # falls back to config.yaml whenever a flag is absent, so a bare boolean flag
  # that means `false` would silently do nothing.
  #
  # Flags whose value is an empty list are omitted entirely — there is no way to
  # express "an empty bypass list" on the command line, and emitting
  # `--requestProxyBypass` with nothing after it would make yargs consume the
  # NEXT flag as its value. See `cliArgv`'s doc comment for the full contract.
  renderCliArgv =
    flags:
    let
      # Sorted so argv is stable across evaluations; the flag order is
      # irrelevant to yargs but very relevant to diffs.
      ordered = lib.sort (a: b: a < b) (lib.attrNames flags);
      render =
        name: value:
        let
          flag = "--${name}";
        in
        if value == true then
          "--${name}=true"
        else if value == false then
          "--${name}=false"
        else if builtins.isList value then
          # Empty list: no representation, see above.
          if value == [ ] then null else concatMapStringsSep " " (e: "${flag} ${renderCliArgvScalar e}") value
        else if value == null then
          null
        else
          "${flag}=${renderCliArgvScalar value}";
    in
    concatStringsSep " " (filter (x: x != null) (map (name: render name flags.${name}) ordered));

  # ── renderCliArgvList ───────────────────────────────────────────────────────
  #
  # The SAME flags as `renderCliArgv`, but as a LIST of argv elements — one
  # element per argument, never a single joined string.
  #
  # This is what the systemd unit must use. `ExecStart` is `listOf str`, and
  # systemd passes each list element to the process as ONE argv entry, with no
  # word splitting and no quote removal. So the string form is actively harmful:
  # `lib.escapeShellArg` wraps the whole command line in single quotes, systemd
  # strips them and hands the process a single argument containing spaces, yargs
  # sees one malformed flag, and `--configPath`, `--dataRoot` and `--global` are
  # ALL silently ignored. Observed live: the server started, ignored the
  # StateDirectory entirely, and created ~/.local/share/SillyTavern.
  #
  # Empty list values are still omitted for the reason given on `renderCliArgv`.
  renderCliArgvList =
    flags:
    let
      ordered = lib.sort (a: b: a < b) (lib.attrNames flags);
      render =
        name: value:
        let
          flag = "--${name}";
        in
        if value == true then
          [ "${flag}=true" ]
        else if value == false then
          [ "${flag}=false" ]
        else if builtins.isList value then
          if value == [ ] then [ ] else lib.concatMap (e: [ flag (toString e) ]) value
        else if value == null then
          [ ]
        else
          # `--flag=value` as ONE element. A value containing spaces is safe
          # here precisely because systemd does not split list elements.
          [ "${flag}=${toString value}" ];
    in
    lib.concatMap (name: render name flags.${name}) ordered;

  # A single CLI scalar. Only a space or an empty string needs quoting; yargs
  # does not otherwise interpret shell metacharacters, but the unit's argv is
  # assembled through a shell (`ExecStart`), so a value with a space must be
  # quoted to survive it.
  renderCliArgvScalar = v: let s = toString v; in if builtins.match ".*[ ].*" s != null then lib.escapeShellArg s else s;

  # ── Config tree helpers ─────────────────────────────────────────────────────

  # Remove the secret leaves from a config tree, by dotted path. Used on the
  # tree that is about to be rendered into the store.
  #
  # `removeAttrs` alone cannot express this: the paths are nested
  # (`ssl.keyPassphrase`), and removing `ssl` wholesale would also drop
  # `ssl.enabled`, `ssl.certPath` and `ssl.keyPath`.
  stripSecretPaths =
    tree:
    lib.foldl' (acc: path: removePath acc (splitString "." path)) tree secretConfigPaths;

  # Remove one dotted path from a nested attrset, leaving its siblings — and its
  # ancestors' other children — intact.
  removePath =
    tree: parts:
    if parts == [ ] then
      tree
    else
      let
        name = lib.head parts;
        rest = lib.tail parts;
      in
      if !(tree ? ${name}) then
        tree
      else if rest == [ ] then
        lib.removeAttrs tree [ name ]
      else
        tree // { ${name} = removePath tree.${name} rest; };

  # Read a dotted path out of a nested attrset, or `fallback` if absent.
  getPath =
    tree: path: fallback:
    let
      parts = splitString "." path;
    in
    lib.foldl' (node: part: if node ? ${part} then node.${part} else fallback) tree parts;

  # True when the tree holds a non-empty value at `path`. Used to decide whether
  # a secret needs an environment entry at all.
  pathIsSet =
    tree: path:
    let v = getPath tree path null; in v != null && v != "";

  # ── deepMerge — recursive attrset merge ────────────────────────────────────
  #
  # `//` is SHALLOW. `{ oai_settings = { a = 1; b = 2; }; } // { oai_settings = { a = 9; }; }`
  # does not override the leaf `a` — it discards `b` along with everything else
  # under `oai_settings`. That is the exact behaviour this project needs and
  # `//` cannot provide, and it has caused a real bug: a per-account settings
  # override silently dropped the sibling keys it was supposed to leave alone,
  # which the seeder then wrote to disk and the server read back as missing.
  #
  # Merge rules, in order:
  #   * both sides attrsets -> recurse per key, union of key sets
  #   * otherwise           -> the RIGHT side wins
  #
  # The right side wins on a type conflict (say, an attrset overridden by a
  # scalar), which is the same "more specific wins" rule the docs describe.
  # Lists are values, not things to concatenate: overriding `bypass = [ "a" ]`
  # with `[ "b" ]` means `[ "b" ]`, and anything else would be surprising.
  deepMerge =
    left: right:
    if builtins.isAttrs left && builtins.isAttrs right then
      lib.foldl'
        (
          acc: key:
          let
            inLeft = builtins.hasAttr key left;
            inRight = builtins.hasAttr key right;
            # Only recurse when BOTH sides have an attrset under this key;
            # otherwise the right-hand value wins outright.
            merged =
              if inLeft && inRight && builtins.isAttrs left.${key} && builtins.isAttrs right.${key} then
                deepMerge left.${key} right.${key}
              else
                right.${key};
          in
          # `{ ${key} = merged; }` sets the VALUE at that key. Writing
          # `{ inherit key; value = …; }` would instead add two literal
          # attributes called `key` and `value` to the result.
          if inRight then acc // { ${key} = merged; } else acc
        )
        left
        (builtins.attrNames right)
    else right;

  # ── leafPaths ───────────────────────────────────────────────────────────────
  #
  # The dotted paths of every LEAF in a JSON-shaped attrset.
  #
  #   { oai_settings = { openai_max_context = 4096; }; }
  #     → [ "oai_settings.openai_max_context" ]
  #
  # This is what the settings-key guard needs: `settings.json` is read by
  # direct property access, so the *path* is the identity of a setting, and a
  # path that does not exist upstream is a setting that will never be read.
  #
  # Lists are leaves (their contents are data, not structure), and so is an
  # empty attrset (an object with no children has no leaves of its own).
  leafPaths =
    attrs:
    lib.concatMap
      (name:
        let
          value = attrs.${name};
        in
        if lib.isAttrs value && value != { } then
          map (path: "${name}.${path}") (leafPaths value)
        else
          [ name ])
      (lib.attrNames attrs);

  # ── leafEntries ────────────────────────────────────────────────────────────
  #
  # The same walk as `leafPaths`, but each leaf comes with its VALUE.
  #
  #   { oai_settings = { openai_max_context = 4096; }; }
  #     → [ { path = "oai_settings.openai_max_context"; value = 4096; } ]
  #
  # `leafPaths` is enough to ask "does this path exist?"; this is what a type
  # check needs, because a path can be real and still hold the wrong kind of
  # thing — and in JavaScript a string "false" is TRUTHY, so
  # `power_user.waifuMode = "false"` is not a harmless typo.
  leafEntries =
    attrs:
    lib.concatMap
      (name:
        let
          value = attrs.${name};
        in
        if lib.isAttrs value && value != { } then
          map (entry: {
            path = "${name}.${entry.path}";
            inherit (entry) value;
          }) (leafEntries value)
        else
          [
            {
              path = name;
              inherit value;
            }
          ])
      (lib.attrNames attrs);
in
{
  inherit
    secretConfigPaths
    presetDirectories
    presetNameFromContentBuckets
    presetDirectoryKeys
    presetApiIds
    presetFacts
    mkPresetFiles
    keyToEnv
    userKeyFor
    renderYaml
    renderYamlScalar
    renderYamlString
    renderEnvValue
    renderEnvLine
    renderEnvFile
    renderCliArgv
    renderCliArgvList
    renderCliArgvScalar
    stripSecretPaths
    deepMerge
    getPath
    pathIsSet
    leafPaths
    leafEntries
    ;

  # ── mkUserArg ───────────────────────────────────────────────────────────────
  #
  # Resolves one `services.sillytavern-nixos.users.<handle>` spec into the flat shape
  # scripts/st_seed_users.py consumes on its command line.
  #
  # `name` falls back to the handle, because that is what the server would have
  # used anyway (DEFAULT_USER in src/constants.js pairs them) and a display name
  # equal to the handle is less surprising than a blank field.
  mkUserArg =
    handle: spec:
    {
      inherit handle;
      name = if spec.name != null then spec.name else handle;
      inherit (spec) admin enabled;
      passwordFile = spec.passwordFile;
    };

  # ── mkProxyUpstreams ────────────────────────────────────────────────────────
  #
  # Returns `[{ name, port, path, stripPrefix, displayName, hosts, maxBodySize,
  # forwardedFor, readTimeout; }]` describing how
  # to reach the instance, so a consumer can wire it into whatever reverse
  # proxy module they use without this project depending on that module — the
  # same trick `nixos-projectzomboid-servers` uses.
  #
  # SillyTavern is a single-port HTTP server with no path prefix, so `path` is
  # always "/" and `stripPrefix` is always false. Both are still emitted so the
  # shape is uniform with other services in a consumer's upstream list.
  #
  # The trailing four are the values a proxy gets wrong most often: the `Host`
  # header the host whitelist checks, the request-body ceiling, whether
  # `X-Forwarded-For` is replaced or appended, and how long a streaming LLM
  # response may stall. Each is a silent misconfiguration otherwise — a 413, a
  # blank page, or a spoofed client IP. See the option they come from.
  #
  #   proxy.upstreams = lib.mkMerge (
  #     map mkProxyUpstream config.services.sillytavern-nixos.proxyUpstreams);
  #
  #   # …or, for the default instance:
  #   proxy.upstreams = [ mkProxyUpstream { inherit config; } ];
  #
  #   # …then, per instance:
  #   nix eval --json '.#nixosConfigurations.host.config.services.sillytavern-nixos.proxyUpstreams'
  #
  # `openFirewall` is deliberately NOT handled here: a reverse proxy reaching
  # SillyTavern over loopback needs no firewall hole at all, and SillyTavern
  # does not speak TLS on its own port without extra certificates. Exposing it
  # directly is the `services.sillytavern-nixos.openFirewall` option's job, and it
  # defaults to false.
  #
  # Every parameter is OPTIONAL, which is what makes both documented call styles
  # work:
  #
  #   # A. mapped over this module's own list (one call per declared instance):
  #   map mkProxyUpstream config.services.sillytavern-nixos.proxyUpstreams
  #
  #   # B. built by hand for the default instance:
  #   mkProxyUpstream { inherit config; }
  #
  # `config` used to be REQUIRED with no default, so style A — the one in
  # docs/installing.md — failed with
  #
  #   error: function 'mkProxyUpstream' called without required argument 'config'
  #
  # because each element of `proxyUpstreams` is `{ name, port, path, ... }` and
  # carries no `config` at all. It was latent purely because the list defaults
  # to `[]`, so `map` over it never invoked the function. That is the same
  # defect modules/home.nix once had, in an exported helper, and the third time
  # this shape has bitten the project.
  #
  # `config` is therefore consulted only to FILL IN `port` when the caller did
  # not say, which is the only thing it was ever needed for.
  mkProxyUpstream =
    {
      config ? null,
      configName ? "sillytavern",
      displayName ? "SillyTavern",
      path ? "/",
      stripPrefix ? false,
      name ? configName,
      port ? null,
      hosts ? [ ],
      maxBodySize ? null,
      forwardedFor ? "replace",
      readTimeout ? null,
      ...
    }:
    {
      # `sillytavern-nixos`, NOT `sillytavern`. nixos-unstable ships its own
      # `services.sillytavern`, so that attribute always exists — reading it
      # resolved to the OTHER module, which has no `config` sub-option.
      #
      # Precedence: the element's own `port` wins, because a `proxyUpstreams`
      # entry may describe an instance on a different host. `config` is only the
      # fallback for hand-built entries.
      port =
        if port != null then
          port
        else if config != null then
          config.services.sillytavern-nixos.config.port
        else
          throw "mkProxyUpstream: no `port` given and no `config` to read one from. Pass `port = …`, or `config` to take it from services.sillytavern-nixos.config.port.";
      # `name` is what a proxy module keys its upstream list on, so it has to
      # survive: it is a PARAMETER here, which does not put it in the result.
      inherit name path stripPrefix displayName;
      # Passed straight through: a consumer's proxy module decides what to do
      # with them, and declaring them here keeps the deployment's assumptions
      # in one place rather than scattered across a vhost definition.
      inherit hosts maxBodySize forwardedFor readTimeout;
    };
}
