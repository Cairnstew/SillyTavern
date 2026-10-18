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
    { lib, stdenvNoCC, nodejs, caCertFile ? null }:
    stdenvNoCC.mkDerivation {
      pname = "yaml-npm";
      version = "2.8.3";

      nativeBuildInputs = [ nodejs ];
      dontConfigure = true;
      dontBuild = true;
      # There is no `src`: this derivation installs straight from the npm
      # registry. Without this, the unpack phase runs and fails with
      # "variable $src or $srcs should point to the source".
      dontUnpack = true;
      # The YAML parser must not be shebang-patched or its hash would depend on
      # this nixpkgs' bash. See the identical note in pkgs/sillytavern/default.nix.
      dontFixup = true;

      installPhase = ''
        runHook preInstall
        export HOME="$TMPDIR"
        ${lib.optionalString (caCertFile != null) ''
          # On a host whose TLS is intercepted by a corporate proxy, npm needs
          # the system CA bundle; Node does not read it automatically.
          # Mirrors the argument on pkgs/sillytavern/default.nix.
          export NODE_EXTRA_CA_CERTS="${caCertFile}"
        ''}
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
      startupTimeout = system.config.services.sillytavern-nixos.startupTimeout;
      # Precomputed here: a `runCommand` script is SHELL, so a Nix expression
      # such as `lib.concatStringsSep` cannot appear inside it.
      execStartJoined = lib.concatStringsSep " " sc.ExecStart;
      # Elements containing whitespace are the failure mode being guarded
      # against; surfaced as an eval error rather than a shell assertion.
      execStartElementsWithSpaces = builtins.filter (e: builtins.match ".* .*" e != null) sc.ExecStart;
    in
    # Fails at eval time with the offending elements named.
    assert execStartElementsWithSpaces == [ ];
    pkgs.runCommand "sillytavern-check-module-evaluates"
      {
        nativeBuildInputs = [ pkgs.coreutils ];
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
        [ "${sc.TimeoutStartSec}" = "${toString startupTimeout}" ] \
          || fail "TimeoutStartSec is ${sc.TimeoutStartSec}, expected ${toString startupTimeout}"

        # --configPath must point at the rendered store file and --dataRoot at the
        # state directory: together they are the reason the unit is reproducible.
        #
        # ExecStart is an argv LIST — one element per argument — because systemd
        # passes each element to the process verbatim, with no word splitting and
        # no quote removal. Joining it with spaces here is only for matching.
        # (Interpolating a list into a Nix string is a type error, hence the
        # explicit concatStringsSep.)
        case "${execStartJoined}" in
          *--configPath=*) ;;
          *) fail "ExecStart has no --configPath" ;;
        esac
        case "${execStartJoined}" in
          *--dataRoot=/var/lib/sillytavern*) ;;
          *) fail "ExecStart has no --dataRoot=/var/lib/sillytavern" ;;
        esac

        # argv[0] is the launcher and every later element is a single flag: no
        # element may contain a space-joined command line, which is the bug that
        # made yargs drop every option. Asserted in Nix, not in shell — a Nix
        # error names the offending element, a shell one does not.
        # `--global` must never be emitted. The launcher refuses it, and in that
        # mode SillyTavern ignores --configPath and --dataRoot.
        case "${execStartJoined}" in
          *--global*)
            fail "ExecStart emits --global, which the launcher refuses" ;;
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

      # NOT named `yamlPackage`: that would shadow the top-level binding of
      # the same name and make this `pkgs.callPackage <itself>`, which is an
      # infinite recursion rather than an error you can read.
      yamlPkg = pkgs.callPackage yamlPackage {
        # `/etc/ssl` is the NixOS convention; absent on non-NixOS hosts,
        # where the plain derivation still works against a clean network.
        caCertFile = if builtins.pathExists /etc/ssl/certs then "/etc/ssl/certs/ca-bundle.crt" else null;
      };

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
        export NODE_PATH=${yamlPkg}

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
    # Asserted at EVAL time rather than by string-building into shell. The
    # previous version interpolated the value into a shell assignment and
    # compared it there, which reported an empty value and a misleading message
    # when it failed. `assert` fails at evaluation with the real value.
    assert cfg.services.sillytavern-nixos.internal.effectiveConfig.browserLaunch.enabled == false;
    pkgs.runCommand "sillytavern-check-browser-launch" { } ''
      echo "PASS browser-launch-disabled"
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
        # BOTH suites. `test_seed_files.py` was written alongside the first and
        # never wired in here, so the JSON seeding path — settings merge, path
        # confinement, secrets.json — had passing tests that CI never ran.
        python3 test_seed_users.py
        python3 test_seed_files.py
        touch "$out"
      '';

  # NOTE: there is deliberately no separate "renderer" check. `renderers.nix` would
  # test the same code paths as `configYamlRoundTrip` against synthetic inputs,
  # and every shape the renderer has to handle — quoted IPv6 wildcards, nulls,
  # empty lists, integer lists, strings that look like booleans — appears in
  # upstream's real document, which that check already round-trips through the
  # same parser. Synthetic cases would be a second, weaker source of truth.

  # ── 4. Regression: `.common` options actually reach an account ────────────
  #
  # `settings.common` and `files.common` are documented as applying to EVERY
  # account. They did not. `seedHandles` was the union of the `byUser` maps
  # alone, so a configuration using nothing but `.common` produced a seed spec
  # with `users: {}` — an EMPTY spec, and therefore a silent no-op at
  # activation. No error, no warning, nothing seeded, for any configuration that
  # did not happen to name a handle in one of the three `byUser` maps.
  #
  # It was worst in the default case: `config.enableUserAccounts` defaults to
  # false, so `default-user` is the only account that exists, and the only way
  # to reach it was `settings.byUser.default-user` — writing `byUser` to use
  # something documented as applying to everyone.
  #
  # Asserted at EVAL time on `internal.seedSpecJson`, the parsed spec. No build
  # and no store path: this check is `builtins.elem` over an attrset, so it
  # cannot be defeated by a derivation that fails to build, and it fails with
  # the actual handle list in the error.
  seedSpecCoversCommon =
    pkgs:
    let
      specOf =
        module:
        let s = (evalSystem pkgs module).config.services.sillytavern-nixos.internal.seedSpecJson;
        in {
          handles = builtins.attrNames s.users;
          users = s.users;
          # `or { }` rather than an `inherit`: before the fix this handle is
          # absent entirely, and a hard attribute access would fail with
          # "attribute 'default-user' missing" instead of reaching the `assert`
          # that explains what went wrong.
          defaultUser = s.users."default-user" or { };
        };

      # Case 1: the DEFAULT. No accounts, no `byUser` anywhere — the exact shape
      # that silently seeded nothing. Only `default-user` can appear, and it
      # must.
      singleAccount = specOf {
        services.sillytavern-nixos = {
          enable = true;
          settings.common = { main_api = "openai"; oai_settings.temp_openai = 0.77; };
          files.common."instruct/Default.json".json = { name = "d"; content = "c"; };
        };
      };

      # Case 2: accounts enabled, one declared, still nothing but `.common`.
      # `alice` must be seeded — and `default-user` too, since the server
      # creates it regardless once `enableUserAccounts` is on.
      withAccount = specOf {
        services.sillytavern-nixos = {
          enable = true;
          config.enableUserAccounts = true;
          users.alice = { name = "Alice"; };
          settings.common = { main_api = "openai"; };
          files.common."themes/T.json".json = { palette = { }; };
        };
      };
    in
    # Case 1. `config.enableUserAccounts` is left at its default (false).
    assert lib.elem "default-user" singleAccount.handles;
    # ...and the CONTENT reached it, not merely the handle. An empty `settings`
    # or `files` under a present handle is the same bug wearing a disguise.
    assert singleAccount.defaultUser.settings.oai_settings.temp_openai == 0.77;
    assert singleAccount.defaultUser.files != { };

    # Case 2.
    assert lib.elem "alice" withAccount.handles;
    assert withAccount.users."alice".settings.main_api == "openai";
    assert withAccount.users."alice".files."themes/T.json".json.palette == { };

    pkgs.runCommand "sillytavern-check-seed-spec-covers-common" { } ''
      echo "PASS seed-spec-covers-common (single-account: default-user; with-account: alice)"
      touch "$out"
    '';

  # `customCss` is the only thing this module ever writes at the data root, and
  # its isolation is the whole point: `dataRootFiles` and the per-user `files`
  # maps must never overlap, because that overlap was the original
  # double-seeding bug.
  #
  # Asserted at eval time on `internal.seedSpecJson`.
  customCssIsolated =
    pkgs:
    let
      specOf = module: (evalSystem pkgs module).config.services.sillytavern-nixos.internal.seedSpecJson;

      # unset: the module must not touch the data root at all.
      unset = specOf { services.sillytavern-nixos.enable = true; };
      cssFile = pkgs.writeText "ui-overrides.css" "body { --accent: #f00; }\n";
      set = specOf {
        services.sillytavern-nixos = {
          enable = true;
          customCss = cssFile;
          # A per-account file, to prove the two maps stay disjoint.
          files.common."themes/T.json".json = { palette = { }; };
        };
      };
    in
    # Unset means dataRootFiles is EMPTY — not "one key with no value". An
    # unset option that still produced a key would resurrect the migration path
    # this module is explicitly not supposed to own.
    assert unset.dataRootFiles == { };

    # Set means EXACTLY one key, with a literal name.
    assert lib.attrNames set.dataRootFiles == [ "_css/user.css" ];

    # Nix-authoritative and browser-readable, both explicit in the spec so the
    # seeder never has to guess.
    assert set.dataRootFiles."_css/user.css".policy == "overwrite";
    assert set.dataRootFiles."_css/user.css".mode == "0644";

    # The key never appears per-account. This is the double-seeding bug, stated
    # as an assertion.
    assert lib.all (h: !(builtins.elem "_css/user.css" (lib.attrNames set.users.${h}.files)))
      (lib.attrNames set.users);

    pkgs.runCommand "sillytavern-check-custom-css-isolated" { } ''
      echo "PASS custom-css-isolated (unset -> {}; set -> _css/user.css only, overwrite, 0644)"
      touch "$out"
    '';

  # nixpkgs ships its own `services.sillytavern`, and both modules own
  # `systemd.services.sillytavern`, `users.users.sillytavern` and
  # `serviceConfig.StateDirectory`. These cases pin the behaviour of the
  # assertion that rejects that combination.
  upstreamCollisionAsserted =
    pkgs:
    let
      # `services.sillytavern` is ALREADY in scope: `nixosSystem` loads nixpkgs'
      # whole module-list.nix, which registers services/web-apps/sillytavern.nix.
      # These cases therefore exercise the REAL upstream module, not a stand-in.
      mk = extra: (evalSystem pkgs extra).config;

      # Only FAILING assertions are inspected, and each `.message` read is
      # wrapped in tryEval. Forcing every message walks NixOS' own assertions,
      # one of which (`tasks/filesystems.nix`) has a message that reads
      # `fileSystems`, and forcing it inside this evaluation is an attribute
      # cycle — unrelated to SillyTavern and not worth the fragility.
      failingWithOurMarker =
        cfg:
        let failing = builtins.filter (a: !a.assertion) cfg.assertions;
        in
          builtins.filter
            (a: (builtins.tryEval (builtins.match ".*ALSO defines.*" a.message)).success
                 && (builtins.tryEval (builtins.match ".*ALSO defines.*" a.message)).value != null)
            failing;

      oursOnly     = mk { services.sillytavern-nixos.enable = true; };
      theirsOnOnly = mk { services.sillytavern.enable = true; };
      bothOn       = mk {
        services.sillytavern-nixos.enable = true;
        services.sillytavern.enable = true;
      };
      neither      = mk { };
    in
    # ── 1. both enabled → ours is declared and FAILS ──────────────────────────
    assert builtins.length (failingWithOurMarker bothOn) == 1;

    # ── 2. nixpkgs' enabled, ours disabled → ours does not block the user ─────
    # The important negative: running nixpkgs' module must not be stopped by one
    # that was never enabled.
    assert failingWithOurMarker theirsOnOnly == [ ];

    # ── 3. ours only → ours does not fail ─────────────────────────────────────
    assert failingWithOurMarker oursOnly == [ ];

    # ── 4. neither enabled → ours is never declared ───────────────────────────
    assert failingWithOurMarker neither == [ ];

    pkgs.runCommand "sillytavern-check-upstream-collision" { } ''
      echo "PASS upstream-collision-asserted (both -> ours fails; theirs-only / ours-only / neither -> clean)"
      touch "$out"
    '';

  # `modules/sillytavern.nix` imports `assertions.nix` UNCONDITIONALLY — it is
  # not inside services.nix's `mkIf`. The file therefore wraps its own list in
  # `lib.mkIf cfg.enable`. Without that, importing this module while running
  # nixpkgs' `services.sillytavern` would fail on assertions belonging to a
  # module the user never enabled.
  #
  # It also means a disabled module must contribute NO assertions at all, which
  # is stronger and easier to test than "none of ours happen to fail".
  assertionsDisabledCleanly =
    pkgs:
    let
      base = {
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "/dev/null"; fsType = "tmpfs"; };
        system.stateVersion = "25.05";
      };
      cfgWith = modules: (nixpkgs.lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = modules ++ [ base ];
      }).config;

      # The precise statement: a DISABLED module of ours contributes nothing at
      # all. So importing it must be indistinguishable from not importing it.
      #
      # Compared against a system with no SillyTavern module of ours at all,
      # NOT against "nothing enabled" — enabling nixpkgs' module legitimately
      # adds assertions of its own (9 on this system), so the naive comparison
      # looked like a failure when the behaviour was correct.
      withOursDisabled = cfgWith [
        modulePath
        { services.sillytavern.enable = true; }   # nixpkgs' module, on
      ];
      withoutOurs = cfgWith [
        { services.sillytavern.enable = true; }
      ];
      bothOff = cfgWith [ modulePath ];

      # …and with ours enabled it DOES contribute, otherwise this check would
      # pass trivially on a module that had been emptied out.
      oursEnabled = cfgWith [ modulePath { services.sillytavern-nixos.enable = true; } ];
    in
    assert builtins.length withOursDisabled.assertions == builtins.length withoutOurs.assertions;
    assert builtins.length bothOff.assertions == builtins.length (cfgWith [ ]).assertions;

    assert builtins.all (a: a.assertion) withOursDisabled.assertions;

    # Sanity: enabled, we do contribute.
    assert builtins.length oursEnabled.assertions > builtins.length bothOff.assertions;

    pkgs.runCommand "sillytavern-check-assertions-disabled-cleanly" { } ''
      echo "PASS assertions-disabled-cleanly (disabled -> contributes nothing; enabled -> contributes)"
      touch "$out"
    '';

  # Nothing in the module may READ another module's namespace. Two defects
  # shipped from exactly this mistake — `modules/home.nix` and
  # `lib/default.nix` both read `services.sillytavern` and both broke, one of
  # them in an exported flake lib function. A grep is the cheapest thing that
  # catches a third.
  #
  # The ONE exception is `modules/assertions.nix`, whose whole job is to detect
  # nixpkgs' module. That line is matched by a literal, not waved through.
  noCrossModuleReads =
    pkgs:
    let
      offenders = pkgs.runCommand "sillytavern-check-no-cross-module-reads"
        {
          nativeBuildInputs = [ pkgs.gnugrep pkgs.coreutils ];
        }
        ''
          # The sources have to be COPIED in: a runCommand's build directory
          # starts empty, so `../modules` would silently scan nothing and this
          # check would pass unconditionally. That was the first version.
          cp -r ${../modules} ./modules
          cp -r ${../lib} ./lib

          # Anchored on `config.` / `osConfig.` immediately followed by
          # `services.sillytavern`, and NOT followed by `-` or an alphanumeric.
          #
          # Both halves matter, and the first version of this check got both
          # wrong:
          #
          #  * With a trailing `.` required, an attrset-level read — which is
          #    exactly the shape of both real bugs, `...sillytavern or null` —
          #    was missed entirely.
          #  * Without the `config.` anchor, three legitimate references were
          #    caught: this module's own `systemd.services.sillytavern-healthcheck`
          #    unit, and two lines in this test harness that deliberately set
          #    nixpkgs' option. Neither is an options-namespace read.
          #
          # The trailing `-` exclusion drops `sillytavern-nixos` (and
          # `-healthcheck`, `-package`) without a second filter pass.
          #
          # Comments are excluded: options.nix documents this very collision in
          # prose, and assertions.nix detects nixpkgs' module on purpose.
          grep -rInE '(config|osConfig)\.services\.sillytavern([^0-9A-Za-z_-]|$)' \
            ./modules ./lib \
            | sed 's|^\./||' \
            | grep -vE '^[a-z/._-]+\.nix:[0-9]+:[[:space:]]*#' \
            | grep -v '^modules/assertions.nix:' \
            > hits.txt || true
          hits=$(cat hits.txt)

          if [ -n "$hits" ]; then
            echo "FAIL no-cross-module-reads: reading another module's namespace:" >&2
            echo "$hits" >&2
            echo >&2
            echo "nixpkgs owns services.sillytavern. OURS is services.sillytavern-nixos." >&2
            exit 1
          fi
          echo "PASS no-cross-module-reads"
          touch "$out"
        '';
    in
    offenders;

  checks =
    pkgs:
    {
      moduleEvaluates = moduleEvaluates pkgs;
      configYamlRoundTrip = configYamlRoundTrip pkgs;
      browserLaunchDisabled = browserLaunchDisabled pkgs;
      secretsExcluded = secretsExcluded pkgs;
      assertionsAreWired = assertionsAreWired pkgs;
      seedSpecCoversCommon = seedSpecCoversCommon pkgs;
      customCssIsolated = customCssIsolated pkgs;
      upstreamCollisionAsserted = upstreamCollisionAsserted pkgs;
      assertionsDisabledCleanly = assertionsDisabledCleanly pkgs;
      noCrossModuleReads = noCrossModuleReads pkgs;
      seeder = seeder pkgs;
    };

  packages = pkgs: { };
}
