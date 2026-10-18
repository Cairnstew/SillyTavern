# lib/default.nix
#
# Shared, NixOS-module-free helpers for packaging and running SillyTavern.
#
# Everything in here is pure: it takes values and returns strings or attrsets,
# and it never reads `config` or instantiates `pkgs`. That makes it directly
# unit-testable (`nix run .#checks.lib`) and reusable from a consumer's own
# module, which `self.lib` exposes.
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
  # note on `assertNoControlCharacters` in modules/assertions.nix, which is
  # where that is actually enforced rather than papered over here.
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
  # why it lives in one place with a test next to it.
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
in
{
  inherit
    secretConfigPaths
    keyToEnv
    userKeyFor
    renderYaml
    renderYamlScalar
    renderYamlString
    renderEnvValue
    renderEnvLine
    renderEnvFile
    renderCliArgv
    renderCliArgvScalar
    stripSecretPaths
    getPath
    pathIsSet
    ;

  # ── mkUserArg ───────────────────────────────────────────────────────────────
  #
  # Resolves one `services.sillytavern.users.<handle>` spec into the flat shape
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
  # Returns `[{ name, port, path, stripPrefix, displayName; }]` describing how
  # to reach the instance, so a consumer can wire it into whatever reverse
  # proxy module they use without this project depending on that module — the
  # same trick `nixos-projectzomboid-servers` uses.
  #
  # SillyTavern is a single-port HTTP server with no path prefix, so `path` is
  # always "/" and `stripPrefix` is always false. Both are still emitted so the
  # shape is uniform with other services in a consumer's upstream list.
  #
  # `config` is the consumer's whole module config, so that one call reads the
  # port out of `services.sillytavern.config.port` for every named instance
  # without this function having to know the option path:
  #
  #   proxy.upstreams = lib.mkMerge (map mkUpstream
  #     (config.services.sillytavern.proxyUpstreams));
  #
  #   # …then, per instance:
  #   nix eval --json '.#nixosConfigurations.host.config.services.sillytavern.proxyUpstreams'
  #
  # `openFirewall` is deliberately NOT handled here: a reverse proxy reaching
  # SillyTavern over loopback needs no firewall hole at all, and SillyTavern
  # does not speak TLS on its own port without extra certificates. Exposing it
  # directly is the `services.sillytavern.openFirewall` option's job, and it
  # defaults to false.
  mkProxyUpstream =
    {
      config,
      configName ? "sillytavern",
      displayName ? "SillyTavern",
      path ? "/",
      stripPrefix ? false,
    }:
    {
      name = configName;
      port = config.services.sillytavern.config.port;
      inherit path stripPrefix displayName;
    };
}
