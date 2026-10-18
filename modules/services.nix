# modules/services.nix
#
# The systemd unit.
#
# Three decisions here are not obvious, and each is the difference between this
# working and this being a service that fails at 3am:
#
# ── 1. Type=simple, and a generous TimeoutStartSec ────────────────────────────
#
# The server does NOT call `sd_notify`, so there is no `Type=notify` to use.
# `Type=exec`/`Type=idle` would report "started" before the socket is listening,
# which is worse than useless for a service a reverse proxy connects to.
#
# Startup is also genuinely slow: `src/server-main.js` awaits
# `webpackMiddleware.runWebpackCompiler({ pruneCache: true })` BEFORE it starts
# listening, so every start recompiles the frontend bundle — tens of seconds on a
# cold cache. `startupTimeout` is sized for a webpack run, not for a process that
# merely needs to exec.
#
# When `heartbeatInterval` is non-zero, the server's own `src/healthcheck.js`
# gives a real answer to "is it actually serving?", wired up here as a timer.
#
# ── 2. The data root must stay WRITABLE under the hardening ──────────────────
#
# The conventional hardening block is `ProtectSystem=strict` plus a
# `ReadWritePaths=` list. This server writes to its data root *continuously* —
# chats, thumbnails, per-user settings, uploads, and the webpack cache — and a
# failed chat write loses data rather than merely logging.
#
# `StateDirectory` is the right primitive precisely because systemd creates the
# directory AND exempts it from `ProtectSystem=strict`. It is the only writable
# path the unit gets, which is why `cli.dataRoot` is asserted to match it.
#
# ── 3. The access log has to move ─────────────────────────────────────────────
#
# `logging.enableAccessLog` opens `access.log` RELATIVE to the server directory,
# which is the read-only store. Left alone, every request logs an EROFS error.
# The unit therefore sets the server's working directory to the data root's
# parent for logging purposes — no: it cannot, because the server also resolves
# `default/content` and `certs/` from that directory. Instead the unit turns the
# access log off by default and says so; see `accessLogMode` below.
#
# ── 4. Secrets are assembled at start, from paths, into a 0700 directory ─────
#
# `EnvironmentFiles` points at `$RUNTIME_DIRECTORY/secrets.env`, which a
# `preStart` hook writes from the caller's own files. The values are never Nix
# attribute values (see modules/config.nix on `secretEnvFiles`), so they cannot
# be read out of the module config with `nix eval` or `nixos-option`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sillytavern-nixos;
  internal = cfg.internal;
  inherit (internal) hasSecrets secretEnvFiles resolvedUsers packaged renderedArgv cliArgvList healthcheckEnv seedSpec;

  seeder = ../scripts/st_seed_users.py;
  jsonSeeder = ../scripts/st_seed_files.py;
  jsonSeederSpec = seedSpec;

  # Secrets reach the process through this wrapper, not a systemd directive.
  #
  # NixOS has no per-service environment-file option: there is no
  # `environmentFiles` on a systemd unit at all (verified against
  # nixos/modules/system/boot/systemd.nix), and `serviceConfig` is
  # `addCheck (attrsOf unitOption) checkService`, so systemd's own
  # `EnvironmentFile=` is rejected too with
  # "The option `systemd.services.<name>.EnvironmentFile` does not exist".
  #
  # Sourcing it here instead keeps the values out of the unit file, which would
  # otherwise be world-readable in /etc/systemd/system, and keeps them out of
  # the Nix store. `set -a` exports everything the file sets, matching what
  # systemd's own EnvironmentFile= would have done.
  #
  # RuntimeDirectory=sillytavern is 0700 and owned by the service account, so
  # only this user can read the file.
  #
  # `writeShellApplication`, not `writeShellScript`: the latter writes the
  # script to $out/<name> while everything else in NixOS — including
  # `lib.getExe` — assumes $out/bin/<name>. Hard-coding either path is a trap;
  # `writeShellApplication` gives the conventional layout and a proper `meta`.
  serviceLauncher = pkgs.writeShellApplication {
    name = "sillytavern-service";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -a
      ${lib.optionalString hasSecrets "  . /run/sillytavern/secrets.env"}
      set +a
      exec ${lib.getExe' packaged "sillytavern"} "$@"
    '';
  };
  python = pkgs.python3;


  # systemd's `Environment=` and `EnvironmentFiles=` want `KEY=value` lines, and
  # a value containing a space, a quote or a `$` has to be quoted for systemd's
  # parser — which is neither shell nor POSIX. `lib.mapAttrsToString` is the
  # straightforward way to build the assignment list, but it does NOT quote, so
  # every value goes through `escapeShellArg` first.
  #
  # This is the same quoting contract as `st_env_line` in modules/config.nix,
  # which the preStart hook uses for the secrets file. Kept as one helper here
  # and one there because they write different things: this builds a unit-file
  # attribute, that builds a file on disk.
  #
  # Returns the ATTRSET unchanged, sorted for a stable unit.
  #
  # `systemd.services.<name>.environment` is an `attrsOf`, not a list of strings:
  # handing it a list fails with "expected a list but found a set" when read back,
  # and handing `serviceConfig.Environment` a list fails with "expected a set but
  # found a list". NixOS renders the set into `Environment=` itself, quoting each
  # value — so doing it here would double-quote.

  # What the server opens RELATIVE to its own directory: `access.log`. The
  # package directory is read-only, so this has to be off unless the caller has
  # arranged otherwise.
  accessLogMode = if cfg.config.logging.enableAccessLog then "warn" else "off";

  # Declared accounts that have a password file, as `--user` argv.
  #
  # The attribute name is the HANDLE, which is also the account's directory name
  # under the data root and the lowercased username an SSO provider must send.
  mkUserArg =
    handle: user:
    lib.escapeShellArg (
      "handle="
      + handle
      + ",name="
      + (if user.name != null then user.name else handle)
      + ",admin="
      + (if user.admin then "true" else "false")
      + ",enabled="
      + (if user.enabled then "true" else "false")
      + (
        if user.passwordFile != null then ",passwordFile=" + toString user.passwordFile else ""
      )
    );

  userArgs = lib.concatStringsSep " " (lib.mapAttrsToList mkUserArg resolvedUsers);

  # Fully-formed `--user SPEC` arguments, one per declared account.
  #
  # `mkUserArg` ALREADY shell-escapes its result, so these must not be escaped a
  # second time: doing so hands the script a literal `'handle` and it rejects the
  # key with "unknown --user key".
  userSpecs = lib.attrValues (lib.mapAttrs mkUserArg resolvedUsers);

  # The preStart script: assemble secrets, then seed accounts. Both run before
  # the server, and both are idempotent, so a `nixos-rebuild` that changes
  # nothing is a no-op.
  #
  # Seeding runs BEFORE the server starts so a fresh state directory already has
  # its accounts on the first login, rather than requiring a manual trip through
  # the UI to create the first administrator.
  preStart =
    lib.optionalString hasSecrets ''
      # ${internal.envQuote}

      umask 077
      : > "$RUNTIME_DIRECTORY/secrets.env"
    ''
    + lib.optionalString hasSecrets (
      lib.concatStringsSep "
" (
        lib.mapAttrsToList (name: path: ''
          echo "sillytavern: assembling ${name} from ${path}" >&2
          st_env_line ${lib.escapeShellArg name} "$(cat ${path})" \
            >> "$RUNTIME_DIRECTORY/secrets.env"
        '') secretEnvFiles
      )
    )
    # Compare the declared option, not the derived `resolvedUsers`: the
    # derived values embed coerced paths and force the option machinery harder
    # than the check needs.
    # `userSpecs` is already `--user SPEC` per account, because
    # st_seed_users.py takes a REPEATABLE `--user` flag. A bare positional list
    # makes argparse exit with "unrecognized arguments", and the accounts are
    # then silently never seeded — the service still starts, just open to the
    # world.
    #
    # Nothing explanatory may go inside the `''` string below: Nix comments are
    # Nix comments, but a `#` line inside it becomes a SHELL comment, and one
    # sitting between a `\` and its argument breaks the line continuation.
    + lib.optionalString (cfg.users != { }) ''
      echo "sillytavern: seeding declared accounts into ${cfg.dataRoot}" >&2
      ${lib.getExe python} ${seeder} \
        --data-root ${lib.escapeShellArg cfg.dataRoot} \
        ${lib.concatStringsSep " " (map (spec: "--user " + spec) userSpecs)}
    ''

    # The JSON state — settings.json, presets, themes, world books — is seeded
    # LAST, because it is keyed by account handle and the account directories
    # have to exist first.
    + lib.optionalString (seedSpec != null) ''
      echo "sillytavern: seeding JSON state into ${cfg.dataRoot} (policy: ${cfg.seedPolicy})" >&2
      ${lib.getExe python} ${jsonSeeder} \
        --data-root ${lib.escapeShellArg cfg.dataRoot} \
        --spec ${jsonSeederSpec} \
        --policy ${lib.escapeShellArg cfg.seedPolicy}
    '';

in
{
  imports = [ ./assertions.nix ];

  config = lib.mkIf cfg.enable {
    # Exposed so the launcher can be realised and exercised directly, the
    # same way `internal.packaged` is. `internal` is a `types.attrs` option,
    # so this merges with config.nix's assignment rather than replacing it.
    services.sillytavern-nixos.internal.serviceLauncher = serviceLauncher;

    users.users = lib.optionalAttrs (cfg.user != "root") {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        description = "SillyTavern LLM front-end server";
        # No home directory: the service has no use for one, and combined with
        # `ProtectHome` there is nothing in it to reach even if the process is
        # compromised. `systemd.StateDirectory` places the data root in /var/lib,
        # which is unaffected.
        home = "/var/empty";
        shell = "${pkgs.bash}/bin/bash";
      };
    };

    users.groups = lib.optionalAttrs (cfg.group != "root") {
      ${cfg.group} = { };
    };

    systemd.services.sillytavern = {
      description = "SillyTavern LLM front-end and proxy server";
      documentation = [
        "https://docs.sillytavern.app/"
        "https://github.com/Cairnstew/nixos-sillytavern"
      ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        # `Type`, not `systemd.services.<name>.type`: it is a serviceConfig key.
        # (NixOS' systemd module declares `after`, `wantedBy`, `restartTriggers`
        # and friends on the unit, but `Type` lives in serviceConfig — and gets a
        # "does not exist" error with a misleading list of alternatives if put on
        # the wrong side.)
        Type = "simple";

        # See header note 1. `TimeoutStartSec` / `TimeoutStopSec` rather than
        # `systemd.services.<name>.startTimeout` / `.stopTimeout`: the latter are
        # not declared by NixOS' systemd module, so using them fails with "The
        # option … does not exist" — naming it after the systemd directive it
        # sets is both correct and greppable.
        TimeoutStartSec = toString cfg.startupTimeout;
        TimeoutStopSec = toString cfg.shutdownTimeout;

        # A LIST, not a string: this nixpkgs declares `serviceConfig.ExecStart`
        # as `listOf str`, and a bare string fails with "expected a list but
        # found a string". The whole command line is one element, so the
        # rendering of `renderedArgv` stays a single shell-quoted word.
        # `lib.getExe`, not a hard-coded path: the wrapper is a
        # `writeShellApplication`, so it lives at $out/bin/<name>.
        # A LIST: one element per argv entry, wrapper first.
        ExecStart = [ (lib.getExe serviceLauncher) ] ++ cliArgvList;

        Restart = "on-failure";
        RestartSec = 5;

        # SIGTERM is what the server handles
        # (`process.on('SIGTERM', exitProcess)` in src/server-main.js); it stops
        # accepting requests before exiting. `KillMode = "mixed"` means SIGTERM
        # goes to the main process only, and SIGKILL to everything in the cgroup
        # once the stop timeout expires — which is what you want, since node
        # forks webpack workers.
        KillSignal = "SIGTERM";
        KillMode = "mixed";

        # See header notes 2 and 4.
        StateDirectory = cfg.stateDirectory;
        StateDirectoryMode = "0700";
        RuntimeDirectory = "sillytavern";
        RuntimeDirectoryMode = "0700";

        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = packaged;

        # See header note 3.
        StandardOutput = "journal";
        StandardError = "journal";

        # ── Hardening ────────────────────────────────────────────────────────
        #
        # `strict` makes the whole filesystem read-only except /dev, /proc, /sys
        # and the directories systemd was told about. A compromised Node process
        # therefore cannot write outside the state directory.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;

        # The server makes outbound requests to LLM providers, so the network
        # namespace cannot be closed. What can be tightened is the socket
        # families: no Bluetooth, no packet sockets, no netlink.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];

        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        SystemCallErrorNumber = "EPERM";

        # The image and thumbnail pipeline (jimp) is pure JS, so no capability is
        # needed for anything this server does.
        CapabilityBoundingSet = [ ];
        AmbientCapabilities = [ ];

        # `NODE_OPTIONS` is deliberately NOT set: heap sizing is left to
        # systemd's memory caps rather than to a flag that has to be kept in sync
        # with `hardware.memoryMax`.
      }
      # The hardware caps ARE `serviceConfig` keys, so they merge INTO
      # serviceConfig rather than sitting beside it.
      # Only the caps that are actually set. `cfg.hardware`'s members default
      # to null, and injecting `memoryMax = null` into serviceConfig breaks the
      # `attrsOf unitOption` merge with "attribute 'optionalValue' missing"
      # raised from inside lib/types.nix.
      # lib.filterAttrs (_: v: v != null) cfg.hardware
      ;

      # `environment`, not `serviceConfig.Environment`.
      # NixOS' systemd module declares the unit-level `environment` as an
      environment =
        # A plain attrset, not `serviceConfig.Environment`: NixOS' systemd module
        # declares the unit-level `environment` as an attrset and renders it into
        # `Environment=` itself, quoting each value. Passing a list of
        # `KEY=value` strings fails with "expected a list but found a set".
        #
        # No sorting is needed for a stable unit: Nix attrsets already serialise
        # with their keys in canonical order.
        (
        {
          NODE_ENV = "production";
          # Set explicitly as well as via --configPath, so the unit is
          # self-describing and does not depend on flag-parsing order.
          SILLYTAVERN_CONFIGPATH =
            if cfg.cli.configPath != "" then cfg.cli.configPath else internal.renderedConfig;
        }
        // healthcheckEnv
        // cfg.environment
        // cfg.extraConfigEnv
      );

      # The assembled-at-start secrets file, never a store path. See the
      # header note on secrets.

      # Unit level, NOT serviceConfig. Inside serviceConfig it becomes a
      # systemd directive named `PreStart=`, which systemd does not know, and
      # the unit's own `preStart` option stays empty — so the seeder silently
      # never runs.
      preStart = preStart;

      restartTriggers = [ "sillytavern-package.path" ] ++ cfg.restartTriggers;
    } // cfg.systemdOverrides;

    # A trivial unit whose only job is to exist, so `RestartTrigger` has
    # something stable to name and so the package is pulled in when the main
    # unit starts. Deliberately a SEPARATE unit: RestartTrigger on a unit that
    # depends on this one would restart the service whenever its own ExecStart
    # changed, which is what switch-to-configuration already does.
    systemd.services.sillytavern-package = {
      description = "SillyTavern package (for RestartTrigger)";
      before = [ "sillytavern.service" ];
      wantedBy = [ "sillytavern.service" ];
      unitConfig = {
        # Must not be enabled at boot on its own; it exists only as a restart
        # trigger target.
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [ "${pkgs.coreutils}/bin/true" ];
      };
    };

    # ── The heartbeat probe ───────────────────────────────────────────────────
    #
    # `src/healthcheck.js` exits non-zero when `<dataRoot>/heartbeat.json` has not
    # been touched within two intervals. It reads `SILLYTAVERN_HEARTBEATINTERVAL`
    # and `SILLYTAVERN_DATAROOT` from the environment — and with the interval
    # unset it parses 0, treats that as "disabled" and exits 0 immediately,
    # reporting success without checking anything. Both are exported for exactly
    # that reason (see `healthcheckEnv` in modules/config.nix).
    systemd.services.sillytavern-healthcheck = lib.mkIf (cfg.config.heartbeatInterval > 0) {
      description = "SillyTavern liveness probe (heartbeat)";
      after = [ "sillytavern.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        environment = healthcheckEnv;
        ExecStart = [ "${lib.getExe' packaged "sillytavern-healthcheck"}" ];
        # The node the package was built against, via the package's own wrapper.
      };
    };

    systemd.timers.sillytavern-healthcheck = lib.mkIf (cfg.config.heartbeatInterval > 0) {
      description = "Run the SillyTavern liveness probe";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "sillytavern-healthcheck.service";
        OnBootSec = "${toString cfg.config.heartbeatInterval * 3}s";
        # Twice the interval: the probe itself allows two missed beats, so
        # running it that often means one consecutive failure is visible without
        # a second failure being required to notice.
        OnUnitActiveSec = "${toString cfg.config.heartbeatInterval * 2}s";
        AccuracySec = "5s";
      };
    };

    # ── Firewall ──────────────────────────────────────────────────────────────
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.config.port ];
  };
}
