# modules/home.nix
#
# The Home Manager half.
#
# ── Why this module exists at all ──────────────────────────────────────────────
#
# Everything about running the server is a SYSTEM concern: the process runs as a
# dedicated system user, the data root is a systemd `StateDirectory`, and the
# config file is a read-only store path. None of that belongs in a user's home
# directory.
#
# What IS a user concern is the other end of the connection: getting to the UI,
# and knowing which account to log in as. That is what this module does, and it is
# deliberately tiny — it wires the instance into whatever the user's browser and
# secret tooling already use.
#
# It reads the NixOS side through `osConfig`, so importing it WITHOUT a SillyTavern
# instance in scope is a no-op rather than an error. That is what makes it safe to
# put in a shared Home Manager configuration.
{
  config,
  lib,
  pkgs,
  osConfig,
  ...
}:

let
  cfg = config.sillytavern;

  # `services.sillytavern-nixos`, NOT `services.sillytavern`.
  #
  # nixos-unstable ships its own `services.sillytavern` module, so that option
  # path EXISTS in any system that has nixpkgs' module set — reading it here
  # silently picked up the wrong module. It then had no `config` sub-option at
  # all, so `instance.config.ssl.enabled` was a hard evaluation error:
  #
  #     error: attribute 'config' missing
  #     at modules/home.nix:47:34
  #
  # Which means this module could not be evaluated at all whenever a SillyTavern
  # instance was in scope. It only ever "worked" in the one case where it could
  # not: no instance, so `instance` was null and the URL fell back to
  # http://localhost:8000. The `or null` fallback hid the bug behind the exact
  # configuration it was supposed to help with.
  instance = osConfig.services.sillytavern-nixos or null;

  # An instance that exists but is switched off is as unusable as none at all,
  # and the distinction matters for the warning below.
  instanceEnabled = instance != null && instance.enable;

  # Only usable when the system actually runs one.
  enabled = cfg.enable && instanceEnabled;

  # `nixos` gives the port; falling back to upstream's 8000 keeps the module
  # usable against a system config that has not been evaluated with this flake.
  port = if instance != null then instance.config.port else 8000;

  # How the UI is reached. `url` is the full override when given, otherwise the
  # scheme/host/port the system config implies.
  # Hoisted out of `url`'s `else` branch: the login script exports
  # `SILLYTAVERN_HOST`, and a binding inside a `let` that only one branch of an
  # `if` can see is not in scope where it is needed.
  host = if cfg.host != null then cfg.host else "localhost";

  url =
    if cfg.url != null then
      cfg.url
    else
      let
        scheme =
          if instance != null && instance.config.ssl.enabled then "https" else "http";
      in
      "${scheme}://${host}:${toString port}${cfg.path}";
in
{
  options.sillytavern = {
    enable = lib.mkEnableOption "client-side integration with a NixOS-managed SillyTavern instance";

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://sillytavern.example.com";
      description = ''
        Full URL of the instance's UI. Overrides `host`, `path`, the port and the
        scheme — set it when SillyTavern is behind a reverse proxy with its own
        hostname, which is the common case.
      '';
    };

    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sillytavern.example.com";
      description = "Hostname to open. Defaults to `localhost`, i.e. reach the server directly.";
    };

    path = lib.mkOption {
      type = lib.types.str;
      default = "/";
      description = "Path prefix, if a reverse proxy mounts the instance under one.";
    };

    # ── Browser ──────────────────────────────────────────────────────────────

    openInBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add a `xdg-open`/`open` alias for the instance.

        This is a CLIENT-side convenience and is unrelated to
        `config.browserLaunch.enabled`, which is the SERVER trying to open a
        browser on its own host — that one has to stay false under systemd, and
        this option has no effect on it.
      '';
    };

    # ── Accounts ─────────────────────────────────────────────────────────────

    # Declared as a LIST rather than read from the system config, because the
    # system config exposes handles and file PATHS, not passwords, and a password
    # has no business crossing from a system module into a home configuration.
    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "seanc" ];
      description = ''
        Account handles to keep track of locally, used by `loginScript`.

        Take these from `services.sillytavern-nixos.users` on the system side; the
        handles are the attribute names there.
      '';
    };

    loginCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "${pkgs.curl}/bin/curl --fail-with-body --silent --show-error ...";
      description = ''
        Shell command that performs a login, for `loginScript`.

        Left as a string because a login needs a CSRF token and a session cookie
        (see docs/users.md), which is a curl invocation with two round trips. The
        point is that the Nix side records WHICH accounts exist, not how to
        authenticate as them.

        The generated script exports three variables before running it, and
        those are the whole contract:

          `ACCOUNT`            the chosen account handle
          `SILLYTAVERN_URL`    the instance base URL, scheme included
          `SILLYTAVERN_HOST`   just the host[:port]

        Refer to them as SHELL variables (`"$ACCOUNT"`, `"$SILLYTAVERN_URL"`),
        not as Nix interpolations. A Nix string is evaluated in the CALLER's
        scope, where those names are not bound, so the Nix spelling fails at
        evaluation with `undefined variable 'ACCOUNT'`. The same trap catches a
        half-written version that interpolates the sibling option `url`: a Nix
        attribute set is not recursive, so the key is not in scope either.

        `loginPackages` supplies whatever binaries the command shells out to.
      '';
    };

    loginScript = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Write a `sillytavern-login` script into `home.packages`, which runs
        `loginCommand` for the chosen account. Requires `loginCommand`.
      '';
    };

    loginPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      # `mktemp`, `cat` and `rm` come from coreutils, which
      # `writeShellApplication` always puts on PATH.
      default = with pkgs; [
        curl
        jq
      ];
      example = "[ pkgs.curl pkgs.jq pkgs.coreutils ]";
      description = ''
        Binaries `loginCommand` may invoke, put on the script's PATH.

        A `writeShellApplication` runs under `set -euo pipefail` with a minimal
        PATH, so without this a `loginCommand` calling `curl` or `jq` fails with
        "command not found" at the moment you actually try to log in.

        `coreutils` (`mktemp`, `cat`, `rm`, …) is always present and does not
        need listing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    warnings =
      (lib.optional (cfg.loginScript && cfg.loginCommand == null) ''
        sillytavern.loginScript is set but sillytavern.loginCommand is null.
        Nothing will be written to home.packages.
      '')
      ++ (lib.optional (cfg.enable && instance == null) ''
        sillytavern.enable is set but no `services.sillytavern-nixos` module was
        found in the system configuration, so the URL and port fall back to
        http://localhost:8000. Import the NixOS module too
        (`inputs.<name>.nixosModules.default`), or set `sillytavern.url`.
      '')
      ++ (lib.optional (cfg.enable && instance != null && !instance.enable) ''
        sillytavern.enable is set but `services.sillytavern-nixos.enable` is false
        on the system, so there is no instance to reach. The URL is still derived
        from the system config, but nothing will be listening on it.
      '')
      # The seedHandles lesson, applied here: an option that is enabled but
      # produces no observable output is indistinguishable from a typo. Both
      # outputs (`sillytavern-open`, `sillytavern-login`) are opt-in and default
      # to false, so `sillytavern = { enable = true; }` on its own silently does
      # nothing at all.
      ++ (lib.optional (cfg.enable && !cfg.openInBrowser && !cfg.loginScript) ''
        sillytavern.enable is set but neither sillytavern.openInBrowser nor
        sillytavern.loginScript is, and both default to false — so this module
        currently produces no output at all. Set one of them.
      '');

    home.packages =
      lib.optional (cfg.openInBrowser) (
        pkgs.writeShellApplication {
          name = "sillytavern-open";
          runtimeInputs = [ pkgs.xdg-utils ];
          text = ''
            exec xdg-open ${lib.escapeShellArg url}
          '';
        }
      )
      ++ lib.optional (cfg.loginScript && cfg.loginCommand != null) (
        pkgs.writeShellApplication {
          name = "sillytavern-login";
          runtimeInputs = cfg.loginPackages;
          text = ''
            accounts=(${lib.concatMapStringsSep " " lib.escapeShellArg cfg.accounts})

            if [ ''${#accounts[@]} -eq 0 ]; then
              echo "sillytavern-login: no accounts declared." >&2
              echo "Set sillytavern.accounts on the Home Manager side." >&2
              exit 1
            fi

            if [ ''${#accounts[@]} -eq 1 ]; then
              chosen=''${accounts[0]}
            else
              echo "Which account?" >&2
              select_account() {
                local i=1
                for a in "''${accounts[@]}"; do
                  printf '  %d) %s\n' "$i" "$a" >&2
                  i=$((i + 1))
                done
              }
              select_account
              read -r -p "Number: " reply
              if ! [[ "$reply" =~ ^[0-9]+$ ]] || [ "$reply" -lt 1 ] || [ "$reply" -gt "''${#accounts[@]}" ]; then
                echo "Not a valid choice." >&2
                exit 1
              fi
              chosen=''${accounts[$((reply - 1))]}
            fi

            # The contract `loginCommand` is written against. Exported, not
            # merely assigned: `$ACCOUNT` has to be visible inside whatever the
            # command turns out to be.
            export ACCOUNT="$chosen"
            export SILLYTAVERN_URL="${url}"
            export SILLYTAVERN_HOST="${host}"

            echo "sillytavern-login: logging in as $ACCOUNT at $SILLYTAVERN_URL" >&2
            ${cfg.loginCommand}
          '';
        }
      );
  };
}
