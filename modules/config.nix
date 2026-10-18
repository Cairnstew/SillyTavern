# modules/config.nix
#
# Turns the option tree into the three things the server actually consumes:
# a `config.yaml`, an environment file for secrets, and a command line.
#
# This file is imported by modules/services.nix and does no systemd work of its
# own, so it can be evaluated (and tested) without building a unit.
#
# ── The central design decision: config.yaml in the store, not the state dir ──
#
# The obvious approach is to render config.yaml into the StateDirectory at
# activation, the way a hand-managed deployment would write /etc/sillytavern.
# This module deliberately does NOT, and the reason is in the code:
#
#   src/config-init.js -> initConfig(configPath) -> addMissingConfigValues()
#
# That function reads config.yaml, deep-merges upstream's `default/config.yaml`
# into it, and **rewrites the file** whenever it added a key or performed a
# migration. On a fresh upstream release that adds a config key, the server
# would try to write to the config path on first start.
#
# Rendering to the store makes that write fail — and it fails QUIETLY, because
# the whole body of addMissingConfigValues is wrapped in a try/catch that only
# `console.warn`s. So this is safe, but it is safe for a reason worth writing
# down: the missing key does not matter, because every read goes through
# `getConfigValue(key, default)`, which falls back to an in-code default when
# neither the environment nor the file supplies one. Upstream's own code comment
# agrees: "Configs are read-only. Use environment variables instead."
#
# Putting the file in the store therefore costs nothing and buys immutability:
# the config is a pure function of the Nix configuration, cannot drift, and
# cannot be edited by whatever is running the server.
#
# ── Why secrets do not go in it ───────────────────────────────────────────────
#
# Everything rendered here is a store path: world-readable, greppable by anyone
# who can read /nix/store, and kept forever by the garbage collector. Three
# config values are credentials — `ssl.keyPassphrase`, `basicAuthUser.password`
# and `requestProxy.url` (whose upstream default literally reads
# `socks5://username:password@example.com:1080`). Those are stripped from the
# rendered YAML and delivered as `SILLYTAVERN_*` environment variables read from
# files at service start.
#
# The environment is the right channel for two independent reasons:
#
#   1. It is not the store. The values are read from a path the caller controls
#      (an agenix decryption, a systemd credential) and never from Nix.
#   2. It is what upstream recommends for exactly these keys — config.yaml's own
#      comment on `ssl.keyPassphrase` names
#      `SILLYTAVERN_SSL_KEYPASSPHRASE`, and `getConfigValue` checks the
#      environment BEFORE the file for every single key.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    types
    concatStringsSep
    last
    mapAttrsToList
    optionalAttrs
    removeAttrs
    removeSuffix
    splitString
    ;

  st = import ../lib { inherit lib; };
  cfg = config.services.sillytavern-nixos;

  # ── Effective config ────────────────────────────────────────────────────────
  #
  # `config` merged with the free-form `extraConfig`. `extraConfig` is applied
  # LAST so it can override a modelled key as well as add an unmodelled one —
  # that is the whole point of an escape hatch.
  mergedConfig = lib.recursiveUpdate cfg.config cfg.extraConfig;

  # ── Module overrides on the config tree ─────────────────────────────────────
  #
  # A handful of upstream defaults are actively wrong under systemd, and a
  # handful are actively wrong under Nix. Overriding them here — rather than in
  # `options.nix` — keeps `default/config.yaml` transcription honest: the option
  # defaults stay equal to upstream's values, and the round-trip check in
  # lib/tests.nix keeps proving that. What differs is stated in one place, and
  # every override is `lib.mkIf`-able by the user.
  effectiveConfig =
    mergedConfig
    // {
      # ── browserLaunch.enabled: true → false ────────────────────────────────
      # Upstream defaults this true because the common case is someone running
      # the server by hand on a desktop. A systemd unit has no DISPLAY and no
      # D-Bus session, so the launch fails — and with `browser: "firefox"` it
      # logs a spawn error on every single start. Overridable.
      browserLaunch = mergedConfig.browserLaunch // {
        enabled = false;
      };

      # ── whitelistDockerHosts: true → false ────────────────────────────────
      # "Auto-whitelist the Docker host and gateway" describes a Docker bridge
      # that does not exist on NixOS. Left on, it adds container-network ranges
      # to an allowlist nobody chose, and its presence in a rendered config is
      # actively confusing when auditing `whitelist`. Overridable.
      whitelistDockerHosts = false;

      # ── autoUpdate: true → false, whenever anything is pinned ──────────────
      # Both of these drive a `git pull` into the plugin/extension directory.
      # This module installs those directories as READ-ONLY STORE PATHS, so an
      # update attempt fails. Worse, it would fail *after* the server decided it
      # needed to update, so the failure surfaces as a startup error rather than
      # as an inert UI button.
      #
      # Only forced when there is something pinned, so a bare
      # `services.sillytavern-nixos.enable` renders a config indistinguishable from a
      # hand-written one. modules/assertions.nix refuses the combination of an
      # explicit `true` here with a non-empty `plugins`/`extensions`.
      extensions =
        mergedConfig.extensions // {
          autoUpdate = if mergedConfig.extensions.autoUpdate && (cfg.plugins != { } || cfg.extensions != { }) then false else mergedConfig.extensions.autoUpdate;
        };

      enableServerPluginsAutoUpdate =
        if mergedConfig.enableServerPluginsAutoUpdate && cfg.plugins != { } then false else mergedConfig.enableServerPluginsAutoUpdate;

      # ── dataRoot: always the StateDirectory ────────────────────────────────
      # `dataRoot` in config.yaml is relative ("./data") and is resolved by the
      # server against ITS OWN DIRECTORY — which is the read-only store. The
      # flag below is what actually redirects it; this keeps the two in sync so
      # the file is not actively lying.
      dataRoot = cfg.dataRoot;
    };

  # ── The rendered config.yaml ────────────────────────────────────────────────
  #
  # Read-only store path, 0444. See the header for why that is deliberate.
  #
  # `stripSecretPaths` runs even though the assertions should already have
  # guaranteed the values are empty: defence in depth, so a bare import that
  # bypasses `assertions` still cannot write a credential to the store.
  renderedConfig = pkgs.writeText "sillytavern-config.yaml" (
    (st.renderYaml 0 (st.stripSecretPaths effectiveConfig)) + "\n"
  );

  # ── Secrets ─────────────────────────────────────────────────────────────────
  #
  # Each entry is the environment variable SillyTavern would read that key from
  # (`keyToEnv`), so nothing has to be threaded through argv.
  #
  # `fileContent` normalises the awkward cases:
  #   * a trailing newline is stripped — every text file has one, and a password
  #     that accidentally includes one is a support ticket;
  #   * CRLF is normalised, for the same reason.
  #
  # It does NOT strip leading/trailing spaces: those can be legitimate in a
  # passphrase, and silently eating them is worse than failing.
  fileContent =
    path:
    let
      raw = builtins.readFile path;
      noTrailingNewline = lib.removeSuffix "\n" (lib.removeSuffix "\r" raw);
    in
    lib.removeSuffix "\n" (lib.removeSuffix "\r" noTrailingNewline);

  # `optionalAttrs` needs an ATTRSET, not an expression — hence the
  # `${st.keyToEnv "…"}` dynamic attribute name rather than a function call
  # applied to the result.
  secretEnvEntries =
    optionalAttrs (cfg.ssl.keyPassphraseFile != null) {
      ${st.keyToEnv "ssl.keyPassphrase"} = fileContent cfg.ssl.keyPassphraseFile;
    }
    // optionalAttrs (cfg.basicAuthUser.passwordFile != null) {
      ${st.keyToEnv "basicAuthUser.password"} = fileContent cfg.basicAuthUser.passwordFile;
    }
    // optionalAttrs (cfg.requestProxy.urlFile != null) {
      ${st.keyToEnv "requestProxy.url"} = fileContent cfg.requestProxy.urlFile;
    }
    // cfg.extraConfigEnv;

  # The same mapping, but NAME -> PATH rather than NAME -> VALUE.
  #
  # This is what services.nix builds the environment file from, and the
  # distinction matters: `secretEnvEntries` holds secret VALUES as Nix attribute
  # values, so anything that can read the module config — `nixos-option`,
  # `nix eval .#nixosConfigurations.host.config`, a `--json` dump, a crash log —
  # can read the password. `secretEnvFiles` holds only paths, which are already
  # public, and the value is read from disk by the shell at service start.
  #
  # Nothing downstream of services.nix should use `secretEnvEntries`.
  secretEnvFiles =
    optionalAttrs (cfg.ssl.keyPassphraseFile != null) {
      ${st.keyToEnv "ssl.keyPassphrase"} = cfg.ssl.keyPassphraseFile;
    }
    // optionalAttrs (cfg.basicAuthUser.passwordFile != null) {
      ${st.keyToEnv "basicAuthUser.password"} = cfg.basicAuthUser.passwordFile;
    }
    // optionalAttrs (cfg.requestProxy.urlFile != null) {
      ${st.keyToEnv "requestProxy.url"} = cfg.requestProxy.urlFile;
    }
    // lib.mapAttrs (_: v: "/nix/store/ignored") cfg.extraConfigEnv;

  hasSecrets = secretEnvFiles != { };

  # Escaping for a systemd `EnvironmentFile=` value, done in shell at runtime.
  #
  # systemd's parser is not shell and not POSIX: it takes `KEY=VALUE` where
  # VALUE is shell-like words, and honours `\` and `"` escapes inside double
  # quotes. Double-quoting with both escaped is the only unambiguous encoding,
  # which is what a password containing a quote or a `$` needs.
  #
  # Declared here rather than in services.nix so the two files cannot disagree
  # about the format.
  envQuote =
    ''
      # Emit one systemd `EnvironmentFile=` line: KEY="escaped value".
      #
      # systemd's parser is neither shell nor POSIX. It takes KEY=VALUE where
      # VALUE is shell-like words, and inside double quotes it honours \ and "
      # escapes. Double-quoting with both escaped is the only unambiguous
      # encoding — a password containing a quote, a backslash or a `$` is not
      # exotic, and single quotes would not help because systemd does not
      # interpret escapes there at all.
      #
      # Command substitution already strips trailing newlines, which is why a
      # secret file may end in a newline. An INTERIOR newline is not
      # representable and is rejected by an assertion rather than mangled here.
      st_env_line() {
        printf '%s="%s"\n' "$1" "$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
      }
    '';

  # ── TLS material ────────────────────────────────────────────────────────────
  #
  # `ssl.certFile` / `ssl.keyFile` are copied into the package's `certs/`
  # directory at build time and referenced by ABSOLUTE path.
  #
  # The absolute path is the point. The server resolves a relative `certPath`
  # against its own directory — `server.js` does `process.chdir(serverDirectory)`
  # before anything else — and that directory is the read-only store. A relative
  # path can therefore only ever name the file baked into the package, and
  # `checkSslOptions` in src/server-startup.js exits at startup if it cannot
  # open the certificate.
  tlsFiles =
    let
      copy =
        name: src: dst:
        pkgs.runCommand "sillytavern-${name}" { } ''
          mkdir -p "$out/certs"
          cp ${src} "$out/certs/${dst}"
        '';
    in
    { }
    // optionalAttrs (cfg.ssl.certFile != null) {
      cert = copy "cert" cfg.ssl.certFile "cert.pem";
    }
    // optionalAttrs (cfg.ssl.keyFile != null) {
      key = copy "key" cfg.ssl.keyFile "privkey.pem";
    };

  certPackage = tlsFiles.cert or null;
  keyPackage = tlsFiles.key or null;

  # ── Plugins and extensions ──────────────────────────────────────────────────
  #
  # Installed as `fetchgit` store paths, so they are pinned, content-addressed
  # and read-only.
  #
  # `fetchgitExtra` is merged LAST so a per-plugin `fetchSubmodules` or
  # `leaveDotGit` can override the shared defaults — the option's doc comment
  # says it is passed straight through, so it has to actually win.
  repoName =
    url:
    let
      base = lib.last (splitString "/" url);
    in
    if base == "" then "sillytavern-plugin" else removeSuffix ".git" base;

  mkGitPackage =
    spec:
    pkgs.fetchgit (
      {
        url = spec.url;
        rev = spec.rev;
        fetchSubmodules = spec.submodules;
        name = repoName spec.url;
      }
      // spec.fetchgitExtra
    );

  # Plugins land in `$package/plugins/<name>` and extensions in
  # `$package/public/scripts/extensions/third-party/<name>` — the two directories
  # upstream scans (plugins.js and content-manager.js).
  #
  # An `overrideAttrs` postInstall rather than a postInstall in the package
  # itself, so a consumer running this module against their OWN package build
  # still gets their plugins installed, and the plugin store paths show up in
  # the derivation graph where `nix-store -q --references` finds them.
  packaged =
    cfg.package.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        ${concatStringsSep "\n" (
          mapAttrsToList (name: spec: ''
            echo "sillytavern: installing plugin ${name} -> plugins/${name}"
            mkdir -p "$out/plugins/${name}"
            cp -r --no-preserve=mode,ownership,timestamps ${mkGitPackage spec}/. "$out/plugins/${name}/"
          '') cfg.plugins
        )}
        ${concatStringsSep "\n" (
          mapAttrsToList (name: spec: ''
            echo "sillytavern: installing extension ${name} -> public/scripts/extensions/third-party/${name}"
            mkdir -p "$out/public/scripts/extensions/third-party/${name}"
            cp -r --no-preserve=mode,ownership,timestamps ${mkGitPackage spec}/. "$out/public/scripts/extensions/third-party/${name}/"
          '') cfg.extensions
        )}
      '';
    });

  # ── The command line ────────────────────────────────────────────────────────
  #
  # `--configPath` and `--dataRoot` are always emitted. Every other flag is
  # emitted ONLY when it differs from the corresponding `config` value, which
  # keeps the argv short and — more importantly — keeps the rendered config.yaml
  # authoritative. See the note on `renderCliArgv` in ../lib for why flags use
  # the explicit `--flag=value` form.
  # `global` is emitted only when TRUE, never as `--global=false`.
  #
  # The packaged launcher refuses `--global` outright, because in that mode
  # SillyTavern ignores --configPath and --dataRoot and resolves both through XDG
  # directories. Always emitting `--global=false` therefore made the launcher
  # reject the module's OWN argv and exit 2, so the unit never started.
  #
  # `false` is already the upstream default, so omitting it changes nothing
  # except the noise; `true` is still emitted, and still refused.
  cliFlags =
    {
      configPath = if cfg.cli.configPath != "" then cfg.cli.configPath else renderedConfig;
      dataRoot = if cfg.cli.dataRoot != "" then cfg.cli.dataRoot else cfg.dataRoot;
    }
    // optionalAttrs cfg.cli.global { global = true; }
    // optionalAttrs (cfg.cli.listen != null) { listen = cfg.cli.listen; }
    // optionalAttrs (cfg.cli.port != null) { port = cfg.cli.port; }
    // optionalAttrs (cfg.cli.listenAddressIPv4 != null) { listenAddressIPv4 = cfg.cli.listenAddressIPv4; }
    // optionalAttrs (cfg.cli.listenAddressIPv6 != null) { listenAddressIPv6 = cfg.cli.listenAddressIPv6; }
    // optionalAttrs (cfg.cli.enableIPv4 != null) { enableIPv4 = cfg.cli.enableIPv4; }
    // optionalAttrs (cfg.cli.enableIPv6 != null) { enableIPv6 = cfg.cli.enableIPv6; }
    // optionalAttrs (cfg.cli.dnsPreferIPv6 != null) { dnsPreferIPv6 = cfg.cli.dnsPreferIPv6; }
    // optionalAttrs (cfg.cli.browserLaunchEnabled != null) { browserLaunchEnabled = cfg.cli.browserLaunchEnabled; }
    // optionalAttrs (cfg.cli.browserLaunchHostname != null) { browserLaunchHostname = cfg.cli.browserLaunchHostname; }
    // optionalAttrs (cfg.cli.browserLaunchPort != null) { browserLaunchPort = cfg.cli.browserLaunchPort; }
    // optionalAttrs (cfg.cli.browserLaunchAvoidLocalhost != null) { browserLaunchAvoidLocalhost = cfg.cli.browserLaunchAvoidLocalhost; }
    // optionalAttrs (cfg.cli.corsProxy != null) { corsProxy = cfg.cli.corsProxy; }
    // optionalAttrs (cfg.cli.disableCsrf != null) { disableCsrf = cfg.cli.disableCsrf; }
    // optionalAttrs (cfg.cli.ssl != null) { ssl = cfg.cli.ssl; }
    // optionalAttrs (cfg.cli.certPath != "" && cfg.cli.certPath != null) { certPath = cfg.cli.certPath; }
    // optionalAttrs (cfg.cli.keyPath != "" && cfg.cli.keyPath != null) { keyPath = cfg.cli.keyPath; }
    // optionalAttrs (cfg.cli.keyPassphrase != "") { keyPassphrase = cfg.cli.keyPassphrase; }
    // optionalAttrs (cfg.cli.whitelist != null) { whitelist = cfg.cli.whitelist; }
    // optionalAttrs (cfg.cli.basicAuthMode != null) { basicAuthMode = cfg.cli.basicAuthMode; }
    // optionalAttrs (cfg.cli.enableKeepAlive != null) { enableKeepAlive = cfg.cli.enableKeepAlive; }
    // optionalAttrs (cfg.cli.requestProxyEnabled != null) { requestProxyEnabled = cfg.cli.requestProxyEnabled; }
    // optionalAttrs (cfg.cli.requestProxyUrl != null) { requestProxyUrl = cfg.cli.requestProxyUrl; }
    // optionalAttrs (cfg.cli.requestProxyBypass != null) { requestProxyBypass = cfg.cli.requestProxyBypass; }
    // optionalAttrs (cfg.cli.heartbeatInterval != null) { heartbeatInterval = cfg.cli.heartbeatInterval; }
    // optionalAttrs (cfg.cli.autorun != null) { autorun = cfg.cli.autorun; }
    // optionalAttrs (cfg.cli.autorunHostname != null) { autorunHostname = cfg.cli.autorunHostname; }
    // optionalAttrs (cfg.cli.autorunPortOverride != null) { autorunPortOverride = cfg.cli.autorunPortOverride; }
    // optionalAttrs (cfg.cli.avoidLocalhost != null) { avoidLocalhost = cfg.cli.avoidLocalhost; };

  renderedArgv = st.renderCliArgv cliFlags;

  # The argv the unit actually runs. A LIST, because systemd hands each
  # `ExecStart` element to the process as a single argv entry: joining the
  # flags into one escaped word (as `renderedArgv` does, for humans reading the
  # unit) makes yargs ignore every flag in it.
  cliArgvList = st.renderCliArgvList cliFlags;

  # ── healthcheck.js ──────────────────────────────────────────────────────────
  #
  # `src/healthcheck.js` parses `SILLYTAVERN_HEARTBEATINTERVAL` and falls back to
  # `parseInt(… || '0')`, then `process.exit(0)`s immediately when that is <= 0 —
  # i.e. with the variable unset the probe reports success without checking
  # anything at all. Both variables are exported whenever the interval is on.
  healthcheckEnv =
    optionalAttrs (effectiveConfig.heartbeatInterval > 0) {
      SILLYTAVERN_HEARTBEATINTERVAL = toString effectiveConfig.heartbeatInterval;
      SILLYTAVERN_DATAROOT = cfg.dataRoot;
    };

  # ── Resolved users ──────────────────────────────────────────────────────────
  #
  # The attribute name is the handle; `mkUserArg` fills in `name` from it.
  #
  # `lib.mapAttrs`, NOT `lib.mapAttrs'`. The primed variant hands your function's
  # result straight to `listToAttrs`, which requires each element to be a
  # `{ name, value; }` pair — `mkUserArg` returns a plain record, so it fails
  # with "in a {name=...; value=...;} pair / attribute 'value' missing".
  # `lib.mapAttrs` wraps the result for you.
  resolvedUsers = lib.mapAttrs st.mkUserArg cfg.users;

  # ── The JSON-state seed spec ──────────────────────────────────────────────
  #
  # Everything Nix-definable about SillyTavern's JSON state (settings.json,
  # presets, themes, world books) is rendered here into ONE store file, which
  # scripts/st_seed_files.py applies at activation. Rendering it at eval time
  # rather than passing the attrsets through to the shell is what keeps a
  # 26 KB settings tree out of a generated shell script.
  #
  # Handles come from the union of both `byUser` maps so that a handle present
  # in only one of them still gets seeded; assertions.nix then requires it to
  # be a declared account, so a typo cannot leave a stray directory in the
  # data root that SillyTavern would never adopt.
  # Handles to seed. This is the union of:
  #
  #   * every DECLARED account — so `settings.common` and `files.common`, which
  #     are documented as applying to EVERY account, actually reach them. They
  #     used to be seeded only for handles that happened to appear in a `byUser`
  #     map, which meant a config using nothing but `.common` produced an EMPTY
  #     spec and silently did nothing. Verified: `users.seanc` +
  #     `settings.common` with no `byUser` anywhere gave `users: {}`.
  #   * `default-user`, which the server creates for itself on first start when
  #     accounts are disabled. Without this, the single-account setup — the
  #     DEFAULT, since `config.enableUserAccounts` defaults to false — was
  #     unreachable entirely.
  #   * anything named in a `byUser` map; assertions.nix requires those to be a
  #     declared account or `default-user`, so they add nothing here but keep the
  #     two derivations honest about each other.
  seedHandles = lib.unique (
    lib.attrNames cfg.users
    ++ [ "default-user" ]
    ++ lib.attrNames cfg.settings.byUser
    ++ lib.attrNames cfg.files.byUser
    ++ lib.attrNames cfg.secrets.byUser
  );

  seedSpec = pkgs.writeText "sillytavern-seed-spec.json" (
    builtins.toJSON {
      # Deliberately empty.
      #
      # `files.common` is documented as relative to each ACCOUNT's directory, and
      # every configurable file SillyTavern owns lives under one: presets,
      # themes, world books, settings.json, and so on. The only data-root-level
      # things are `config.yaml` (which this module renders separately),
      # `stats.json`, `backups/`, and the `_`-prefixed runtime directories —
      # none of which are user configuration, and all of which the seeder
      # refuses to touch anyway.
      #
      # Listing `cfg.files.common` here as well was a real bug: it seeded every
      # file twice and created stray top-level directories in the data root that
      # SillyTavern never reads.
      dataRootFiles = { };
      users = lib.genAttrs seedHandles (
        handle: {
          # `//` so a per-account leaf overrides the shared one without the
          # account having to restate the rest of its tree.
          settings = cfg.settings.common // (cfg.settings.byUser.${handle} or {});
          files = cfg.files.common // (cfg.files.byUser.${handle} or {});
          # PATHS ONLY. A secret's bytes are read by the seeder at activation,
          # so nothing about the key itself reaches this file, the store, or
          # `nixos-rebuild` output.
          secrets = lib.mapAttrs (
            _key: entry: {
              inherit (entry) label;
              value = toString entry.value;
            }
          ) (cfg.secrets.byUser.${handle} or {});
        }
      );
    }
  );


in
{
  options = {
    services.sillytavern-nixos = {
    # ONE option holding every derived value, not a dozen.
    #
    # The per-option form (`internal.foo = mkOption { … }` plus a `mkDefault`
    # assignment in `config`) is the more conventional shape and was tried first.
    # It fails on this nixpkgs with "attribute 'deprecationMessage' missing"
    # raised from inside `lib/modules.nix` — an error that blames the option's
    # TYPE while the real problem is in the option system's handling of these
    # declarations. One `types.attrs` option has no such machinery and reads
    # perfectly well at the use site (`cfg.internal.renderedConfig`).
    #
    # `internal = true` keeps all of it out of generated documentation and out of
    # `nixos-option`, which matters for `secretEnvValues` in particular.
    internal = lib.mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = ''
        Derived values shared between this module's files: the rendered
        config.yaml and argv, the secrets environment mapping, the resolved user
        list, and the package with plugins installed. Set by this module; read
        only by services.nix and assertions.nix.

        The one value here that must never be treated as public is
        `secretEnvValues` — it holds secret VALUES as Nix attribute values, which
        anything able to evaluate the module config can read. Everything that
        needs a secret should use `secretEnvFiles`, which holds paths.
      '';
    };

    };
  };

  config = {
    services.sillytavern-nixos = {
      # Derived from `stateDirectory`, which systemd turns into
      # /var/lib/<stateDirectory>. Declared `internal` over `readOnly` — see the
      # note on `dataRoot` in modules/options.nix.
      dataRoot = lib.mkDefault "/var/lib/${cfg.stateDirectory}";
      dataRootPath = lib.mkDefault "/var/lib/${cfg.stateDirectory}";
    };

    # The derived values every other module file reads. Assigned as ONE
    # `types.attrs` option rather than a submodule — see the note on `internal`
    # in the options block below for why a submodule fails on this nixpkgs.
services.sillytavern-nixos.internal = {
  renderedConfig = renderedConfig;
  renderedArgv = renderedArgv;
      cliArgvList = cliArgvList;
  effectiveConfig = effectiveConfig;
  secretEnvFiles = secretEnvFiles;
  secretEnvValues = secretEnvEntries;
  envQuote = envQuote;
  hasSecrets = hasSecrets;
  packaged = packaged;
  certPackage = certPackage;
  keyPackage = keyPackage;
  resolvedUsers = resolvedUsers;
  healthcheckEnv = healthcheckEnv;
  seedSpec = seedSpec;
};

    # An absolute `ssl.certPath` / `ssl.keyPath` pointing into the store paths
    # that carry the certificate and key.
    #
    # This is the only way a Nix-built SillyTavern can find TLS material: the
    # server resolves a relative path against its own directory, and that
    # directory is the read-only store, so a relative path can only ever name
    # the file baked into the package.
    #
    # `mkIf` per option, not `mkMerge` of the whole `ssl` attrset: `ssl` is
    # declared as individual options (`ssl.enabled`, `ssl.certPath`, …) rather
    # than one submodule, so assigning to `services.sillytavern-nixos.config.ssl` as a
    # whole is a type error — NixOS reads that as defining a single option named
    # `ssl` and finding a lambda where an attrset of option definitions belongs.
    services.sillytavern-nixos.config.ssl = {
      certPath = lib.mkIf (certPackage != null) "${certPackage}/certs/cert.pem";
      keyPath = lib.mkIf (keyPackage != null) "${keyPackage}/certs/privkey.pem";
    };
  };
}
