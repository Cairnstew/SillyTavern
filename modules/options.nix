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

  # ── Shared submodules ───────────────────────────────────────────────────────

  # `[ width, height ]`, as `thumbnails.dimensions.*` is shaped upstream: a
  # mapping of kind -> pair, not a list of pairs.
  dimensionPair = types.submodule {
    options = {
      width = mkOption {
        type = types.ints.positive;
        default = 0;
        description = "Pixel width.";
      };
      height = mkOption {
        type = types.ints.positive;
        default = 0;
        description = "Pixel height.";
      };
    };
  };

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
      };
      path = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "./my-theme.json";
        description = "A file copied verbatim from the store. Use this for presets too large to inline.";
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
      defaultText = literalExpression "pkgs.sillytavern";
      description = "The SillyTavern package to run.";
    };

    # ── The data root ─────────────────────────────────────────────────────────

    # Derived, not set directly: `StateDirectory = "sillytavern"` gives
    # /var/lib/sillytavern, and the module passes that to `--dataRoot`. Making it
    # an option would only create a second way to be wrong.
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
      internal = true;
      default = "/var/lib/sillytavern";
      defaultText = "/var/lib/${config.services.sillytavern-nixos.stateDirectory}";
      description = "Resolved absolute data root, derived from `stateDirectory`.";
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
            Write an access log. Note this is a FILE (`access.log`, in the
            server directory by default) as well as console output — under a Nix
            build the server directory is read-only, so the module redirects it
            into the state directory. See modules/config.nix.
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
            default = {
              width = 160;
              height = 90;
            };
            description = "Thumbnail size for background images.";
          };
          avatar = mkOption {
            type = dimensionPair;
            default = {
              width = 96;
              height = 144;
            };
            description = "Thumbnail size for character avatars.";
          };
          persona = mkOption {
            type = dimensionPair;
            default = {
              width = 96;
              height = 144;
            };
            description = "Thumbnail size for user personas.";
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
              max_context = 32768;
            };
            power_user = {
              user_name = false;
              quick_ui = true;
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
          see `config.customUrl` / `config.openaiModel` for the server-side
          equivalents.
        '';
      };

      byUser = mkOption {
        type = types.attrsOf jsonObject;
        default = { };
        example = literalExpression ''{ seanc = { oai_settings.max_context = 131072; }; }'';
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
        };
      });
      default = [ ];
      example = literalExpression ''[ self.lib.mkProxyUpstream { inherit config; } ]'';
      description = ''
        Reverse-proxy upstreams describing this instance.

        Deliberately just DATA: this project does not depend on any particular
        reverse-proxy module, so it cannot open a proxy hole for you. Wire it into
        whatever you use:

          proxy.upstreams = lib.mkMerge (map mkUpstream
            (config.services.sillytavern-nixos.proxyUpstreams));

        `self.lib.mkProxyUpstream { inherit config; }` builds the default entry.
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
          Restart = "always";
          LimitNOFILE = 65536;
        }
      '';
      description = ''
        Raw systemd unit options merged last, after everything this module sets.

        The escape hatch for the unit, equivalent in spirit to `extraConfig` for
        `config.yaml`. Not validated.
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

    # ── Reverse-proxy helpers exposed as config ───────────────────────────────

    dataRootPath = mkOption {
      type = types.str;
      internal = true;
      default = "/var/lib/sillytavern";
      defaultText = "/var/lib/${config.services.sillytavern-nixos.stateDirectory}";
      description = ''
        Alias of `dataRoot`, kept so `homeModules` can read it without reaching
        into a system option from a Home Manager module.
      '';
    };
  };
}
