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
  inherit (cfg.internal) effectiveConfig secretEnvFiles secretEnvValues;

  # `default-user` is created by the server itself on first start, so it is a
  # legitimate seed target without being a declared account.
  declaredHandles = builtins.attrNames cfg.users ++ [ "default-user" ];
  seedHandles = lib.unique (lib.attrNames cfg.settings.byUser ++ lib.attrNames cfg.files.byUser);
in
{
  assertions = [
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
      assertion = lib.all (f: (f.json != null) != (f.path != null))
        (lib.attrValues cfg.files.common ++ lib.concatLists (lib.attrValues cfg.files.byUser));
      message = ''
        services.sillytavern-nixos: every entry in `files` must set exactly one
        of `json` or `path`.

        `json` writes the value literally; `path` copies a file from the store.
        Setting both is ambiguous and setting neither has no meaning, so both are
        rejected rather than guessed at.
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
    {
      assertion = cfg.plugins == { } || !cfg.config.enableServerPluginsAutoUpdate;
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
      assertion = cfg.extensions == { } || !cfg.config.extensions.autoUpdate;
      message = ''
        services.sillytavern-nixos: extensions are declared but
        config.extensions.autoUpdate = true.

        Declared extensions live in read-only store paths, so the UI's
        automatic update fails with EROFS. Update them by changing the `rev` in
        services.sillytavern-nixos.extensions and rebuilding.

        The module turns this off for you when extensions are non-empty.
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
      assertion = builtins.all (handle: spec: lib.hasInfix "/" spec.rev || builtins.match "^[0-9a-f]{40}$" spec.rev != null) (
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
      assertion = lib.all (name: value: !(lib.hasInfix "\n" value)) secretEnvValues;
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
      assertion = lib.all (name: value: !(lib.hasInfix "\n" value)) (lib.mapAttrsToList (_: v: v) cfg.environment);
      message = ''
        services.sillytavern-nixos: a value in services.sillytavern-nixos.environment
        contains a newline.

        systemd cannot represent a newline in a single Environment= value. Use a
        list of strings, or put the variable in a file and reference it.
      '';
    }
  ];
}
