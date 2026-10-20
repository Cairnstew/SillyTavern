# modules/assertions.nix
#
# Validation for `services.sillytavern-nixos`.
#
# Every assertion here corresponds to a combination that is SILENTLY WRONG —
# produces no error, no warning, and a server that either dies at startup or
# does something other than what the configuration says. That is the only kind
# worth an assertion; anything that already fails loudly is not this file's job.
#
# The traps are documented at the point they are most likely to bite (usually
# the option), and the evidence for several of them was established by reading
# the server's source and then running it, not by guessing. Where a check only
# WARNS rather than refuses, the message says why being permissive is sometimes
# right — a service on a trusted LAN really is a legitimate configuration.
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.sillytavern-nixos;
  inherit (cfg.internal) effectiveConfig secretEnvFiles secretEnvValues seedSpecJson;

  st = import ../lib { inherit lib; };

  # Whether NIXPKGS' `services.sillytavern` is enabled.
  #
  # `or false` here is a DELIBERATE detection of the nixpkgs namespace, and the
  # only sanctioned exception to the rule in docs §4.1 ("any option path read
  # from another module's namespace is `services.sillytavern-nixos`"). The point
  # of the lookup is to notice nixpkgs' module, so reading it is the whole job.
  #
  # `or false` rather than a bare read because this module is also evaluated in
  # the flake's minimal test systems, where a slimmed module list may not carry
  # it at all. Absent and `enable = false` mean the same thing here, and both
  # mean "not a conflict".
  upstreamEnabled = config.services.sillytavern.enable or false;

  # `default-user` is created by the server itself on first start, so it is a
  # legitimate seed target without being a declared account.
  declaredHandles = builtins.attrNames cfg.users ++ [ "default-user" ];
  seedHandles = lib.unique (
    lib.attrNames cfg.settings.byUser
    ++ lib.attrNames cfg.files.byUser
    ++ lib.attrNames cfg.presets.byUser
    ++ lib.attrNames cfg.secrets.byUser
  );

  # Every `files` entry, as { handle, path, entry } triples, so an assertion can
  # name the exact declaration that is wrong rather than failing with an opaque
  # type error from `mapAttrs`.
  #
  # `files.common` is tagged with a literal handle of "common" purely so the
  # resulting message can say which map a bad path came from; nothing seeds
  # under that name.
  fileEntries =
    lib.mapAttrsToList (
      path: entry: { handle = "files.common"; inherit path entry; }
    ) cfg.files.common
    ++ lib.concatLists (
      lib.mapAttrsToList (
        handle: map:
          lib.mapAttrsToList (path: entry: { inherit handle path entry; }) map
      ) cfg.files.byUser
    );

  # Every `presets` declaration, as { handle, bucket, name, path, entry }.
  #
  # `presets` and `files` are two VIEWS of the same files, so a preset
  # declaration has a path — the one `st.mkPresetFiles` will derive from it.
  # The assertions below need that path to compare the two views.
  presetEntries =
    # `concatLists` because the inner `mapAttrsToList` returns a LIST of
    # entries per bucket, and the outer one collects those lists — without
    # flattening, every "entry" here is a list, and `e.name` on a list fails
    # with an error that says nothing about presets.
    lib.concatLists (
      lib.mapAttrsToList (
        bucket: entries:
          lib.mapAttrsToList (
            name: entry: {
              handle = "presets.common";
              inherit bucket name entry;
              path = "${st.presetDirectories.${bucket}}/${name}.json";
            }
          ) entries
      ) cfg.presets.common
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        handle: buckets:
          lib.concatLists (
            lib.mapAttrsToList (
              bucket: entries:
                lib.mapAttrsToList (
                  name: entry: {
                    inherit handle bucket name entry;
                    path = "${st.presetDirectories.${bucket}}/${name}.json";
                  }
                ) entries
            ) buckets
          )
      ) cfg.presets.byUser
    );

  # The buckets whose dropdown label is a `name` field INSIDE the JSON, and
  # whose entries therefore have a name that can DISAGREE with the key.
  #
  # `st.mkPresetFiles` fills the field in from the key when it is missing, so a
  # preset can never show up as "undefined". It cannot fix a field that is
  # present and wrong, so that case is an assertion.
  presetNameMismatches = builtins.filter (
    e:
      lib.elem e.bucket st.presetNameFromContentBuckets
      && e.entry.json != null
      && lib.isAttrs e.entry.json
      && e.entry.json ? name
      && e.entry.json.name != e.name
  ) presetEntries;

  # A name becomes a FILE NAME, so it must not be a path.
  #
  # A `/` in the name would create a subdirectory the server never reads, and
  # `..` would climb out of the account's directory entirely. Neither is
  # refused loudly anywhere else: the seeder would write the file and the
  # dropdown would simply not show it.
  illegalPresetNames = builtins.filter (
    e: (lib.hasInfix "/" e.name) || e.name == ".." || e.name == "."
  ) presetEntries;

  # The same file declared through BOTH views.
  #
  # `presets` derives a path from a bucket and a name; `files` states a path.
  # Declaring the same file in both is not a merge — it is two claims on one
  # file, and the merge in `modules/config.nix` would silently let `files`
  # win, so the `presets` declaration would quietly do nothing.
  #
  # Compared per ACCOUNT, because that is the scope in which the two views
  # actually collide: `presets.common` applies to every account, and so does
  # `files.common`.
  allHandles = lib.unique (
    declaredHandles
    ++ lib.map (e: e.handle) (builtins.filter (e: e.handle != "presets.common") presetEntries)
    ++ lib.map (e: e.handle) (builtins.filter (e: e.handle != "files.common") fileEntries)
  );

  presetFilesCollisions =
    lib.unique (
      lib.concatMap
        (handle:
          let
            presetPaths =
              lib.map (e: e.path) (
                builtins.filter (e: e.handle == handle || e.handle == "presets.common") presetEntries
              );
            filePaths =
              lib.map (e: e.path) (
                builtins.filter (e: e.handle == handle || e.handle == "files.common") fileEntries
              );
          in
          lib.map (path: { inherit handle path; }) (
            builtins.filter (p: lib.elem p filePaths) presetPaths
          )
        )
        allHandles
    );

  # The seeder's deny-list, mirrored here.
  #
  # `scripts/st_seed_files.py` refuses these at ACTIVATION time. It does so by
  # raising `SeedError` on the FIRST bad entry, which `main()` turns into exit
  # code 2 — and `main` is the last command in the unit's `preStart`, so the
  # `ExecStartPre` fails and THE UNIT DOES NOT START. Entries visited before the
  # bad one have already been written, leaving a half-seeded data root.
  #
  # Verified live: a spec with `backups/bad.json` between two good entries wrote
  # the first, refused the second, skipped the third, and exited 2.
  #
  # So a single typo here means `nixos-rebuild switch` reports success and the
  # service is simply dead afterwards. This file's entire reason for existing is
  # configurations that fail silently, and that is exactly what an unchecked
  # reserved path is.
  #
  # Kept deliberately in sync with the Python by nix-tests/test_seed_files.py,
  # which reads these same names back out of `src_seed_files` — so drift in
  # either direction fails the suite rather than sitting here quietly.
  #
  # `config.yaml` is refused because a `configPath` is the supported route (see
  # `cli.configPath`); `stats.json` is pure server bookkeeping; `secrets.json`
  # is owned by the `secrets` mechanism, which writes the array-of-records shape
  # the server actually reads.
  reservedBasenames = [ "stats.json" "config.yaml" "secrets.json" ];

  # Matched against the FIRST path component only, exactly as
  # `safe_join` does (`parts[0]`). So `backups/x.json` is refused but
  # `user/backups/x.json` — a per-user directory that happens to be named
  # `backups` inside some other folder — is not, which is correct because the
  # seeder resolves per-account paths against the account directory.
  reservedTopLevel = [ "_storage" "_webpack" "_sc" "_cache" "backups" ];

  # `_errors/` is not blanket-refused: upstream serves exactly four HTML files
  # from it, and the `errorPages` options exist to write them. Anything else
  # under `_errors/` is never read, so allowing it would create a file that
  # looks meaningful and is not.
  allowedErrorPages = [
    "forbidden-by-whitelist.html"
    "host-not-allowed.html"
    "unauthorized.html"
    "url-not-found.html"
  ];

  reservedReason =
    e:
    let
      parts = lib.splitString "/" e.path;
      top = lib.head parts;
    in
    if lib.elem (builtins.baseNameOf e.path) reservedBasenames then
      "a reserved filename the server or another option owns"
    else if lib.elem top reservedTopLevel then
      "'${top}/' is reserved server state at the top level of the account directory"
    else if top == "_errors" && !(lib.elem (lib.concatStringsSep "/" (lib.tail parts)) allowedErrorPages) then
      "'_errors/' only accepts upstream's four error pages — use the errorPages options"
    else
      "";

  refusedFiles = builtins.filter (e: reservedReason e != "") fileEntries;

  # Flattened { handle, key, entry } triples so one bad entry reports its exact
  # location instead of failing with an opaque `mapAttrs` type error.
  secretEntries = lib.concatLists (
    lib.mapAttrsToList (
      handle: lib.mapAttrsToList (key: entry: { inherit handle key entry; })
    ) cfg.secrets.byUser
  );

  # Settings subtrees that contain a dotted attribute NAME. Such a key
  # type-checks but is inert at runtime — see the assertion below.
  #
  # The candidates are the per-GROUP subtrees, not the per-account maps:
  # `settings.common` and each `settings.byUser.<handle>` are both
  # `{ <group> = { … }; }`, and it is the inner `<group>` level that can hold
  # a dotted key. `settings.byUser` as a whole is `{ <handle> = { … }; }`,
  # whose keys are handles, so it is flattened one level before filtering —
  # otherwise `lib.filter` would be handed the `byUser` attrset itself.
  flatDottedSettings =
    let
      hasDots = set: builtins.any (name: lib.hasInfix "." name) (builtins.attrNames set);
      oneLevel = set:
        builtins.any (name: let v = set.${name}; in builtins.isAttrs v && hasDots v)
          (builtins.attrNames set);
      # Every per-account settings map, flattened into the same shape as
      # `settings.common`.
      perAccount = lib.attrValues cfg.settings.byUser;
      candidates = [ cfg.settings.common ] ++ perAccount;
    in
    lib.filter (s: hasDots s || oneLevel s) candidates;

  # ── Settings keys that upstream does not have ──────────────────────────────
  #
  # `settings.json` is read by DIRECT PROPERTY ACCESS on the client
  # (`public/script.js`, `public/scripts/power-user.js:1566` —
  # `Object.assign(power_user, settings.power_user)`). There is no
  # dotted-path resolver, no schema, and no warning for a key that does not
  # exist. A key that upstream does not have is therefore inert: it is written
  # to disk by the seeder, it is merged over the real defaults, it changes
  # nothing, and the module reports no problem.
  #
  # That is exactly the class of failure this file exists for — silently wrong
  # — and it is a *large* class here, because `settings.common` is a free-form
  # blob with hundreds of real settings spread over seven subtrees.
  #
  # The inventory is derived from upstream's own sources by
  # `scripts/extract_settings_inventory.mjs` (the same discipline as
  # `.opencode/skills/nix-coverage/scripts/audit.py` for `config.yaml`): no key
  # is hardcoded here, and `settingsInventoryFresh` fails the build if the
  # committed inventory no longer matches the source it was derived from.
  settingsInventory = builtins.fromJSON (builtins.readFile ../lib/settings-inventory.json);

  # The 24 top-level keys the client writes. A key outside this set is not
  # merely unknown — it is DROPPED: the client's save payload is a fixed
  # object (`public/script.js:8068`), so anything the browser does not know
  # about disappears from `settings.json` at the first UI save.
  knownTopLevelKeys = settingsInventory.topLevelKeys;

  # Per subtree: the set of real leaf paths, and the paths that are free-form
  # maps (keyed by persona name, extension name, …) where any leaf is legal.
  surfaceFields = builtins.mapAttrs (
    name: surface:
    builtins.listToAttrs (map (field: { name = field.path; value = field.type; }) surface.fields)
  ) settingsInventory.surfaces;
  surfaceOpenPaths = builtins.mapAttrs (name: surface: surface.openPaths) settingsInventory.surfaces;

  # Every leaf declared in `settings.common` and in each
  # `settings.byUser.<handle>`, with its VALUE, tagged with where it came from
  # so the message can name the account.
  settingsLeaves =
    let
      entriesOf = attrs: st.leafEntries attrs;
      maps =
        [
          {
            label = "settings.common";
            entries = entriesOf cfg.settings.common;
          }
        ]
        ++ lib.mapAttrsToList (
          handle: attrs: {
            label = "settings.byUser.${handle}";
            entries = entriesOf attrs;
          }
        ) cfg.settings.byUser;
    in
    lib.concatLists (
      lib.map (map: lib.map (e: map // e) map.entries) maps
    );

  settingsLeafPaths = lib.map (e: e) settingsLeaves;

  # A leaf is legal when its path is a real upstream field, when it sits
  # under a free-form map, or when it names an upstream OBJECT (in which case
  # the value is a nested attrset and the guard is about the children, not
  # about this path).
  isKnownPath =
    surface: path:
    let
      fields = surfaceFields.${surface} or { };
      open = surfaceOpenPaths.${surface} or [ ];
      underOpen = lib.any (prefix: path == prefix || lib.hasPrefix "${prefix}." path) open;
      isObjectPath = lib.any (field: lib.hasPrefix "${path}." field) (builtins.attrNames fields);
    in
    builtins.hasAttr path fields || underOpen || isObjectPath;

  # ── Types ─────────────────────────────────────────────────────────────────
  #
  # A path can be real and still hold the wrong kind of thing, and in
  # JavaScript that is not always a loud failure:
  #
  #   * `power_user.waifuMode = "false"` — a non-empty string is TRUTHY, so
  #     the setting is ON while the configuration says OFF.
  #   * `oai_settings.custom_url = 123` — a number where a URL is expected
  #     breaks the request builder with a type error far from the cause.
  #
  # Numbers are the exception: JavaScript coerces them in arithmetic, and
  # upstream's own UI writes numeric strings in places, so a numeric field
  # accepts a number or a string.
  typeOk =
    expected: value:
    if expected == "bool" then
      lib.isBool value
    else if expected == "str" then
      lib.isString value
    else if expected == "array" then
      lib.isList value
    else if expected == "int" || expected == "float" then
      lib.isInt value || lib.isFloat value || lib.isString value
    else
      # `unknown` (an upstream constant we could not resolve), `null`, and
      # object paths have no type to check against.
      true;

  # Leaves whose value is not the type upstream's own default has.
  mistypedSettings =
    lib.filter (
      e:
      let
        parts = lib.splitString "." e.path;
        surface = lib.head parts;
        fields = surfaceFields.${surface} or { };
        relative = lib.concatStringsSep "." (lib.tail parts);
      in
      builtins.hasAttr relative fields && !(typeOk fields.${relative} e.value)
    ) settingsLeaves;

  # Top-level keys the client never writes. These are silently discarded at
  # the first save, which is worse than unknown: the value *looks* applied.
  unknownTopLevelKeys =
    lib.unique (
      lib.map (p: p.path) (
        lib.filter (p: !(builtins.elem (lib.head (lib.splitString "." p.path)) knownTopLevelKeys)) settingsLeafPaths
      )
    );

  # Leaf paths inside a known subtree that upstream does not have.
  unknownSettingPaths =
    lib.unique (
      lib.map (p: p.path) (
        lib.filter (
          p:
          let
            parts = lib.splitString "." p.path;
            surface = lib.head parts;
          in
          builtins.hasAttr surface surfaceFields && !(isKnownPath surface (lib.concatStringsSep "." (lib.tail parts)))
        ) settingsLeafPaths
      )
    );
in
{
  # Gated on `enable` as a whole, not assertion by assertion.
  #
  # `modules/sillytavern.nix` imports this file UNCONDITIONALLY (it is not
  # inside `services.nix`'s `mkIf`), so without this every one of the
  # assertions below is evaluated — and can FAIL — with the module switched
  # off. That is not hypothetical: the nixpkgs-collision assertion was written
  # without a guard and blocked a user running nixpkgs' own module who had never
  # installed ours. Adding another assertion in the same style would reproduce it.
  #
  # `mkIf` around the LIST, not around the import: gating `imports` on `config`
  # is an infinite recursion, because `config` cannot be known until every
  # imported module has been evaluated.
  #
  # `config.enableUserAccounts` and friends are not evaluated at all when the
  # module is off, which is the point.
  assertions = lib.mkIf cfg.enable [
    # ── Flat dotted keys ─────────────────────────────────────────────────────
    #
    # A key like `"oai_settings.openai_max_context" = 131072;` type-checks — the
    # option is `types.attrsOf types.anything`, which accepts any attribute
    # NAME, dots included. It renders into the seed spec as a flat JSON object
    # key, the seeder writes it to settings.json verbatim, and the server then
    # ignores it: settings are read by direct property access
    # (`public/script.js:7933` — `settings.oai_settings.openai_max_context`),
    # and there is no dotted-path resolver anywhere in the settings path.
    #
    # So it fails completely silently: the key is present in the file, the
    # module reports no problem, and the value simply never takes effect. That
    # is the definition of a configuration that is silently wrong.
    {
      assertion = flatDottedSettings == [ ];
      message = ''
        SillyTavern reads settings.json by direct property access, so a dotted
        attribute name is silently ignored — the key is written to disk and
        never read.

        Use a nested attrset instead:

            settings.byUser.seanc = {
              oai_settings.openai_max_context = 131072;   # WRONG: inert
              oai_settings = { openai_max_context = 131072; };  # right
            };

        Offending subtrees: ${builtins.toJSON flatDottedSettings}
      '';
    }
    # ── Settings keys upstream does not have ────────────────────────────────
    #
    # Two different failures, in one guard because they share a cause: the
    # client reads `settings.json` by direct property access, so a key that
    # upstream does not have is inert — and a key outside the client's own save
    # payload does not even survive the next save.
    {
      assertion = unknownTopLevelKeys == [ ] && unknownSettingPaths == [ ] && mistypedSettings == [ ];
      message =
        let
          straySection =
            if unknownTopLevelKeys == [ ] then
              ""
            else
              ''
                These settings.json keys are not among the 24 the client writes, so the browser DISCARDS them at the next save:

                ${lib.concatStringsSep "\n" (map (key: "  - ${key}") unknownTopLevelKeys)}

                A key outside the client's save payload never reaches the UI. Use one of:

                ${lib.concatStringsSep "\n" (map (key: "  - ${key}") knownTopLevelKeys)}
              '';
          unknownSection =
            if unknownSettingPaths == [ ] then
              ""
            else
              ''
                These settings.json paths are not settings SillyTavern has, so they are written to disk and then ignored:

                ${lib.concatStringsSep "\n" (map (path: "  - ${path}") unknownSettingPaths)}

                The setting names are read by direct property access; a name that does not exist upstream can never take effect. Check the spelling, and see docs/settings-surface.md for the full list of real settings.
              '';
          typeSection =
            if mistypedSettings == [ ] then
              ""
            else
              ''
                These settings.json values are not the type upstream expects:

                ${lib.concatStringsSep "\n" (
                  map (
                    e:
                    let
                      parts = lib.splitString "." e.path;
                      surface = lib.head parts;
                      relative = lib.concatStringsSep "." (lib.tail parts);
                    in
                    "  - ${e.path}: expected ${surfaceFields.${surface}.${relative}}, got ${builtins.typeOf e.value}"
                  ) mistypedSettings
                )}

                A string where upstream has a boolean is not a harmless typo: in JavaScript every non-empty string is TRUE, so the setting would be ON while the configuration says OFF.
              '';
        in
        ''
          services.sillytavern-nixos: a settings.json value is silently wrong.

          The browser reads settings.json by DIRECT PROPERTY ACCESS
          (`public/scripts/power-user.js:1566`). There is no schema, no
          dotted-path resolver and no warning, so a name that does not exist, a
          name the browser does not save, or a value of the wrong kind all fail
          without a word.

          ${lib.concatStringsSep "\n\n" (lib.filter (s: s != "") [ straySection unknownSection typeSection ])}
        '';
    }
    # ── JSON-driven state ─────────────────────────────────────────────────────
    {
      # A `byUser` handle that is not a declared account would be seeded into a
      # directory SillyTavern never adopts: it derives accounts from its own
      # `_storage` database, not from the presence of a directory. The seed
      # would silently do nothing, which is worse than failing here.
      assertion = lib.all (handle: builtins.elem handle declaredHandles) seedHandles;
      message = ''
        services.sillytavern-nixos: every handle in `settings.byUser` and
        `files.byUser` must be a declared account.

        Unrecognised: ${lib.concatStringsSep ", " (lib.filter (h: !builtins.elem h declaredHandles) seedHandles)}

        Declared accounts: ${lib.concatStringsSep ", " declaredHandles}

        SillyTavern builds its account list from its own user database, not from
        directories under the data root, so seeding an account that does not
        exist creates a directory nothing ever reads. Add the account to
        `services.sillytavern-nixos.users` first.

        `default-user` is allowed without being declared: the server creates it
        itself on first start.
      '';
    }
    {
      # A `{ json = …; path = …; }` entry with both, or neither, would fail at
      # activation time with a Python traceback rather than at eval time.
      #
      # `fileEntries` rather than the `lib.attrValues … ++ lib.concatLists …`
      # this used to do. That expression was WRONG and made the module
      # impossible to evaluate: `lib.attrValues cfg.files.byUser` yields a list
      # of ATTRSETS (one per handle), and `lib.concatLists` wants a list of
      # LISTS, so every non-empty `files.byUser` died with
      #
      #   error: expected a list but found a set: { "themes/mine.json" = «thunk»; }
      #
      # Nothing in the suite ever set `files.byUser`, so it was never forced.
      # `config.assertions` is reached by `system.build.toplevel`, which is what
      # `nixos-rebuild switch` builds, so this was not a latent test gap — it
      # made `files.byUser` unusable in anger: the per-account seeding feature
      # that docs/options.md documents as
      # `files.byUser.seanc.themes."Red.json"` failed every rebuild.
      #
      # `fileEntries` flattens both maps in one place, so there is no second
      # spelling of this to get wrong.
      assertion = lib.all (e: (e.entry.json != null) != (e.entry.path != null)) fileEntries;
      message = ''
        services.sillytavern-nixos: every entry in `files` must set exactly one
        of `json` or `path`.

        `json` writes the value literally; `path` copies a file from the store.
        Setting both is ambiguous and setting neither has no meaning, so both are
        rejected rather than guessed at.
      '';
    }
    {
      # A preset name becomes a FILE NAME, so it must not be a path.
      #
      # A `/` would put the file in a subdirectory the server never reads, and
      # `..` would climb out of the account's directory. Neither fails loudly
      # anywhere: the seeder writes the file, and the dropdown simply does not
      # show it — the "silently wrong" case this file exists for.
      assertion = illegalPresetNames == [ ];
      message = ''
        services.sillytavern-nixos: these `presets` names cannot be used as
        file names.

        ${lib.concatStringsSep "\n" (
          map (e: "  ${e.handle}.${e.bucket}.\"${e.name}\" — would be written to ${e.path}") illegalPresetNames
        )}

        A preset's name becomes its file name, with `.json` appended, so it
        must not contain a path separator and must not be `.` or `..`.
      '';
    }
    {
      # For the buckets whose dropdown label is a `name` field inside the JSON,
      # the key and the field must agree.
      #
      # The module fills the field in from the key when it is MISSING, so a
      # preset can never appear in the dropdown as "undefined". It cannot fix a
      # field that is present and wrong — and a wrong one is invisible: the
      # preset appears in the list under a name that is not the name of the
      # file it is stored in, so renaming it in the UI creates a second file
      # and the first one is orphaned.
      assertion = presetNameMismatches == [ ];
      message = ''
        services.sillytavern-nixos: these `presets` entries have a `name` that
        disagrees with the key they are declared under.

        ${lib.concatStringsSep "\n" (
          map (e: "  ${e.handle}.${e.bucket}.\"${e.name}\" — the content's `name` is \"${toString e.entry.json.name}\"") presetNameMismatches
        )}

        For these buckets the dropdown label is the `name` field inside the
        JSON, not the file name. The module fills that field in from the key
        when it is missing, so the two only have to be written once — but if
        they are both written and they disagree, the preset shows up in the
        list under a name that is not the name of the file it lives in.

        Either drop the `name` field from the content, or make it match the key.
      '';
    }
    {
      # The same file, declared through both views.
      #
      # `presets` and `files` are two views of the same files, so declaring
      # one file in both is two claims on it — and the merge in
      # `modules/config.nix` resolves it silently in favour of `files`, so the
      # `presets` declaration would do nothing at all.
      assertion = presetFilesCollisions == [ ];
      message = ''
        services.sillytavern-nixos: these files are declared through BOTH
        `presets` and `files`.

        ${lib.concatStringsSep "\n" (
          map (e: "  ${e.handle}: ${e.path}") presetFilesCollisions
        )}

        `presets` derives the path from a bucket and a name; `files` states
        the path outright. They are two views of the same files, so declaring
        one in both is ambiguous — and the merge would quietly let `files`
        win, making the `presets` declaration a no-op.

        Keep the `presets` form (it carries the name) or the `files` form (it
        carries the path), not both.
      '';
    }
    {
      # A path the seeder refuses at ACTIVATION time takes the whole unit down
      # with it: it exits 2 as the last command in `preStart`, so `ExecStartPre`
      # fails and the service never starts — after `nixos-rebuild switch` has
      # already reported success, and with the entries visited before the bad
      # one already written. Caught here, where the message can name the path.
      assertion = refusedFiles == [ ];
      message = ''
        services.sillytavern-nixos: these `files` entries name paths the seeder
        refuses.

        ${lib.concatStringsSep "\n" (
          map (e: "  ${e.handle}: ${e.path} — ${reservedReason e}") refusedFiles
        )}

        The seeder refuses them at activation, and because it exits non-zero
        from the unit's `preStart`, that makes the WHOLE SERVICE fail to start —
        not just this file. `nixos-rebuild switch` still succeeds, so the
        failure appears only as a dead service, with a partially seeded data
        root, until someone reads the journal.

        Reserved filenames: ${lib.concatStringsSep ", " reservedBasenames}

        Reserved at the top level of the account directory: ${lib.concatStringsSep ", " reservedTopLevel}

        `_errors/` accepts only upstream's four pages: ${lib.concatStringsSep ", " allowedErrorPages}

        For `config.yaml` use `services.sillytavern-nixos.cli.configPath`; for
        `secrets.json` use `secrets.byUser`. For `_errors/*.html` use the
        `errorPages` options, which take a path and write the file with mode
        0644 for you.
      '';
    }
    {
      # `mode` is a 4-digit octal STRING all the way through, because that is
      # what a Nix string literal carries and because `6440` would otherwise be
      # silently read as DECIMAL 6440 by `os.chmod`. The seeder raises on
      # anything that is not exactly four octal digits — but again at
      # activation, in the same fail-the-unit way. Checked here so a typo is an
      # eval error naming the file.
      assertion = lib.all (e: e.entry.mode == null || lib.match "[0-7]{4}" e.entry.mode != null) fileEntries;
      message = ''
        services.sillytavern-nixos: every `files` entry `mode` must be a 4-digit
        octal string such as "0644".

        ${lib.concatStringsSep "\n" (
          map (e: "  ${e.handle}: ${e.path} — mode = ${lib.strings.toJSON e.entry.mode}")
            (lib.filter (e: e.entry.mode != null && lib.match "[0-7]{4}" e.entry.mode == null) fileEntries)
        )}

        The leading zero matters: `mode = "644"` and `mode = "0644"` are the
        same intent, but only the second is accepted, so that a bare `6440`
        cannot be read as decimal. Leave `mode` unset for the default, which is
        0600 — correct for every seeded JSON file, since they sit behind an
        authenticated per-user router.
      '';
    }
    {
      # Two routes to the same file would race at activation and one would
      # silently win, depending on ordering inside `apply_spec`. `secrets.json`
      # is also the one file whose shape the `secrets` mechanism owns, so a
      # hand-written `files` entry could put it in a shape the server rejects.
      #
      # `fileEntries` again. The previous expression was
      # `lib.concatLists (lib.attrValues (lib.mapAttrs lib.attrNames cfg.files.byUser))`,
      # which is broken TWICE over: `lib.mapAttrs` calls its function as
      # `f name value`, so `lib.attrNames` (arity 1) receives the HANDLE NAME
      # where it expects the attrset, and fails with
      # `expected a set but found a string: "seanc"`.
      #
      # It only ever ran when this assertion was reached, which is why a
      # non-empty `files.byUser` broke the module rather than this line
      # obviously being wrong on sight.
      assertion = lib.all (e: builtins.baseNameOf e.path != "secrets.json") fileEntries;
      message = ''
        services.sillytavern-nixos: do not seed `secrets.json` through `files`.

        Use `services.sillytavern-nixos.secrets.byUser.<handle>.<key>.value`
        instead. It writes the `{id, value, label, active}` record shape the
        server actually reads, takes the key from a file so it never reaches the
        store, and will not fight the key you set in the UI.

        Declared here: ${lib.concatStringsSep ", " (
          lib.filter (rel: builtins.baseNameOf rel == "secrets.json")
            (map (e: e.path) (lib.filter (e: builtins.baseNameOf e.path == "secrets.json") fileEntries))
        )}
      '';
    }
    {
      # A secret whose value is not a readable file fails at activation with a
      # Python traceback. Caught here instead, where the message can name the
      # handle and key.
      assertion = lib.all (e: builtins.pathExists e.entry.value) secretEntries;
      message = ''
        services.sillytavern-nixos: every `secrets.byUser` value must be a path
        that exists at evaluation time.

        Missing: ${lib.concatStringsSep ", " (
          lib.map (e: "${e.handle}.${e.key} = ${e.entry.value}")
            (lib.filter (e: !builtins.pathExists e.entry.value) secretEntries)
        )}

        `value` is the file the key is read FROM, so it has to be a real path.
        For agenix this is `config.age.secrets.<name>.path`, which exists only
        once the age identity file is readable — check `age.secrets.age.identity
        .path` exists, or decrypt once with `agenix -d`.
      '';
    }

    {
      # `dataRootFiles` and the per-user `files` maps must never name the same
      # path. That overlap is what the original bug was: `files.common` was
      # listed in BOTH, so every file was seeded twice and stray top-level
      # directories appeared in the data root that SillyTavern never reads.
      #
      # `dataRootFiles` is now fed from `customCss` alone with a literal key, so
      # this should be structurally impossible — which is exactly why it is
      # worth asserting rather than trusting. A future edit that feeds
      # `files.common` here again fails at EVAL time, not at activation.
      assertion =
        let
          rootPaths = lib.attrNames seedSpecJson.dataRootFiles;
          # Per-user files are relative to the ACCOUNT directory, so a collision
          # is only real when the data-root path ends with a per-account path.
          perUser = lib.concatLists (
            lib.attrValues (lib.mapAttrs (_h: lib.attrNames) seedSpecJson.users)
          );
        in
        builtins.all (p: !(lib.elem p perUser)) rootPaths;
      message = ''
        services.sillytavern-nixos: a path is declared both as a data-root file
        and as a per-account file.

        Data-root: ${lib.concatStringsSep ", " (lib.attrNames seedSpecJson.dataRootFiles)}

        `dataRootFiles` and per-account `files` must not overlap. A path seeded
        into both is written twice per activation, and the data-root copy lands
        in a directory SillyTavern never reads. This map is fed from
        `customCss` alone precisely so that no configuration can reintroduce it.
      '';
    }
    {
      # Behind a reverse proxy the `Host` header is the PUBLIC name, so turning
      # the whitelist on without listing it rejects every request — the server
      # answers 403 to everything, which reads as "the proxy is broken" rather
      # than "the host list is empty".
      #
      # `hostWhitelist.js:26` reads `req.headers.host` unconditionally.
      assertion = !(cfg.config.hostWhitelist.enabled && cfg.config.hostWhitelist.hosts == [ ]);
      message = ''
        services.sillytavern-nixos: config.hostWhitelist.enabled is true but
        config.hostWhitelist.hosts is empty.

        `src/middleware/hostWhitelist.js` matches `req.headers.host` against
        this list, so an empty list rejects EVERY request — including the proxy's
        own health check. Behind a reverse proxy the header carries the public
        name, so that name is what has to be listed:

          services.sillytavern-nixos = {
            config.hostWhitelist.enabled = true;
            config.hostWhitelist.hosts = [ "st.example.com" ];
            proxyUpstreams = [ { inherit (config) hosts; /* … */ } ];
          };

        A leading dot makes a subdomain pattern, matching upstream's own syntax.
        Leave the whitelist off entirely for a loopback-only instance.
      '';
    }
    {
      # `enableForwardedWhitelist` defaults TRUE and
      # `src/express-common.js` prefers `x-real-ip`, then `cf-connecting-ip`,
      # then the FIRST `x-forwarded-for` entry. An APPENDING proxy therefore lets
      # a client supply its own `X-Forwarded-For` and choose which address the
      # whitelist and the rate limiter see.
      #
      # Only refused for `append`, which this option can now express. A proxy
      # that replaces the header (nginx `$remote_addr`) or is loopback-only is
      # fine as-is.
      assertion =
        cfg.proxyUpstreams == [ ]
        || !(cfg.config.enableForwardedWhitelist
          && lib.any (u: u.forwardedFor == "append") cfg.proxyUpstreams);
      message = ''
        services.sillytavern-nixos: a proxyUpstream sets forwardedFor =
        "append" while config.enableForwardedWhitelist is true.

        `config.enableForwardedWhitelist` defaults to true, and
        `src/express-common.js` reads the client-controlled `X-Forwarded-For`
        when it is set. An APPENDING proxy passes a client's own header through
        with their chosen address still first, so `whitelist` and
        `rateLimiting.preferRealIpHeader` then trust a spoofed IP.

        Forward the immediate peer's address instead — `replace`, the default —
        which is nginx `$remote_addr` (not `$proxy_add_x_forwarded_for`) and
        Caddy's default behaviour:

          proxyUpstreams = [ { inherit (config) forwardedFor; /* = "replace" */ } ];

        …or record that you meant to trust the chain by turning the server-side
        switch off:

          config.enableForwardedWhitelist = false;
      '';
    }
    {
      # `_css/user.css` is served to every visitor by `userCssMiddleware`, so it
      # must not be owner-only like `settings.json` (0600) — that is fine for a
      # secret-bearing file read by the service account, but this one is read
      # through `res.sendFile` as another user.
      assertion = lib.all (p: (seedSpecJson.dataRootFiles.${p}.mode or null) == "0644")
        (lib.attrNames seedSpecJson.dataRootFiles);
      message = ''
        services.sillytavern-nixos: data-root files must be mode 0644, not the
        owner-only default.

        `st_seed_files.py` defaults every seeded file to 0600 because most of
        them may hold a key. `_css/user.css` is served unauthenticated to every
        visitor, so it has to be world-readable.
      '';
    }

    # ── nixpkgs' own services.sillytavern ─────────────────────────────────────
    #
    # nixos-unstable ships a `services.sillytavern` module of its own
    # (nixos/modules/services/web-apps/sillytavern.nix, registered in
    # module-list.nix), and it is ALWAYS in scope — every NixOS system imports
    # the whole module list, so the option exists whether or not anyone wants it.
    # Ours is `services.sillytavern-nixos`.
    #
    # The two collide on three surfaces that are NOT option namespaced:
    #
    #   systemd.services.sillytavern      (the unit)
    #   users.users.sillytavern           (the account)
    #   systemd.services.sillytavern.serviceConfig.StateDirectory
    #
    # Verified against nixpkgs fe132422: that module's entire `config` block is a
    # single `lib.mkIf cfg.enable` — `systemd.services.sillytavern`,
    # `users.users`, `users.groups` and `systemd.tmpfiles.settings.sillytavern`
    # are all inside it, with nothing unconditional. So checking `enable` alone
    # is sufficient, and `enable = false` really does contribute nothing.
    #
    # Without this assertion the failure is a misleading conflict on
    # `serviceConfig.Restart` ("always" vs "on-failure"), and a user who forces
    # past it gets a merged unit whose ExecStart is nixpkgs' binary invoked WITH
    # our wrapper and flags as arguments.
    {
      # Guarded on OUR `enable` as well as theirs. `sillytavern.nix` imports
      # this file UNCONDITIONALLY (it is not inside services.nix's `mkIf`), so
      # every assertion here is evaluated even when the module is switched off.
      # Without the `!cfg.enable` arm, a user running nixpkgs' module and
      # deliberately not installing ours would be blocked by a module they never
      # enabled — which is the opposite of what this is for.
      assertion = !cfg.enable || !upstreamEnabled;
      message = ''
        services.sillytavern-nixos: nixos-unstable ALSO defines
        `services.sillytavern`, and both are enabled.

        This module is `services.sillytavern-nixos`. The namespace `services.sillytavern`
        belongs to a different, unrelated module that ships with nixpkgs.

        Enabling both makes them fight over three things that are NOT namespaced
        by option path, so they cannot coexist:

          * the systemd unit        `systemd.services.sillytavern`
          * the system account      `users.users.sillytavern`
          * `serviceConfig.StateDirectory`

        What you would see otherwise is a confusing conflict on
        `serviceConfig.Restart` ("always" vs "on-failure"), and forcing past it
        yields a merged unit that runs nixpkgs' binary with this module's wrapper
        as arguments.

        Fix: keep this one and disable the other —

            services.sillytavern-nixos = { enable = true; ... };
            services.sillytavern.enable = false;   # nixpkgs'

        or drop this module and use nixpkgs' (which has no account seeding, no
        JSON state, no secrets, and passes its flags as one quoted string).

        Do NOT rename around it. The unit name and the state directory are
        shared on purpose for now; a rename to `sillytavern-nixos` is planned
        as a breaking change, not something to bolt on here.
      '';
    }

    # ── global mode ───────────────────────────────────────────────────────────
    #
    # `--global` makes command-line.js resolve both the config path and the data
    # root through `env-paths`, and it then WARNS AND IGNORES any `--configPath`
    # or `--dataRoot` passed alongside. So the StateDirectory would silently not
    # be used, and the data root would land in the service account's
    # `~/.local/share` — outside the unit's writable set, unbacked, and
    # invisible to `nixos-rebuild`.
    {
      assertion = !cfg.cli.global;
      message = ''
        services.sillytavern-nixos: cli.global must be false.

        Global mode resolves the config path and data root through XDG
        directories (env-paths) and IGNORES --configPath and --dataRoot, so
        services.sillytavern-nixos.stateDirectory would have no effect and the data
        root would move to the service account's ~/.local/share — outside the
        systemd StateDirectory and outside anything NixOS backs up.

        The packaged `sillytavern` launcher also refuses --global.
      '';
    }

    # ── CLI / config contradictions ───────────────────────────────────────────
    #
    # Every `cli.*` option defaults to upstream's value, and services.nix only
    # emits a flag when it DIFFERS from `config`. So a user who sets both to
    # different values gets the flag silently winning. That is the server's own
    # precedence (`cliArgument ?? getConfigValue(...)`) and it is legitimate —
    # but it is invisible in the rendered config.yaml, which is a genuine trap.
    #
    # Every `cli.*` flag defaults to `null`, meaning "do not pass it", which
    # leaves the `config` value in charge. A flag is emitted only when it is
    # explicitly set, so there is no silent default-versus-config mismatch — but
    # when BOTH are set to different values the flag wins at runtime while the
    # rendered config.yaml still says something else, which is invisible unless
    # you read both. Worth one assertion.
    {
      assertion = cfg.cli.port == null || cfg.cli.port == cfg.config.port;
      message = ''
        services.sillytavern-nixos: cli.port (${toString cfg.cli.port}) differs from
        config.port (${toString cfg.config.port}).

        The command line WINS — command-line.js resolves each field as
        `cliArgument ?? getConfigValue(...)` — but the rendered config.yaml still
        says ${toString cfg.config.port}, so reading the config file will not tell
        you what the server is actually doing.

        Set both to the same value, or set only one of them: every cli flag
        defaults to null, which means "not passed", leaving `config` in charge.
      '';
    }

    # ── browserLaunch ─────────────────────────────────────────────────────────
    #
    # Verified by running the package: with `browserLaunch.enabled = true` and no
    # `xdg-open` on PATH — which is exactly the situation under systemd, where
    # there is no DISPLAY and no D-Bus session — the spawn throws ENOENT inside
    # an UNCAUGHT exception handler in postSetupTasks, and the process EXITS.
    # The unit then restarts, fails again, and lands in a restart loop that
    # looks like a crash rather than a misconfiguration.
    #
    # The module already forces this false by default; this assertion exists so
    # that turning it back on produces a clear message instead of a restart loop.
    {
      assertion = !effectiveConfig.browserLaunch.enabled || cfg.config.browserLaunch.enabled == false;
      message = ''
        services.sillytavern-nixos: config.browserLaunch.enabled = true.

        Under systemd there is no DISPLAY and no D-Bus session, so the launch
        fails. If the browser is not "default", the failure is an uncaught
        `spawn xdg-open ENOENT` which EXITS THE SERVER, and the unit restart
        loop reads as a crash rather than a misconfiguration.

        Set config.browserLaunch.enabled = false. Open the UI from your own
        machine instead — the reverse-proxy upstreams helper and
        openFirewall are for exactly that.
      '';
    }

    # ── plugin / extension auto-update ────────────────────────────────────────
    #
    # This module installs plugins and extensions as READ-ONLY STORE PATHS. A
    # `git pull` into one of those fails with EROFS. The failure surfaces late
    # — after the server has already decided an update is due — so it appears as
    # a startup error rather than as an inert button.
    #
    # BOTH assertions below read `effectiveConfig`, NOT `cfg.config`.
    #
    # modules/config.nix already forces these to false whenever the
    # corresponding store paths exist, so the OPTION still holds its upstream
    # default of `true` in exactly the case the assertion is about. Reading the
    # option made the assertion fire on the very configuration it says the
    # module handles — its own message ended "The module turns this off for you
    # when extensions are non-empty" while demanding the user set it themselves.
    # Declaring one extension therefore failed the build with no way out short
    # of also setting an option the module had already overridden.
    {
      assertion = cfg.plugins == { } || !effectiveConfig.enableServerPluginsAutoUpdate;
      message = ''
        services.sillytavern-nixos: plugins are declared but
        config.enableServerPluginsAutoUpdate = true.

        Declared plugins are installed as read-only Nix store paths, and
        auto-update runs `git pull` in that directory, which fails with EROFS.
        Set config.enableServerPluginsAutoUpdate = false, or override the
        package with a writable plugin directory.

        The module turns this off for you when plugins are non-empty; this
        assertion only fires if you set it back to true.
      '';
    }

    {
      # `effectiveConfig`, for the reason in the header note above.
      assertion = cfg.extensions == { } || !effectiveConfig.extensions.autoUpdate;
      message = ''
        services.sillytavern-nixos: extensions are declared but
        config.extensions.autoUpdate = true.

        Declared extensions live in read-only store paths, so the UI's
        automatic update fails with EROFS. Update them by changing the `rev` in
        services.sillytavern-nixos.extensions and rebuilding.

        The module turns this off for you when extensions are non-empty; this
        assertion only fires if you set it back to true.
      '';
    }

    # ── plugins require server plugins enabled ────────────────────────────────
    {
      assertion = cfg.plugins == { } || cfg.config.enableServerPlugins;
      message = ''
        services.sillytavern-nixos: plugins were declared but
        config.enableServerPlugins is false, so they would be installed and
        never loaded.

        Note that server plugins execute arbitrary code in the server process
        with the service's full privileges — there is no sandbox and no
        permission model. Enabling it is a deliberate decision.
      '';
    }

    # ── users require accounts enabled ───────────────────────────────────────
    {
      assertion = cfg.users == { } || cfg.config.enableUserAccounts;
      message = ''
        services.sillytavern-nixos: users were declared but
        config.enableUserAccounts is false.

        With accounts disabled the server ignores the user database entirely
        and everything runs as the single built-in `default-user`, so the
        declared accounts would be seeded and never used.
      '';
    }

    # ── the default-user problem ──────────────────────────────────────────────
    #
    # `initUserStorage` creates `default-user` on first start with
    # `admin: true` and an EMPTY password. The login check is
    # `user.password && user.password === getPasswordHash(...)`, so an empty
    # stored hash cannot be logged into — but the account is still an ADMIN, and
    # it is still the account every unauthenticated request resolves to while
    # accounts are disabled.
    {
      assertion = cfg.config.enableUserAccounts || cfg.users != { };
      message = ''
        services.sillytavern-nixos: no authentication is configured.

        With config.enableUserAccounts and config.basicAuthMode both false, the
        server creates a `default-user` account automatically — with
        `admin: true` and an empty password — and every request runs as it. An
        empty password cannot be logged into, but the account is still an
        administrator, and if config.listen is true the whole LLM proxy (with
        whatever API keys users have configured) is reachable unauthenticated.

        Either:
          - set config.listen = false and reach it through a reverse proxy or an
            SSH tunnel (the default), or
          - set config.enableUserAccounts = true and declare
            services.sillytavern-nixos.users, or
          - set config.basicAuthMode = true, understanding that a browser basic
            auth dialog is a poor login page.
      '';
    }

    {
      assertion = !(cfg.config.listen && !cfg.config.enableUserAccounts && !cfg.config.basicAuthMode && cfg.config.hostWhitelist.enabled == false && cfg.config.privateAddressWhitelist.enabled == false);
      message = ''
        services.sillytavern-nixos: config.listen = true with no authentication and
        no host or private-address whitelist.

        This exposes an unauthenticated HTTP service — a proxy to every LLM
        provider configured by any user, plus the character and chat data — on
        every interface, to anyone who can route to this host.

        If that is genuinely intended (a trusted LAN, an isolated network
        namespace), set config.hostWhitelist.enabled = true or
        config.privateAddressWhitelist.enabled = true to record that decision, or
        put a reverse proxy in front of it and keep config.listen = false.
      '';
    }

    # ── secrets must not be set in plaintext ──────────────────────────────────
    #
    # These three land in a `pkgs.writeText` store path: world-readable,
    # greppable by anyone who can read /nix/store, and kept forever by the
    # garbage collector. Upstream's own defaults make the hazard concrete —
    # `requestProxy.url` literally defaults to
    # `socks5://username:password@example.com:1080`.
    {
      assertion = cfg.config.ssl.keyPassphrase == "";
      message = ''
        services.sillytavern-nixos: config.ssl.keyPassphrase is set.

        It is rendered into a Nix store file, which is world-readable and
        permanent. Use services.sillytavern-nixos.ssl.keyPassphraseFile instead — it
        is delivered as SILLYTAVERN_SSL_KEYPASSPHRASE, which is what upstream's
        own comment on that key recommends, and never reaches the store.
      '';
    }

    {
      assertion = cfg.config.basicAuthUser.password == "password" || cfg.basicAuthUser.passwordFile == null;
      message = ''
        services.sillytavern-nixos: config.basicAuthUser.password is set to something
        other than the upstream default while
        services.sillytavern-nixos.basicAuthUser.passwordFile is unset.

        A password here is rendered into a world-readable store file. Use
        services.sillytavern-nixos.basicAuthUser.passwordFile instead.
      '';
    }

    {
      assertion = cfg.config.requestProxy.url == "socks5://username:password@example.com:1080" || cfg.requestProxy.urlFile == null;
      message = ''
        services.sillytavern-nixos: config.requestProxy.url is set while
        services.sillytavern-nixos.requestProxy.urlFile is unset.

        A proxy URL normally embeds a credential, and this one is rendered into
        a world-readable store file. Use
        services.sillytavern-nixos.requestProxy.urlFile instead.
      '';
    }

    # ── a File option and its plaintext twin both set ─────────────────────────
    #
    # `getConfigValue` checks the ENVIRONMENT before the config file, so the
    # `…File` version would win — and the plaintext in the store would be a
    # silent, permanent leak of a credential that is not even in use.
    {
      assertion = !(cfg.ssl.keyPassphraseFile != null && cfg.config.ssl.keyPassphrase != "");
      message = ''
        services.sillytavern-nixos: both ssl.keyPassphraseFile and
        config.ssl.keyPassphrase are set.

        The File option wins at runtime (the environment is checked before the
        config file), so the plaintext in the store is a live leak of a
        credential that is not even being used. Clear config.ssl.keyPassphrase.
      '';
    }

    {
      assertion = !(cfg.basicAuthUser.passwordFile != null && cfg.config.basicAuthUser.password != "password");
      message = ''
        services.sillytavern-nixos: both basicAuthUser.passwordFile and
        config.basicAuthUser.password are set.

        The File option wins at runtime, so the store copy is a live leak.
        Clear config.basicAuthUser.password.
      '';
    }

    {
      assertion = !(cfg.requestProxy.urlFile != null && cfg.config.requestProxy.url != "socks5://username:password@example.com:1080");
      message = ''
        services.sillytavern-nixos: both requestProxy.urlFile and
        config.requestProxy.url are set.

        The File option wins at runtime, so the store copy is a live leak.
        Clear config.requestProxy.url.
      '';
    }

    # ── SSL ───────────────────────────────────────────────────────────────────
    {
      assertion = !effectiveConfig.ssl.enabled || (cfg.ssl.certFile != null || effectiveConfig.ssl.certPath != "./certs/cert.pem");
      message = ''
        services.sillytavern-nixos: config.ssl.enabled is true but no certificate was
        provided.

        Either set services.sillytavern-nixos.ssl.certFile, or point
        config.ssl.certPath at an absolute path you manage yourself. A RELATIVE
        path resolves against the server directory, which is the read-only Nix
        store — so the server cannot open it and exits during startup
        (`checkSslOptions` in src/server-startup.js).

        A reverse proxy terminating TLS is usually the better answer; see
        docs/installing.md.
      '';
    }

    {
      assertion = !effectiveConfig.ssl.enabled || (cfg.ssl.keyFile != null || effectiveConfig.ssl.keyPath != "./certs/privkey.pem");
      message = ''
        services.sillytavern-nixos: config.ssl.enabled is true but no private key was
        provided.

        Set services.sillytavern-nixos.ssl.keyFile, or point config.ssl.keyPath at an
        absolute path. See the note on certPath in docs/installing.md.
      '';
    }

    {
      assertion = cfg.ssl.certFile == null || effectiveConfig.ssl.enabled || cfg.config.ssl.enabled;
      message = ''
        services.sillytavern-nixos: ssl.certFile was given but config.ssl.enabled is
        false, so the certificate is copied into the package and never used.
        Set config.ssl.enabled = true.
      '';
    }

    # ── passwordless accounts ─────────────────────────────────────────────────
    #
    # Verified against a running server: `src/endpoints/users-public.js` guards
    # the comparison with `user.password &&`, so an account stored with an empty
    # password is logged into by ANY password. Declaring a user without a
    # `passwordFile` therefore creates an open account, which is the opposite of
    # what it looks like.
    {
      assertion = cfg.allowPasswordlessUsers
        || cfg.users == { }
        || lib.all (handle: cfg.users.${handle}.passwordFile != null) (builtins.attrNames cfg.users);
      message = ''
        services.sillytavern-nixos: a declared user has no passwordFile.

        An account seeded with an empty password is PASSWORDLESS in SillyTavern,
        not disabled. The login check reads

          if (user.password && user.password !== getPasswordHash(…))

        so when the stored password is empty the comparison is skipped and login
        succeeds with any password at all. (Verified: an account seeded without a
        password accepted the literal password "literally-anything".)

        Do one of:
          - give every account a passwordFile;
          - protect them with config.sso.autheliaAuth or
            config.sso.authentikAuth, in which case set
            allowPasswordlessUsers = true to record that;
          - set allowPasswordlessUsers = true and accept that anyone who can
            reach the login endpoint becomes that user.
      '';
    }

    {
      assertion = cfg.allowPasswordlessUsers
        || cfg.users == { }
        || !lib.any (handle: cfg.users.${handle}.passwordFile == null) (builtins.attrNames cfg.users)
        || cfg.config.sso.autheliaAuth
        || cfg.config.sso.authentikAuth
        || cfg.config.enableDiscreetLogin;
      message = ''
        services.sillytavern-nixos: a passwordless account with neither SSO nor
        discreet login enabled.

        config.sso.autheliaAuth, config.sso.authentikAuth and
        config.enableDiscreetLogin are the only things that make an empty
        password safe. Without at least one of them, a passwordless account is
        reachable by anyone who can POST to /api/users/login.
      '';
    }

    # ── the --dataRoot / StateDirectory relationship ─────────────────────────
    {
      assertion = cfg.cli.dataRoot == "" || cfg.cli.dataRoot == cfg.dataRoot;
      message = ''
        services.sillytavern-nixos: cli.dataRoot (${cfg.cli.dataRoot}) differs from
        the StateDirectory path (${cfg.dataRoot}).

        The unit's writable set is the StateDirectory. A --dataRoot pointing
        anywhere else is outside `ProtectSystem=strict`'s exceptions, so the
        first chat write fails with EROFS — and that loses data rather than
        merely logging. Change services.sillytavern-nixos.stateDirectory instead.
      '';
    }

    # ── forwarded headers ─────────────────────────────────────────────────────
    #
    # `forwardedHeaders.*` and `enableForwardedWhitelist` / `rateLimiting.preferRealIpHeader`
    # all trust a client-supplied header to mean "this is the client's real IP".
    # With no proxy in front, that header is attacker-controlled, so the
    # whitelist can be bypassed by putting an allowed address in it.
    {
      assertion = !cfg.config.listen
        || cfg.config.hostWhitelist.enabled
        || !(cfg.config.enableForwardedWhitelist || cfg.config.rateLimiting.preferRealIpHeader)
        || cfg.config.hostWhitelist.enabled
        || builtins.elem "127.0.0.1" cfg.config.sso.trustedProxies;
      message = ''
        services.sillytavern-nixos: config.listen is true and the forwarded-IP headers
        are trusted (config.enableForwardedWhitelist or
        config.rateLimiting.preferRealIpHeader), but nothing establishes that a
        proxy is actually in front.

        With no proxy, X-Forwarded-For and X-Real-IP are attacker-controlled:
        a client can put an allowed address in the header and match any entry in
        config.whitelist, and defeat rate limiting entirely.

        This is correct and expected BEHIND a reverse proxy you control. To say
        so explicitly, set config.hostWhitelist.enabled = true, or turn the
        forwarded-header trust off.
      '';
    }

    # ── listen address sanity ────────────────────────────────────────────────
    {
      assertion = !effectiveConfig.listen || effectiveConfig.listenAddress.ipv6 == "[::]" || !(lib.hasPrefix "[" effectiveConfig.listenAddress.ipv6 && lib.hasSuffix "]" effectiveConfig.listenAddress.ipv6);
      message = ''
        services.sillytavern-nixos: config.listenAddress.ipv6 has brackets around a
        NON-wildcard address ("${effectiveConfig.listenAddress.ipv6}").

        The brackets are part of the value because command-line.js builds a URL
        from it, so a concrete address needs them too — but a wildcard plus
        brackets is ambiguous and the server falls back to 127.0.0.1/[::1]. Use
        "" for "all IPv6 interfaces".
      '';
    }

    # ── protocol sanity ──────────────────────────────────────────────────────
    {
      assertion = effectiveConfig.protocol.ipv4 != "false" || effectiveConfig.protocol.ipv6 != "false";
      message = ''
        services.sillytavern-nixos: both config.protocol.ipv4 and config.protocol.ipv6
        are "false".

        Upstream's own comment: "Need to have at least one enabled!" With both
        disabled the server has no address to listen on and exits at startup.
      '';
    }

    # ── cacheBuster needs a secure origin ────────────────────────────────────
    {
      assertion = !effectiveConfig.cacheBuster.enabled || !effectiveConfig.listen || cfg.config.ssl.enabled;
      message = ''
        services.sillytavern-nixos: config.cacheBuster.enabled is true on a
        non-loopback bind without TLS.

        Upstream's own comment: this REQUIRES localhost or a domain with HTTPS,
        "otherwise will not work". Over plain HTTP the browser cannot be forced
        to refetch, so this is a silent no-op at best. Enable config.ssl, or
        leave cacheBuster disabled and let the reverse proxy handle it.
      '';
    }

    # ── reserved handle ───────────────────────────────────────────────────────
    {
      assertion = !(cfg.users ? default-user);
      message = ''
        services.sillytavern-nixos: a user is declared with the handle "default-user".

        `initUserStorage` creates `default-user` itself, on first start, with
        `admin: true` and an EMPTY password. Declaring it here would be
        silently ignored by the idempotent seeder (which never touches an
        existing handle), leaving you with an administrator whose password
        nobody chose — and a configuration that reads as if it does.

        Pick a different handle, and if you need an administrator, declare one
        with admin = true.
      '';
    }

    # ── git rev must be pinned ────────────────────────────────────────────────
    {
      # `lib.all`, NOT `builtins.all`, and a ONE-argument predicate.
      #
      # Two mistakes used to be stacked here and neither was visible while this
      # module had no plugins:
      #
      #   * `builtins.all` is a strict two-argument builtin, so it calls
      #     `pred elem` with ONE argument. The curried `(handle: spec: …)`
      #     returned a *function* where a boolean was expected. Declaring any
      #     plugin or extension therefore made the whole SYSTEM fail to
      #     evaluate — `lib.asserts.checkAssertWarn` (what
      #     nixos/modules/system/activation/top-level.nix runs) forces every
      #     `assertion`, and it threw:
      #
      #       error: expected a Boolean but found a function: … assertions.nix:728
      #
      #   * With an EMPTY list `builtins.all` returns true without ever calling
      #     the predicate, so every check in lib/tests.nix passed. The bug was
      #     only reachable by doing the one thing the module exists for.
      #
      # `lib.all` auto-applies to `pred elem`, so a single-argument predicate is
      # the correct shape; the records in the list are `{ rev = …; }`, which is
      # all the predicate ever needed, hence no `handle`.
      assertion = lib.all (spec: lib.hasInfix "/" spec.rev || builtins.match "^[0-9a-f]{40}$" spec.rev != null) (
        lib.attrValues (lib.mapAttrs (_: s: { rev = s.rev; }) (cfg.plugins // cfg.extensions))
      );
      message = ''
        services.sillytavern-nixos: a plugin or extension `rev` is not a full commit
        SHA.

        Plugins and extensions are installed as `fetchgit` STORE PATHS. A branch
        name is not content-addressable, so the store path would either fail to
        realise reproducibly or silently move under a running service. Pin a
        tag ("refs/tags/v1.2.3") or a 40-character commit SHA.
      '';
    }

    # ── requestProxy needs a URL ─────────────────────────────────────────────
    {
      assertion = !effectiveConfig.requestProxy.enabled || effectiveConfig.requestProxy.url != "" || cfg.requestProxy.urlFile != null;
      message = ''
        services.sillytavern-nixos: config.requestProxy.enabled is true but the proxy
        URL is empty.

        With no URL, initRequestProxy is called with an empty url and every
        outgoing request fails at the proxy layer rather than at startup.
        Either set config.requestProxy.url or
        services.sillytavern-nixos.requestProxy.urlFile.
      '';
    }

    # ── control-character check on config strings ─────────────────────────────
    #
    # The YAML and EnvironmentFile writers escape `\` and `"` but not control
    # characters. A literal newline inside an EnvironmentFile value is not
    # representable, and systemd's parser will silently truncate the entry at
    # the newline — producing a password that is subtly wrong and very hard to
    # diagnose. Rejected here rather than escaped, because there is no correct
    # answer available to us.
    {
      # Over `attrNames`, not the attrset: `lib.all` takes a LIST. Passing the
      # attrset fails with "expected a list but found a set" — and fails
      # SILENTLY-safely only because it is empty when no secrets are declared.
      assertion = lib.all (name: !(lib.hasInfix "\n" secretEnvValues.${name}))
        (builtins.attrNames secretEnvValues);
      message = ''
        services.sillytavern-nixos: a secret file's contents contain a newline.

        systemd's EnvironmentFile= parser ends a value at a newline even inside
        quotes, so the variable would be silently truncated to its first line —
        a password that is subtly wrong with no error anywhere.

        Strip the trailing newline from the secret file. The service assembles
        the environment file from `$(cat <path>)`, which already strips trailing
        newlines; only an INTERIOR newline is a problem.
      '';
    }

    {
      # A ONE-argument predicate: `lib.all` calls `pred elem`, so a curried
      # `name: value: …` would return a function where a boolean is expected.
      assertion = lib.all (value: !(lib.hasInfix "\n" value)) (lib.attrValues cfg.environment);
      message = ''
        services.sillytavern-nixos: a value in services.sillytavern-nixos.environment
        contains a newline.

        systemd cannot represent a newline in a single Environment= value. Use a
        list of strings, or put the variable in a file and reference it.
      '';
    }
  ];
}
