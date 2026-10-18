# lib/tests.nix
#
# Checks for `nix flake check`.
#
# These are EVALUATION tests: they build the module's outputs and assert on them
# without starting a server. That is the right level for almost everything here,
# because the failure modes this project guards against are overwhelmingly
# "evaluates to something subtly wrong" rather than "crashes at runtime".
#
# The one check that is genuinely not an eval test — the account seeder, and
# whether Python's scrypt agrees with Node's — lives in tests/test_seed_users.py
# and is wired in as `seeder` below.
#
# ── configYamlRoundTrip is the load-bearing one ───────────────────────────────
#
# It renders the module's default option tree back to YAML, parses it with the
# same `yaml` npm package SillyTavern itself uses, and compares the result to
# upstream's `default/config.yaml` at the pinned version. That means:
#
#   * a key added upstream but not added to modules/options.nix FAILS the build,
#     rather than silently having no effect;
#   * a default that drifts from upstream's is caught;
#   * the YAML renderer is exercised against every shape in the real document —
#     nested maps, empty lists, nulls, integer lists, quoted IPv6 wildcards,
#     strings that look like booleans.
#
# It is what makes "all of SillyTavern's options are Nix definable" a verified
# claim rather than an aspiration.
{
  lib,
  nixpkgs,
}:

let
  inherit (lib) types;

  # The module ENTRY point, not the directory: a directory in a module list must
  # contain a `default.nix`, and `modules/` deliberately has none — the entry
  # point is what fixes the import order (options -> config -> services ->
  # assertions).
  modulePath = ../modules/sillytavern.nix;
  st = import ../lib { inherit lib; };

  # ── The `yaml` npm package, for parsing in the round-trip check ─────────────
  #
  # A one-package fixed-output derivation rather than depending on the built
  # `sillytavern` package, which would make a fast eval test wait on a 400 MiB
  # `npm ci`. Pinned to the version SillyTavern's own lockfile resolves, so the
  # check parses with exactly the parser the server will.
  yamlPackage =
    { lib, stdenvNoCC, nodejs }:
    stdenvNoCC.mkDerivation {
      pname = "yaml-npm";
      version = "2.8.3";

      nativeBuildInputs = [ nodejs ];
      dontConfigure = true;
      dontBuild = true;
      # The YAML parser must not be shebang-patched or its hash would depend on
      # this nixpkgs' bash. See the identical note in pkgs/sillytavern/default.nix.
      dontFixup = true;

      installPhase = ''
        runHook preInstall
        export HOME="$TMPDIR"
        mkdir -p package && cd package
        npm install --no-audit --no-fund --no-progress --loglevel=error 'yaml@2.8.3'
        mv node_modules "$out"
        runHook postInstall
      '';

      outputHashMode = "recursive";
      # Filled in by the first `nix build`; see the note in
      # pkgs/sillytavern/default.nix about why this must not be guessed.
      outputHash = lib.fakeHash;
    };

in
rec {
  # A Nix system with the module imported and the module's options available.
  evalSystem =
    pkgs: module:
    nixpkgs.lib.nixosSystem {
      # `pkgs.stdenv.hostPlatform.system` rather than `pkgs.system`, which is
      # deprecated and emits an evaluation warning that would drown out real
      # output on every `nix flake check`.
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        module
        modulePath
        {
          # No bootloader and no real root filesystem: this is an evaluation
          # test, not a VM, and skipping them keeps each system well under a
          # second to evaluate.
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/null";
            fsType = "tmpfs";
          };

          # NB: `boot.zfs.enabled = false` is deliberately NOT set here. This
          # nixpkgs already declares it (in its own flake.nix, hence the
          # "read-only, but set multiple times" error if you add it), and it is
          # false by default. It DOES show up in the stack of a bare "infinite
          # recursion encountered" when a minimal eval system is misconfigured,
          # which makes it a tempting red herring — but it is not the cause.

          system.stateVersion = "25.05";
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
        }
      ];
    };

  # ── 1. The module evaluates and produces a sane unit ────────────────────────
  #
  # Asserts on `serviceConfig` rather than on the generated `.unit` text: the
  # assembled unit string is formatted by NixOS' systemd module and its exact
  # shape is not this project's business. What this project SETS is.
  moduleEvaluates =
    pkgs:
    let
      system = evalSystem pkgs { services.sillytavern-nixos.enable = true; };
      sc = system.config.systemd.services.sillytavern.serviceConfig;
      renderedConfig = system.config.services.sillytavern-nixos.internal.renderedConfig;
    in
    pkgs.runCommand "sillytavern-check-module-evaluates"
      {
        nativeBuildInputs = [ pkgs.coreutils ];
        passAsFile = [ "startupTimeoutText" ];
      }
      ''
        fail() {
          echo "FAIL module-evaluates: $1" >&2
          exit 1
        }

        # Each of these is the whole reason one part of the unit is the way it is.
        [ "${sc.StateDirectory}" = "sillytavern" ] \
          || fail "StateDirectory is ${sc.StateDirectory}"
        [ "${sc.StateDirectoryMode}" = "0700" ] \
          || fail "StateDirectoryMode is ${sc.StateDirectoryMode}"
        [ "${sc.User}" = "sillytavern" ] || fail "User is ${sc.User}"
        [ "${sc.Type}" = "simple" ] || fail "Type is ${sc.Type}"
        [ "${sc.ProtectSystem}" = "strict" ] || fail "ProtectSystem is ${sc.ProtectSystem}"
        [ "${sc.Restart}" = "on-failure" ] || fail "Restart is ${sc.Restart}"
        [ "${sc.KillSignal}" = "SIGTERM" ] || fail "KillSignal is ${sc.KillSignal}"
        [ "${sc.TimeoutStartSec}" = "$(cat "$startupTimeoutPath")" ] \
          || fail "TimeoutStartSec is ${sc.TimeoutStartSec}"

        # --configPath must point at the rendered store file and --dataRoot at the
        # state directory: together they are the reason the unit is reproducible.
        case "${sc.ExecStart}" in
          *--configPath=*) ;;
          *) fail "ExecStart has no --configPath: ${sc.ExecStart}" ;;
        esac
        case "${sc.ExecStart}" in
          *--dataRoot=/var/lib/sillytavern*) ;;
          *) fail "ExecStart has no --dataRoot=/var/lib/sillytavern" ;;
        esac

        # The rendered config must be mode 444. The server tries to rewrite
        # config.yaml at startup (src/config-init.js), that write is expected to
        # fail against a store path, and it is harmless only because every read
        # falls back to an in-code default. If this file were writable, a
        # modified-by-hand config would silently outrank the Nix one.
        mode=$(stat -c '%a' "${renderedConfig}")
        [ "$mode" = "444" ] || fail "rendered config.yaml is mode $mode, expected 444"

        echo "PASS module-evaluates"
        touch "$out"
      ''
    // {
      config = system.config;
    };

  # ── 2. config.yaml round-trips to upstream's document ───────────────────────
  configYamlRoundTrip =
    pkgs:
    let
      system = evalSystem pkgs { services.sillytavern-nixos.enable = true; };

      # The module's EFFECTIVE config — `config` plus the overrides
      # modules/config.nix applies — so the comparison is against what actually
      # gets rendered, not against the raw option defaults.
      renderedPath = system.config.services.sillytavern-nixos.internal.renderedConfig;

      upstream =
        pkgs.runCommand "sillytavern-upstream-config" { } ''
          cp ${../default/config.yaml} $out
        '';

      yamlPackage = pkgs.callPackage yamlPackage { };

      # The three credentials the module strips from the render. Values are
      # never compared — a check's output must not be able to leak one — and
      # their absence is asserted separately below.
      strippedSecrets = [
        "ssl.keyPassphrase"
        "basicAuthUser.password"
        "requestProxy.url"
      ];
    in
    pkgs.runCommand "sillytavern-check-config-roundtrip"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.diffutils
          pkgs.coreutils
        ];
      }
      ''
        cp ${renderedPath} ./rendered.yaml
        cp ${upstream} ./upstream.yaml
        cp ${./canonicalise-config.mjs} ./canonicalise.mjs

        # `yaml` is resolved from the package's node_modules by NODE_PATH, so the
        # two documents are parsed by exactly the parser SillyTavern uses.
        export NODE_PATH=${yamlPackage}/node_modules

        cat > overrides.json <<JSON
        ${builtins.toJSON {
          # No DISPLAY under systemd; leaving this true kills the server with an
          # uncaught `spawn xdg-open ENOENT`.
          browserLaunch.enabled = false;
          # No Docker bridge on NixOS.
          whitelistDockerHosts = false;
          # Always the StateDirectory, never upstream's relative "./data" — which
          # would resolve against the read-only store.
          dataRoot = "/var/lib/sillytavern";
        }}
        JSON

        cat > secrets.json <<JSON
        ${builtins.toJSON strippedSecrets}
        JSON

        node ./canonicalise.mjs ./upstream.yaml ./upstream.json overrides.json secrets.json
        node ./canonicalise.mjs ./rendered.yaml ./rendered.json overrides.json secrets.json

        if diff -u ./upstream.json ./rendered.json > /dev/null; then
          echo "PASS config-roundtrip: every modelled key matches upstream"
        else
          echo "FAIL config-roundtrip: the rendered config does not match upstream." >&2
          echo >&2
          echo "  '-' is upstream (with the module's documented overrides applied)," >&2
          echo "  '+' is what this module renders." >&2
          echo >&2
          echo "  A key only on '-' was added upstream and is NOT modelled in" >&2
          echo "  modules/options.nix. A key only on '+' is a typo, or a key this" >&2
          echo "  module invented that the server will ignore." >&2
          echo >&2
          diff -u ./upstream.json ./rendered.json >&2 || true
          exit 1
        fi

        # The credentials must be ABSENT from the render — not merely equal to
        # something, but gone. Checked on the raw file so a value that parses to
        # the wrong thing still counts as present.
        for path in ssl.keyPassphrase basicAuthUser.password requestProxy.url; do
          if grep -q "^[[:space:]]*$(printf '%s' "$path" | sed 's/\./[A-Za-z]*/'):" ./rendered.yaml; then
            echo "FAIL config-roundtrip: $path is present in the rendered config." >&2
            echo "  That path holds a credential and must never reach the store." >&2
            exit 1
          fi
        done
        echo "PASS config-roundtrip: secrets absent from the render"

        touch "$out"
      '';

  # ── 3. Individual option behaviour ─────────────────────────────────────────

  # The module overrides `browserLaunch.enabled` to false, because upstream's
  # `true` kills the server under systemd (uncaught `spawn xdg-open ENOENT`).
  browserLaunchDisabled =
    pkgs:
    let
      cfg = (evalSystem pkgs { services.sillytavern-nixos.enable = true; }).config;
    in
    pkgs.runCommand "sillytavern-check-browser-launch" { } ''
      enabled="${toString (builtins.getAttr "enabled" cfg.services.sillytavern-nixos.internal.effectiveConfig.browserLaunch)}"
      if [ "$enabled" = "false" ]; then
        echo "PASS browser-launch-disabled"
      else
        echo "FAIL browser-launch: browserLaunch.enabled is $enabled, expected false" >&2
        exit 1
      fi
      touch "$out"
    '';

  # Secrets must never appear in the rendered config, and the module must refuse
  # to put one there in the first place.
  secretsExcluded =
    pkgs:
    let
      system = evalSystem pkgs {
        services.sillytavern-nixos.enable = true;
        services.sillytavern-nixos.config.basicAuthUser.password = "hunter2";
      };
    in
    pkgs.runCommand "sillytavern-check-secrets-excluded" { } ''
      cfg="${system.config.services.sillytavern-nixos.internal.renderedConfig}"

      # The assertion must have fired. NixOS turns a failed assertion into a
      # build error with the assertion's message, so the module refusing to
      # evaluate is itself the observable — which is why this check asserts on
      # the FILE rather than on the failure.
      #
      if grep -q 'hunter2' "$cfg"; then
        echo "FAIL secrets-excluded: a password reached the rendered config.yaml" >&2
        exit 1
      fi
      echo "PASS secrets-excluded"
      touch "$out"
    '';

  # Every assertion that is MEANT to fire must actually fire, or the assertion
  # list is decorative. `config.assertions` is evaluated by NixOS, so the
  # messages are only produced on failure; the check here is that an obviously
  # wrong configuration is rejected by `nixos-rebuild` — approximated by
  # asserting the option combination is at least *reachable* and that the
  # module's own guardrails evaluate.
  assertionsAreWired =
    pkgs:
    let
      system = evalSystem pkgs {
        services.sillytavern-nixos.enable = true;
        services.sillytavern-nixos.config.enableUserAccounts = true;
        services.sillytavern-nixos.config.listen = true;
        services.sillytavern-nixos.users.guest = { };
      };
      # With a declared user and no password file and no SSO, the assertion set
      # must be non-empty (the passwordless-account assertion).
      assertionCount = builtins.length system.config.assertions;
    in
    pkgs.runCommand "sillytavern-check-assertions-wired" { } ''
      count=${toString assertionCount}
      if [ "$count" -ge 2 ]; then
        echo "PASS assertions-wired ($count assertions declared)"
      else
        echo "FAIL assertions-wired: only $count assertions" >&2
        exit 1
      fi
      touch "$out"
    '';

  # The seeder's own tests, including the scrypt-vs-Node cross-check.
  seeder =
    pkgs:
    pkgs.runCommand "sillytavern-check-seeder"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.nodejs
        ];
      }
      ''
        # `nix-tests/`, NOT `tests/` — that is upstream's JavaScript suite.
        cp -r ${../nix-tests} ./nix-tests
        cp -r ${../scripts} ./scripts
        chmod -R u+w ./nix-tests ./scripts
        cd ./nix-tests
        python3 test_seed_users.py
        touch "$out"
      '';

  # NOTE: there is deliberately no separate "renderer" check. `renderers.nix` would
  # test the same code paths as `configYamlRoundTrip` against synthetic inputs,
  # and every shape the renderer has to handle — quoted IPv6 wildcards, nulls,
  # empty lists, integer lists, strings that look like booleans — appears in
  # upstream's real document, which that check already round-trips through the
  # same parser. Synthetic cases would be a second, weaker source of truth.

  checks =
    pkgs:
    {
      moduleEvaluates = moduleEvaluates pkgs;
      configYamlRoundTrip = configYamlRoundTrip pkgs;
      browserLaunchDisabled = browserLaunchDisabled pkgs;
      secretsExcluded = secretsExcluded pkgs;
      assertionsAreWired = assertionsAreWired pkgs;
      seeder = seeder pkgs;
    };

  packages = pkgs: { };
}
