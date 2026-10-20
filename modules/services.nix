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
# ── 3. The access log needs no redirection at all ────────────────────────────
#
# `logging.enableAccessLog` opens `access.log` in the DATA ROOT, not in the
# server directory — `src/middleware/accessLogWriter.js:10`:
#
#   export const getAccessLogPath = () => path.join(globalThis.DATA_ROOT, 'access.log');
#
# which is exactly where `StateDirectory` puts it, and systemd exempts that
# directory from `ProtectSystem=strict`. So the option works as-is under this
# unit and the log lands in /var/lib/sillytavern/access.log.
#
# This note previously said the opposite, on the belief that the path was
# resolved against the read-only package directory, and carried an
# `accessLogMode` binding to "fix" it. Both were wrong and the binding was never
# used by anything: it was computed and dropped. There was also a matching claim
# in the `logging.enableAccessLog` option description.
#
# Recorded because the wrong belief is easy to re-derive — `server.js` does
# `process.chdir(serverDirectory)` at startup, and several other paths in this
# module are genuinely relative to it. This one is not.
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

  # ── Resource caps ───────────────────────────────────────────────────────────
  #
  # `hardware` is a submodule whose members are camelCase, and the unit's
  # directives are not. NixOS renders `serviceConfig` attribute names VERBATIM
  # into the unit file and systemd's directives are case-sensitive, so the two
  # spellings have to be translated. Verified by evaluating a unit with both
  # spellings set:
  #
  #   serviceConfig = { memoryMax = "4G"; MemoryMax = "8G"; ioWeight = "500"; }
  #     -> MemoryMax=8G
  #        memoryMax=4G          <- verbatim, unknown directive, IGNORED
  #        ioWeight=500          <- verbatim, unknown directive, IGNORED
  #
  # So a plain `// cfg.hardware` would produce a unit that looks configured and
  # caps nothing — silent, and the exact failure mode this project documents
  # everywhere else. This map is the whole reason.
  #
  # The two lists must stay in sync: this one and the `hardware` submodule in
  # modules/options.nix. Adding a cap to the option without adding it here is a
  # loud failure, not a silent one — `systemdHardwareName.${name}` raises
  # "attribute '<name>' missing" at evaluation, naming the option that has no
  # mapping.
  systemdHardwareName = {
    memoryMax = "MemoryMax";
    memoryHigh = "MemoryHigh";
    memorySwapMax = "MemorySwapMax";
    cpuQuota = "CPUQuota";
    nice = "Nice";
    ioWeight = "IOWeight";
  };

  # Both transformations in one: drop the unset caps, then rename what is left.
  #
  # `lib.filterAttrs` rather than a raw `cfg.hardware`: every member defaults to
  # null, and injecting `MemoryMax = null` into serviceConfig breaks the
  # `attrsOf unitOption` merge with "attribute 'optionalValue' missing" raised
  # from inside lib/types.nix.
  #
  # `lib.mapAttrs'` hands each result to `listToAttrs`, which wants
  # `{ name, value; }` pairs — hence `lib.nameValuePair`.
  hardwareConfig =
    lib.filterAttrs (_: value: value != null) (
      lib.mapAttrs' (name: value: lib.nameValuePair systemdHardwareName.${name} value) cfg.hardware
    );

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

  # `mkUserArg` ALREADY shell-escapes each result, so these must not be escaped a
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
        "https://github.com/Cairnstew/SillyTavern"
      ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Without this the unit is ordered after `network-online.target` but
      # nothing ever PULLS IT IN, so it never starts at boot and `systemctl
      # status sillytavern` reports "inactive (dead)" on a freshly booted host
      # with no error anywhere. `enable = true` is understood to mean "runs".
      #
      # `multi-user.target`, matching every other NixOS service. The two sibling
      # units in this file set the same thing for themselves.
      wantedBy = [ "multi-user.target" ];

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

        # Console output goes to the journal. The FILE access log is separate and
        # needs nothing here: it goes to <dataRoot>/access.log, which
        # `StateDirectory` already makes writable. See header note 3.
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
      # hardwareConfig, then the consumer's `systemdOverrides.serviceConfig`,
      # so an override ADDS to or REPLACES individual directives rather than
      # replacing the whole block. See the note on the `//` at the end of this
      # unit for the trap this avoids.
      // hardwareConfig
      // (cfg.systemdOverrides.serviceConfig or { });

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
    }

    # `cfg.systemdOverrides`, with `serviceConfig` removed and merged into the
    # serviceConfig above instead.
    #
    # It used to be a plain `// cfg.systemdOverrides` on the whole unit. That
    # is a trap with a very small diff and a very large blast radius, because
    # attrset `//` REPLACES rather than merges: the moment a consumer set
    # `systemdOverrides.serviceConfig.ReadWritePaths`, the entire serviceConfig
    # above it was discarded and rebuilt from that one key alone. Verified
    # live, using the example this project itself documents:
    #
    #   systemdOverrides = { serviceConfig.ReadWritePaths = [ "/tmp/x" ]; };
    #   -> serviceConfig keys: [ "ExecStartPre" "ReadWritePaths" ]
    #
    # which is a unit with no `ExecStart` (so it never starts), no `User` or
    # `Group` (so it would run as root if it did), no `StateDirectory` (so the
    # data root is never created, and `ProtectSystem=strict` would leave it
    # unwritable), and none of the hardening block. `nixos-rebuild` stays green
    # throughout; the failure surfaces only as a dead service after a switch.
    #
    # So `serviceConfig` is merged explicitly, the override winning per key,
    # and everything else is still a plain shallow `//`, which is right for
    # scalar unit options like `description` and `restartTriggers`.
    #
    # Consequence worth knowing: a consumer CANNOT remove a directive this
    # module sets (systemd has no "unset" for `Type=simple`), only change it.
    # Setting it to `""` is the usual escape hatch and renders as `Type=`,
    # which systemd ignores.
    // lib.removeAttrs cfg.systemdOverrides [ "serviceConfig" ];

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

    # ── access.log rotation ───────────────────────────────────────────────────
    #
    # `logging.enableAccessLog` defaults to TRUE and writes to
    # `<dataRoot>/access.log`, which `StateDirectory` makes writable — so the
    # option works, and the file grows without bound on a busy instance. There
    # was no logrotate configuration and no tmpfiles rule anywhere in the tree,
    # which on a long-lived server is a slow disk leak nobody thinks about.
    #
    # A tmpfiles rule is the right primitive rather than logrotate: the file
    # lives under `/var/lib`, which is exactly what `systemd-tmpfiles` manages,
    # and it needs no timer, no copytruncate dance, and no extra package on the
    # closure. SillyTavern holds the file open in append mode
    # (`src/middleware/accessLogWriter.js`), and `z` rotation renames rather
    # than truncates, so the server keeps writing to the renamed inode until it
    # restarts — which is fine, because the NEXT file is fresh.
    #
    # `z path mode user group age count`: keep up to 30 rotations, each no older
    # than 30 days, and stop rotating past that. `0644` because every entry is a
    # connection's source address, and `sillytavern:sillytavern` rather than the
    # configured `user`/`group` because systemd-tmpfiles runs as root before any
    # user exists — the names, not the ids, are what it needs.
    #
    # Gated on the log actually being enabled, so disabling it does not leave a
    # rule behind for a file that will never exist.
    systemd.tmpfiles.rules =
      #
      # `lib.optional COND "rule"`, NOT `lib.optional COND [ "rule" ]`.
      # `lib.optional` already wraps its element in a list, so passing a list
      # yields `[[ "rule" ]]` — one entry that is a list, which this
      # `types.listOf types.str` option rejects with
      # `not of type 'string'` naming entry 1.
      lib.optional (cfg.config.logging.enableAccessLog)
        "z ${cfg.dataRoot}/access.log 0644 sillytavern sillytavern 30d 1024";

    # ── Firewall ──────────────────────────────────────────────────────────────
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.config.port ];
  };
}
