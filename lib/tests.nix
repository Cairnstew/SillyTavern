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
      # Derived with `caCertFile` pointed at `pkgs.cacert` (the store path),
      # not a host path — the sandbox cannot see `/etc/ssl/certs`.
      outputHash = "sha256-qe7ek9Yd6879sP3spf0ZYCbpf5ZcTLe3UyvMm5n5qOs=";
    };

in
rec {
  # Every `assertion` a system contributes, evaluated SAFELY.
  #
  # Reading `a.assertion` can THROW rather than return false. A mis-built
  # assertion — one whose predicate has the wrong arity, say — is a hard
  # evaluation error, not a failed assertion, and NixOS hits it on every
  # rebuild: `lib.asserts.checkAssertWarn` does
  # `filter (x: !x.assertion) assertions`, which forces every single one.
  #
  # So each `assertion` is wrapped in its OWN `builtins.tryEval` here, which
  # turns "this throws" back into an observable value instead of taking the
  # whole check down. `allBooleans` is what catches that class of bug: it was
  # false for the `builtins.all`-with-a-curried-predicate assertion, and only
  # once a plugin or extension was declared — no other configuration reached
  # it.
  #
  # Messages get their own tryEval for a different reason: forcing every
  # message in a full NixOS system walks unrelated assertions, and
  # `tasks/filesystems.nix` reads `fileSystems`, which can walk into an
  # attribute cycle.
  inspectedAssertions =
    cfg:
    let
      one =
        a:
        let
          value = builtins.tryEval (a.assertion or false);
          text = builtins.tryEval (builtins.match ".*services\\.sillytavern-nixos:.*" (a.message or ""));
        in
        {
          # Did evaluating `assertion` succeed at all, and to a boolean?
          ok = value.success && builtins.isBool value.value;
          passed = value.success && value.value == true;
          message = if text.success && text.value != null then (a.message or "") else null;
        };
      evaluated = builtins.map one cfg.assertions;
    in
    {
      allBooleans = builtins.all (e: e.ok) evaluated;
      # Only OUR failing assertions, so an unrelated NixOS assertion cannot make
      # this look like a defect in this module.
      ourFailures = builtins.filter (e: !e.passed && e.message != null) evaluated;
      failing = builtins.filter (e: !e.passed) evaluated;
    };

  # OUR failing assertion messages matching `pattern`. Narrower than
  # `ourFailures`, so a check can assert about one subject without having to
  # know what else a minimal system happens to complain about (a bare
  # `enable = true` deliberately fails the "no authentication configured"
  # assertion).
  ourFailuresMatching =
    cfg: pattern:
    builtins.filter (e: builtins.match pattern e.message != null) (inspectedAssertions cfg).ourFailures;

  # A Nix system with the module imported and the module's options available.
  # The bootstrap every eval check starts from, shared so a check can put
  # EITHER module in scope. The two services are deliberately independent
  # (they do not read each other's options), so the harness must be able to
  # evaluate one without the other.
  evalWith =
    pkgs: modules:
    nixpkgs.lib.nixosSystem {
      # `pkgs.stdenv.hostPlatform.system` rather than `pkgs.system`, which is
      # deprecated and emits an evaluation warning that would drown out real
      # output on every `nix flake check`.
      system = pkgs.stdenv.hostPlatform.system;
      modules = modules ++ [
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

  evalSystem = pkgs: module: evalWith pkgs [ module modulePath ];
  evalLlama = pkgs: module: evalWith pkgs [ module ../modules/llama.nix ];

  # ── 0. The module, the overlay and the flake agree on ONE package ───────────
  #
  # The invariant: the package the module RUNS is the package the overlay
  # exposes as `pkgs.sillytavern`, and both are built from the FILTERED
  # source.
  #
  # It is easy to state and easy to break, because the four places that build
  # this package (the flake's `packages` output, the flake's overlay, the
  # module's default `package`, and the non-flake `default.nix`) each spelled
  # out the source themselves. Two of them used the UNFILTERED tree, and the
  # consequences were observable from outside:
  #
  #   * `pkgs.sillytavern` and "what the module runs" were DIFFERENT store
  #     paths, so applying the overlay built the same software twice and
  #     `pkgs.sillytavern` did not mean "the package the module runs";
  #   * the module's package hash changed whenever a stray `node_modules`
  #     appeared in the source tree, so a `path:` flake input pointing at a
  #     developer's working copy was not reproducible;
  #   * the unfiltered tree was copied into the store as the build input.
  #
  # So this check is worth its weight: it is a consumer-visible property, and
  # nothing else in the suite would notice its loss.
  packageIdentity =
    pkgs:
    let
      # The module's default package, with the module imported the way a
      # consumer imports it — no explicit `package`, so the module's own
      # `mkDefault` is what supplies it.
      system = evalSystem pkgs { services.sillytavern-nixos.enable = true; };
      modulePackage = system.config.services.sillytavern-nixos.package;

      # The same package as the overlay exposes it. `overlay.nix` is applied
      # to the SAME package set the module sees, which is what a consumer
      # who writes `nixpkgs.overlays = [ … ]` gets.
      overlayPackage = (pkgs.extend (import ../overlay.nix)).sillytavern;

      # The filtered source, computed exactly as `lib/source.nix` does. The
      # module and the overlay must BOTH be building from this.
      filteredSource = import ../lib/source.nix { inherit lib; } ../.;
    in
    # The module's package and the overlay's package are the SAME derivation.
    assert modulePackage.outPath == overlayPackage.outPath;
    # Both are built from the FILTERED source, not the raw tree. The raw tree
    # is a different store path from the filtered one whenever the checkout
    # carries anything the filter drops — which is exactly the case this
    # check exists to catch, so it cannot be asserted by comparing two
    # filtered paths. What can be asserted is that neither package's source
    # is the unfiltered repository root.
    #
    # `passthru.source`, not `src`: `src` is a function ARGUMENT of the
    # package function, so it is not an attribute of the built derivation.
    # `passthru.source` is the resolved value of that argument.
    assert modulePackage.source.outPath == filteredSource.outPath;
    assert overlayPackage.source.outPath == filteredSource.outPath;
    pkgs.runCommand "sillytavern-check-package-identity" { }
      ''
        echo "PASS package-identity (module, overlay and flake share one package)"
        touch "$out"
      '';

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
      # The RENDERED unit, not `serviceConfig`. Reading `serviceConfig` is what
      # let a broken unit pass every check for so long: it holds whatever NixOS
      # was handed, and the transformation into the unit file is where the bug
      # was. `systemd.units.<name>.text` is the exact file systemd reads.
      unitText = system.config.systemd.units."sillytavern.service".text;
      unitLines = lib.splitString "\n" unitText;
      # `ExecStart=` EXACTLY — `hasPrefix` would also match `ExecStartPre=` and
      # `ExecStartPost=`, which are different directives that legitimately occur
      # more than once.
      execStartLines = builtins.filter (l: lib.hasPrefix "ExecStart=" l) unitLines;
      execStartCount = builtins.length execStartLines;
      # Precomputed here: a `runCommand` script is SHELL, so a Nix expression
      # such as `lib.concatStringsSep` cannot appear inside it. The unit text is
      # NOT interpolated wholesale — it carries `$` and `%` specifiers that a
      # double-quoted shell context would expand.
      execStartJoined = lib.concatStringsSep " " execStartLines;
      unitSetsMemoryDenyWriteExecute = builtins.any (
        l: lib.hasPrefix "MemoryDenyWriteExecute=" l
      ) unitLines;
    in
    pkgs.runCommand "sillytavern-check-module-evaluates"
      {
        nativeBuildInputs = [ pkgs.coreutils ];
      }
      ''
        fail() {
          echo "FAIL module-evaluates: $1" >&2
          exit 1
        }

        # EXACTLY ONE `ExecStart=` line, which is the whole point of this check.
        #
        # A NixOS `serviceConfig` value that is a LIST is rendered by
        # `attrsToSection` as ONE `Key=` LINE PER ELEMENT — several commands,
        # which is what `ExecStartPre=` is for. systemd then reads each extra
        # line as another executable and rejects it:
        #
        #   Neither a valid executable name nor an absolute path, ignoring: -configPath=…
        #
        # so the wrapper starts with no --configPath and no --dataRoot, the
        # server falls back to ./config.yaml, and it dies EROFS under
        # ProtectSystem=strict. Verified with `systemd-analyze verify`, which
        # reports exactly that line for the multi-line form and nothing for the
        # single-line one.
        [ "${toString execStartCount}" = "1" ] \
          || fail "expected exactly one ExecStart= line, got ${toString execStartCount}: ${execStartJoined}"

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

        # `MemoryDenyWriteExecute` must NOT be set: V8 allocates W+X pages for its
        # JIT, so the directive makes mprotect fail and the server aborts with
        # SIGTRAP at isolate init, restart-looping the unit. A consumer can still
        # turn it on through `systemdOverrides`, so assert on the rendered unit
        # rather than on the module source.
        [ "${if unitSetsMemoryDenyWriteExecute then "yes" else "no"}" = "no" ] \
          || fail "unit sets MemoryDenyWriteExecute, which crash-loops node/V8"

        # --configPath must point at the rendered store file and --dataRoot at the
        # state directory: together they are the reason the unit is reproducible.
        case "${execStartJoined}" in
          *--configPath=*) ;;
          *) fail "ExecStart has no --configPath" ;;
        esac
        case "${execStartJoined}" in
          *--dataRoot=/var/lib/sillytavern*) ;;
          *) fail "ExecStart has no --dataRoot=/var/lib/sillytavern" ;;
        esac

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
        # A STORE PATH, not a host path. The build sandbox cannot see
        # `/etc/ssl/certs/ca-bundle.crt` — it is not a declared dependency —
        # so `NODE_EXTRA_CA_CERTS` pointed at nothing and Node fell back to
        # its built-in CA, which lacks this network's issuer. `pkgs.cacert`
        # ships the identical bundle as a store path the sandbox can read.
        caCertFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
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

        # `yaml` has to be resolvable by ESM RESOLUTION, not by NODE_PATH.
        #
        # canonicalise-config.mjs is an ES module (`import YAML from "yaml"`), and
        # Node's ESM resolver ignores NODE_PATH entirely — it is a CommonJS-only
        # mechanism. `export NODE_PATH=${yamlPkg}`, which this check used to do,
        # therefore produced:
        #
        #   Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'yaml'
        #     imported from …/canonicalise.mjs
        #
        # on EVERY host, which is why the check had never been observed green
        # anywhere and why its documented failure mode was indistinguishable
        # from the TLS one. The fix is the mechanism ESM actually uses: a
        # `node_modules` directory beside the importing file.
        ln -s ${yamlPkg} ./node_modules

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

          # DELIBERATE divergence, not a typo: upstream writes these as YAML
          # booleans, this module writes them as strings.
          #
          # `protocol.ipv4` / `.ipv6` accept a string-or-bool hybrid upstream —
          # "auto" has no boolean equivalent — so the OPTION is
          # `types.enum [ "true" "false" "auto" … ]` and the default is the
          # STRING "true". The rendered `"true"` is therefore not the same JSON
          # type as upstream's `true`, and this byte-exact comparison saw that
          # as a diff.
          #
          # It is functionally identical: src/command-line.js:307-308 reads both
          # through `stringToBool`, which maps "true" → true and "false" → false.
          # Recorded here so the round trip stays exact everywhere else.
          protocol.ipv4 = "true";
          protocol.ipv6 = "false";
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

  # ── The package must ship the directories the server mkdirSync's into ──────
  #
  # `ensurePublicDirectoriesExist` (src/users.js:113-118) walks
  # PUBLIC_DIRECTORIES and, for each entry that is MISSING, calls
  # `fs.mkdirSync(dir, { recursive: true })`. Those paths are relative, and
  # `server.js:11` does `process.chdir(serverDirectory)` — so they resolve
  # INSIDE the read-only store path.
  #
  # The function has no try/catch, and the startup chain that calls it
  # (src/server-main.js:480-490) is a `.then()` chain with no `.catch()`. So a
  # missing directory is an UNCAUGHT exception that kills the process before it
  # ever listens. Reproduced by removing one from a copy of the package:
  #
  #   Error: EACCES: permission denied, mkdir 'public/img/'
  #       at ensurePublicDirectoriesExist (src/users.js:116:16)
  #   exit=1        <- never reached "listening"
  #
  # All five exist today, so this is a latent failure — but nothing was watching
  # for it. A future upstream drop that renames `public/sounds`, or a packaging
  # change that stops creating `backups/`, turns the service into a crash loop
  # that `nix flake check` passes clean, because every other check is
  # evaluation-time and none of them looked at the package's contents.
  #
  # This is the one check that reads the built package, which is also why it
  # needs `packages.default` to exist (flake.nix) — without it `nix flake check`
  # never realised this derivation at all.
  publicDirectoriesPresent =
    pkgs:
    let
      # The package the module would ACTUALLY run — taken from the module's own
      # resolved `package` option rather than `callPackage`d here, so this
      # cannot drift from what gets deployed, and so it inherits the `src` that
      # `modules/sillytavern.nix` supplies with `mkDefault`.
      package = (evalSystem pkgs { services.sillytavern-nixos.enable = true; }).config.services.sillytavern-nixos.package;

      # PUBLIC_DIRECTORIES from src/constants.js:1-7, all relative to the
      # server directory.
      required = [
        "public/img"
        "backups"
        "public/sounds"
        "public/scripts/extensions"
        "public/scripts/extensions/third-party"
      ];
    in
    pkgs.runCommand "sillytavern-check-public-directories" { } ''
      fail=0
      for dir in ${lib.concatStringsSep " " (map (d: "\"${d}\"") required)}; do
        if [ -d "${package}/''${dir}" ]; then
          echo "PASS public-directories-present  $dir"
        else
          echo "FAIL public-directories-present  $dir"
          echo "     src/users.js:116 would mkdirSync this into a read-only store"
          echo "     path and throw uncaught; the server would never listen."
          fail=1
        fi
      done

      if [ "$fail" -ne 0 ]; then
        echo ""
        echo "A directory PUBLIC_DIRECTORIES expects is absent from the package."
        echo "Check pkgs/sillytavern/filter.nix (it drops node_modules, dist"
        echo "and result) and the mkdir -p list in pkgs/sillytavern/default.nix."
        exit 1
      fi

      touch "$out"
      echo "PASS public-directories-present (${toString (builtins.length required)} directories)"
    '';
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
  # The application source, as the package sees it, so the staged `repo/src` is
  # the same tree the tests would read in a checkout.
  repoSrc = lib.cleanSourceWith {
    src = ../src;
    name = "sillytavern-src";
    filter = name: type:
      let base = baseNameOf (toString name);
      in !(builtins.elem base [ "node_modules" "dist" ]);
  };

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

        # `test_seed_files.py` now reads the error-page allowlist out of the
        # real sources instead of comparing two hardcoded copies of it, and
        # checks the Nix-side mirror of the deny-list stays in sync. Both need
        # files outside `nix-tests/` and `scripts/`.
        #
        # `src/` is the whole tree rather than the four files, because the test
        # greps it itself and a filtered copy would make it pass vacuously on a
        # near-empty directory. It is only read, and copied with the repo's own
        # source filter.
        mkdir -p ./repo/modules
        cp -r ${repoSrc} ./repo/src
        cp ${../modules/assertions.nix} ./repo/modules/assertions.nix
        chmod -R u+w ./nix-tests ./scripts ./repo
        cd ./nix-tests

        # The tests resolve the repo root by walking up from this file, which
        # inside the sandbox is ./repo (not the checkout). Set explicitly
        # rather than searched for, so a layout change fails loudly.
        export ST_REPO_ROOT="$PWD/../repo"
        # BOTH suites. `test_seed_files.py` was written alongside the first and
        # never wired in here, so the JSON seeding path — settings merge, path
        # confinement, secrets.json — had passing tests that CI never ran.
        python3 test_seed_users.py
        python3 test_seed_files.py
        # The model-cache linker, which decides what `<dataRoot>/_cache` is.
        # Its interesting behaviour is DATA LOSS if it breaks — an existing
        # cache of downloaded models must be moved aside, never deleted.
        python3 test_link_models.py
        touch "$out"
      '';

  # ── 6. Every guard actually FIRES ─────────────────────────────────────────
  #
  # This replaces a check that could not fail. It counted NIXOS'S OWN assertion
  # list (which is over 900 entries) and asserted the count was `>= 2`, so it
  # proved nothing about this module — measured, the floor for a module-less
  # system is around 904. Its comment claimed "every assertion that is MEANT to
  # fire must actually fire"; it tested none of them.
  #
  # What follows is a real reachability matrix. Each row is a configuration that
  # is SILENTLY WRONG, plus a substring that must appear in one of the failing
  # assertion messages. A row passes only if that specific guard fires, so a
  # guard that is deleted, renamed, or made unfalsifiable by an upstream change
  # turns its own row red rather than disappearing quietly.
  #
  # Substring, not exact message, on purpose: the messages are prose and should
  # stay editable. What must not drift is the SUBJECT of the guard.
  #
  # Each needle must fit on ONE line of the message. The messages are wrapped
  # prose, and a needle that spans a wrap ("names paths the seeder refuses" —
  # the file has a newline and indent after "seeder") can never match, so the
  # row fails for a reason that has nothing to do with the guard it is testing.
  #
  # `ourFailuresMatching` (above) already narrows to this module's assertions,
  # so an unrelated NixOS failure cannot accidentally satisfy a row.
  guardsFire =
    pkgs:
    let
      # Every row needs authentication set up, or the "no authentication"
      # guards fire for the wrong reason and every row would pass spuriously.
      # Authentication is set up on EVERY row. Without it the "no
      # authentication configured" guard fires on all of them, and a row that
      # only ever sees that message passes for the wrong reason — or, worse, the
      # row it was meant to test never gets to run.
      #
      # `enable = true` is load-bearing and easy to miss: modules/assertions.nix
      # wraps its entire list in `lib.mkIf cfg.enable`, so a row that forgets it
      # evaluates a system with NO guards at all and reports every one of them
      # dead. `evalSystem` does not enable the module either — that is the
      # consumer's job, and every other check that wants assertions says so.
      baseConfig = {
        enable = true;
        config.enableUserAccounts = true;
        users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
      };

      # `withConfig` MERGES into `config` rather than replacing it.
      #
      # The naive `auth // { config.ssl.keyPassphrase = …; }` is wrong in a way
      # that looks right: attrset `//` replaces, so the whole `config` subtree
      # is discarded — including `enableUserAccounts = true` — and every such
      # row silently ends up testing "users were declared but accounts are
      # disabled" instead. That is the same replace-vs-merge trap this project
      # just fixed in `systemdOverrides`, met again in its own test.
      withConfig =
        extra:
        # `extra` is applied in the middle so its non-`config` keys (`files.*`,
        # `users.*`, `proxyUpstreams`) actually land, and `config` is then forced
        # to the MERGE so the base's `enableUserAccounts = true` survives.
        #
        # Both orders are wrong in isolation, and both fail the same way: every
        # `files.*` row silently evaluates to a system with nothing to seed, so
        # the guard under test never fires and the row reports itself DEAD.
        baseConfig // extra // {
          config = baseConfig.config // (extra.config or { });
        };

      rows = [
        {
          name = "declared-users-without-accounts";
          module = {
            services.sillytavern-nixos = baseConfig // {
              config = baseConfig.config // { enableUserAccounts = false; };
            };
          };
          expect = "users were declared but";
        }
        {
          name = "no-authentication-at-all";
          # Built WITHOUT `baseConfig`, deliberately. Its guard reads
          # `cfg.config.enableUserAccounts || cfg.users != { }`, so any declared
          # account satisfies it — and `withConfig` always declares one. A
          # forgotten guard would look "ok" here for the wrong reason.
          module = {
            services.sillytavern-nixos = {
              enable = true;
              config = { listen = true; };
            };
          };
          expect = "no authentication is configured";
        }
        {
          name = "plaintext-ssl-passphrase";
          module = {
            services.sillytavern-nixos = withConfig {
              config.ssl.keyPassphrase = "hunter2";
            };
          };
          expect = "config.ssl.keyPassphrase is set";
        }
        {
          name = "plaintext-basic-auth-password";
          # BOTH halves, because the guard reads
          # `password == "password" || passwordFile == null`: a non-default
          # password with NO passwordFile is fine, because nothing renders it
          # anywhere. It is the pair — a secret set twice, once into the store —
          # that is refused.
          module = {
            services.sillytavern-nixos = withConfig {
              config.basicAuthUser.password = "hunter2";
              basicAuthUser.passwordFile = pkgs.writeText "pw" "hunter2";
            };
          };
          expect = "config.basicAuthUser.password is set";
        }
        {
          name = "files-entry-without-json-or-path";
          module = {
            services.sillytavern-nixos = withConfig {
              files.common."themes/x.json".json = null;
            };
          };
          expect = "must set exactly one";
        }
        {
          name = "secrets-json-through-files";
          module = {
            services.sillytavern-nixos = withConfig {
              files.common."secrets.json".json = { };
            };
          };
          expect = "do not seed `secrets.json` through";
        }
        {
          name = "seed-handle-not-declared";
          module = {
            services.sillytavern-nixos = withConfig {
              files.byUser.nobody."themes/x.json".json = { };
            };
          };
          expect = "every handle in";
        }
        {
          name = "reserved-path-in-files";
          module = {
            services.sillytavern-nixos = withConfig {
              files.common."backups/x.json".json = { };
            };
          };
          expect = "entries name paths the seeder";
        }
        {
          name = "bad-file-mode";
          module = {
            services.sillytavern-nixos = withConfig {
              files.common."themes/x.json" = { json = { }; mode = "644"; };
            };
          };
          expect = "entry `mode` must be a 4-digit";
        }
        {
          name = "host-whitelist-without-hosts";
          module = {
            services.sillytavern-nixos = withConfig {
              config.hostWhitelist.enabled = true;
              config.hostWhitelist.hosts = [ ];
            };
          };
          expect = "config.hostWhitelist.enabled is true but";
        }
        {
          name = "proxy-appends-forwarded-for";
          module = {
            services.sillytavern-nixos = withConfig {
              proxyUpstreams = [ { name = "st"; forwardedFor = "append"; } ];
            };
          };
          expect = "a proxyUpstream sets forwardedFor";
        }
        {
          name = "passwordless-account-without-sso";
          module = {
            services.sillytavern-nixos = {
              enable = true;
              config.enableUserAccounts = true;
              users.guest = { };
            };
          };
          expect = "a passwordless account with neither SSO";
        }
        {
          name = "settings-key-that-upstream-does-not-have";
          module = {
            services.sillytavern-nixos = withConfig {
              settings.common.power_user.font_scal = 1.2;
            };
          };
          expect = "not settings SillyTavern has";
        }
        {
          name = "settings-key-outside-the-clients-save-payload";
          module = {
            services.sillytavern-nixos = withConfig {
              settings.common.my_own_key = 1;
            };
          };
          expect = "the browser DISCARDS them";
        }
        {
          name = "data-root-outside-the-state-directory";
          module = {
            services.sillytavern-nixos = withConfig {
              dataRoot = "/var/lib/somewhere-else";
            };
          };
          # The parentheses are ESCAPED: the needle is used as a regular
          # expression, and an unescaped "(" is a group, so the pattern would
          # ask for a message with no parentheses in it — and match nothing.
          expect = "dataRoot \\(/var/lib/somewhere-else\\) is not";
        }
        {
          name = "model-id-that-is-not-a-path";
          module = {
            services.sillytavern-nixos = withConfig {
              models.byId."../escape" = pkgs.writeTextDir "config.json" "{}";
            };
          };
          expect = "is not a usable model id";
        }
        {
          name = "model-weights-outside-the-store";
          module = {
            services.sillytavern-nixos = withConfig {
              models.byId."Xenova/whisper-small" = "/var/lib/models/whisper-small";
            };
          };
          expect = "are not store paths";
        }
      ];

      # Self-contained rather than reusing `ourFailuresMatching`.
      #
      # Two things that helper does not do, and both are needed here:
      #   * it takes a CONFIG, not a system — easy to get backwards, and the
      #     resulting error names `attribute 'assertions' missing` on an
      #     attrset that visibly has one;
      #   * it returns every failing assertion, whereas this needs to ask
      #     "does ANY message match this needle", which is a different filter
      #     order and worth being able to read locally.
      #
      # `one` mirrors `inspectedAssertions`: BOTH `assertion` and `message` go
      # through `tryEval`, because forcing the message of an unrelated NixOS
      # assertion walks `fileSystems` and dies on `attribute 'cycle' missing`.
      firingMessages =
        row:
        let
          evaluated = builtins.map one (evalSystem pkgs row.module).config.assertions;
          one =
            a:
            let
              value = builtins.tryEval (a.assertion or false);
              text = builtins.tryEval (builtins.match ".*services\\.sillytavern-nixos:.*" (a.message or ""));
            in
            {
              passed = value.success && value.value == true;
              message = if text.success && text.value != null then (a.message or "") else null;
            };
        in
        builtins.map (e: e.message) (builtins.filter (e: !e.passed && e.message != null) evaluated);

      evaluate =
        row:
        builtins.filter (m: builtins.match ".*${row.expect}.*" m != null) (firingMessages row);

      # `name=hits` pairs, rendered into the shell script below.
      #
      # Reporting in SHELL rather than asserting in Nix is deliberate: a Nix
      # `assert` on this says only "a list is not empty", which is useless when
      # the failure is "the guard you were relying on cannot fire any more".
      # The script names every dead guard instead.
      results = builtins.map (row: {
        inherit (row) name;
        firing = builtins.length (firingMessages row);
        hits = builtins.length (evaluate row);
      }) rows;

      # The mirror image: a valid configuration must trip NONE of them, or the
      # matrix above would pass for the wrong reason.
      clean = builtins.length (
        firingMessages {
          module = {
            services.sillytavern-nixos = withConfig {
              proxyUpstreams = [ { name = "st"; forwardedFor = "replace"; } ];
              files.common."themes/ok.json" = { json = { }; policy = "overwrite"; mode = "0644"; };
            };
          };
        }
      );
    in
    pkgs.runCommand "sillytavern-check-guards-fire" { }
      ''
        status=0

        echo "guards-fire: ${toString (builtins.length rows)} guards"

        for row in ${lib.concatMapStringsSep " " (r: "\"${r.name} ${toString r.firing} ${toString r.hits}\"") results}; do
          set -- $row
          name=$1; firing=$2; hits=$3
          if [ "$hits" = "0" ]; then
            echo "  DEAD  $name (assertions firing: $firing, messages matching: $hits)" >&2
            status=1
          else
            echo "  ok    $name (firing: $firing, matching: $hits)"
          fi
        done

        if [ "${toString clean}" != "0" ]; then
          echo "" >&2
          echo "guards-fire: a VALID configuration tripped ${toString clean} assertion(s):" >&2
          status=1
        fi

        if [ "$status" != "0" ]; then
          echo "" >&2
          echo "A dead guard means the assertion it names no longer fires, so the" >&2
          echo "configuration it protects is no longer caught at eval time." >&2
          exit 1
        fi

        echo "PASS guards-fire"
        touch "$out"
      '';


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
          settings.common = { main_api = "openai"; oai_settings = { temp_openai = 0.77; }; };
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

  # `errorPages` is the second writer into `dataRootFiles`, and it has the same
  # three properties `customCssIsolated` asserts: unset means untouched, every
  # key is a LITERAL upstream filename, and the file is never also seeded
  # per-account.
  #
  # It also has two more that only it can fail:
  #   * `forbidden-by-whitelist.html` contains HYPHENS. Renaming the key to
  #     `forbiddenByWhitelist.html` produces a file the server never reads, and
  #     the failure is silent — branding simply does not apply.
  #   * a PARTIAL declaration must emit only the pages declared, leaving the
  #     rest to the server's own first-start content seeding.
  errorPagesIsolated =
    pkgs:
    let
      specOf =
        module: (evalSystem pkgs module).config.services.sillytavern-nixos.internal.seedSpecJson;

      unset = specOf { services.sillytavern-nixos.enable = true; };

      page = pkgs.writeText "page.html" "<h1>branded</h1>\n";

      partial = specOf {
        services.sillytavern-nixos = {
          enable = true;
          errorPages = {
            unauthorized = page;
            forbiddenByWhitelist = page;
          };
        };
      };

      full = specOf {
        services.sillytavern-nixos = {
          enable = true;
          errorPages = {
            unauthorized = page;
            forbiddenByWhitelist = page;
            hostNotAllowed = page;
            urlNotFound = page;
          };
        };
      };
    in
    assert unset.dataRootFiles == { };

    assert lib.attrNames partial.dataRootFiles == [
      "_errors/forbidden-by-whitelist.html"
      "_errors/unauthorized.html"
    ];

    assert lib.attrNames full.dataRootFiles == [
      "_errors/forbidden-by-whitelist.html"
      "_errors/host-not-allowed.html"
      "_errors/unauthorized.html"
      "_errors/url-not-found.html"
    ];

    # Every page is Nix-authoritative and browser-readable, for the same
    # reasons as `_css/user.css`: served to unauthenticated visitors, and never
    # updated after the content manager's one-time copy.
    assert lib.all (p: partial.dataRootFiles.${p}.policy == "overwrite")
      (lib.attrNames partial.dataRootFiles);
    assert lib.all (p: partial.dataRootFiles.${p}.mode == "0644")
      (lib.attrNames partial.dataRootFiles);

    # And never per-account either.
    assert lib.all (
      h: !(lib.any (f: lib.hasPrefix "_errors/" f) (lib.attrNames partial.users.${h}.files))
    ) (lib.attrNames partial.users);

    pkgs.runCommand "sillytavern-check-error-pages-isolated" { } ''
      echo "PASS error-pages-isolated (unset -> {}; partial -> 2 literal keys; hyphenated name preserved; overwrite, 0644)"
      touch "$out"
    '';

  # Declaring an extension or a plugin is the single most ordinary thing a
  # consumer does with this module, and it used to break the build two ways.
  #
  # 1. The `rev`-pinning assertion used `builtins.all` with a curried
  #    two-argument predicate. On an EMPTY list `builtins.all` returns true
  #    without calling the predicate, so every other check in this file passed
  #    and the bug was invisible. Declare one plugin and `checkAssertWarn` —
  #    which forces every assertion on every rebuild — threw
  #    "expected a Boolean but found a function".
  #
  # 2. The auto-update assertions read `cfg.config.*`, the OPTION, while
  #    modules/config.nix overrides the same keys in `effectiveConfig`. The
  #    option therefore still held upstream's `true` in precisely the case the
  #    assertion is about, and it fired on the configuration its own message
  #    described as already handled.
  #
  # No other check reached either path, because no other check declares a
  # plugin. The URLs are deliberately fictional: nothing here forces the
  # package, so no `fetchgit` runs and the check needs no network.
  pluginsAndExtensionsAreUsable =
    pkgs:
    let
      # Authentication is configured in both, so the deliberate "no
      # authentication configured" failure — which a bare `enable = true` trips
      # by design — is out of the picture and cannot be mistaken for a defect.
      common = {
        enable = true;
        config.enableUserAccounts = true;
      };

      withExtension = (evalSystem pkgs {
        services.sillytavern-nixos = common // {
          extensions.vector-storage = {
            url = "https://github.com/example/SillyTavern-VectorStorage.git";
            rev = "refs/tags/v3.0.0";
          };
        };
      }).config;

      withPlugin = (evalSystem pkgs {
        services.sillytavern-nixos = common // {
          config.enableServerPlugins = true;
          plugins.dice-roll = {
            url = "https://github.com/example/SillyTavern-Dice-Roll.git";
            rev = "refs/tags/v1.0.0";
          };
        };
      }).config;

      ext = inspectedAssertions withExtension;
      plug = inspectedAssertions withPlugin;
      # Precomputed in Nix, not in the shell: `runCommand` writes a SHELL
      # script, so a Nix expression cannot appear inside one.
      extCount = builtins.length (builtins.attrNames withExtension.services.sillytavern-nixos.extensions);
      plugCount = builtins.length (builtins.attrNames withPlugin.services.sillytavern-nixos.plugins);
    in
    # The load-bearing property: every assertion evaluates to a BOOLEAN. This is
    # what `builtins.all` with a curried predicate broke, and it is invisible to
    # any check that does not declare a plugin.
    assert ext.allBooleans;
    assert plug.allBooleans;

    # Neither system may fail an auto-update assertion.
    assert ourFailuresMatching withExtension ".*autoUpdate.*" == [ ];
    assert ourFailuresMatching withPlugin ".*autoUpdate.*" == [ ];

    # And the overrides those assertions police must actually be in force. This
    # is the second half of the fix: the option may keep upstream's `true`,
    # because that is what `effectiveConfig` exists to override.
    assert withExtension.services.sillytavern-nixos.internal.effectiveConfig.extensions.autoUpdate == false;
    assert withPlugin.services.sillytavern-nixos.internal.effectiveConfig.enableServerPluginsAutoUpdate == false;

    pkgs.runCommand "sillytavern-check-plugins-extensions-usable"
      { }
      ''
        echo "PASS plugins-extensions-usable"
        echo "  ${toString extCount} extension declared: every assertion evaluated to a boolean"
        echo "  ${toString plugCount} plugin declared: every assertion evaluated to a boolean"
        echo "  effective autoUpdate overrides both in force; no auto-update assertion fired"
        touch "$out"
      '';

  # `hardware` was a documented option that did nothing at all: the merge into
  # `serviceConfig` was commented out, leaving a bare `;` after the attrset.
  # Setting `memoryMax = "4G"` produced no cap whatsoever.
  #
  # The fix is not a plain `// cfg.hardware`, and that is the part worth a
  # regression test. NixOS renders `serviceConfig` attribute names VERBATIM and
  # systemd's directives are case-sensitive, so merging the camelCase option
  # names straight in yields a unit containing
  #
  #   memoryMax=4G
  #   ioWeight=500
  #
  # — unknown directives, silently ignored. A unit that reads as configured and
  # caps nothing is worse than no cap at all, and it is what a naive fix would
  # have produced. Verified by evaluating a unit with both spellings set: the
  # PascalCase one renders, the camelCase one lands verbatim and does nothing.
  #
  # So this asserts on the exact directive names in the RENDERED UNIT TEXT, not
  # just on `serviceConfig` — the unit is what systemd sees, and it is where the
  # casing trap is observable. Both directions: caps set, and nothing set.
  hardwareCapsApplied =
    pkgs:
    let
      common = {
        enable = true;
        config.enableUserAccounts = true;
      };

      # `cpuQuota` → `CPUQuota` and `ioWeight` → `IOWeight` are the two names
      # where the option and the directive differ by more than capitalisation,
      # so they are the ones a rename map would plausibly get wrong.
      capped = (evalSystem pkgs {
        services.sillytavern-nixos = common // {
          hardware = {
            memoryMax = "4G";
            memoryHigh = "3G";
            memorySwapMax = "1G";
            cpuQuota = "200%";
            nice = 5;
            ioWeight = 500;
          };
        };
      }).config;

      bare = (evalSystem pkgs { services.sillytavern-nixos = common; }).config;

      wanted = [
        "MemoryMax=4G"
        "MemoryHigh=3G"
        "MemorySwapMax=1G"
        "CPUQuota=200%"
        "Nice=5"
        "IOWeight=500"
      ];
      unitText = cfg: cfg.systemd.units."sillytavern.service".text;
      cappedUnit = unitText capped;
      bareUnit = unitText bare;

      # The unit texts as store paths, so the build below can grep them. Built
      # with `writeText` rather than written by the script: that way the text is
      # a build input, and the evaluation-time asserts above are checking the
      # same string the build is.
      cappedUnitPath = pkgs.writeText "sillytavern-capped.unit" cappedUnit;
      bareUnitPath = pkgs.writeText "sillytavern-bare.unit" bareUnit;
    in
    # Asserted at EVAL time on the unit text, so a failure names the directive
    # rather than only being visible in a build log.
    assert lib.all (line: lib.hasInfix line cappedUnit) wanted;
    # Nothing set, nothing emitted. Every member of `hardware` defaults to null,
    # and a `MemoryMax = null` in serviceConfig breaks the attrsOf unitOption
    # merge — so "absent" and "null" are not interchangeable here.
    assert lib.all (name: !lib.hasInfix "${name}=" bareUnit) (map (line: lib.head (lib.splitString "=" line)) wanted);

    pkgs.runCommand "sillytavern-check-hardware-caps"
      {
        nativeBuildInputs = [ pkgs.gnugrep pkgs.coreutils ];
      }
      ''
        fail() {
          echo "FAIL hardware-caps: $1" >&2
          exit 1
        }

        for want in ${lib.concatMapStringsSep " " (line: lib.escapeShellArg line) wanted}; do
          grep -qxF "$want" ${cappedUnitPath} \
            || fail "the unit is missing the directive: $want"
        done

        # The casing trap: the camelCase spellings must NOT be present at all.
        # They are the shape a naive `// cfg.hardware` would produce, and systemd
        # ignores them without complaining.
        for wrong in memoryMax memoryHigh memorySwapMax cpuQuota ioWeight; do
          if grep -qE "^$wrong=" ${cappedUnitPath}; then
            echo "FAIL hardware-caps: the unit contains the non-systemd spelling '$wrong='" >&2
            echo "  serviceConfig attribute names are rendered verbatim, so this" >&2
            echo "  directive is unknown to systemd and silently ignored." >&2
            exit 1
          fi
        done

        for unset in MemoryMax MemoryHigh MemorySwapMax CPUQuota IOWeight; do
          if grep -qE "^$unset=" ${bareUnitPath}; then
            fail "no hardware caps were set, but the unit emits $unset="
          fi
        done

        echo "PASS hardware-caps (6 caps applied under their systemd names; none emitted when unset)"
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

  # ── 16. `systemdOverrides` merges instead of replacing ──────────────────────
  #
  # The bug this exists for: `systemd.services.sillytavern` ended in a plain
  # `// cfg.systemdOverrides`, and attrset `//` REPLACES. One
  # `serviceConfig.ReadWritePaths` therefore reduced the whole unit's
  # serviceConfig to `[ "ExecStartPre" "ReadWritePaths" ]` — no ExecStart, no
  # User, no StateDirectory, no hardening — while `nixos-rebuild` stayed green.
  #
  # Asserted in both directions, which is what makes it a merge rather than an
  # accidental swap: the override's key must APPEAR, and the module's own keys
  # must all still be there.
  systemdOverridesMerge =
    pkgs:
    let
      plain = evalSystem pkgs { services.sillytavern-nixos.enable = true; };
      over = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          # EXACTLY the form docs/installing.md tells people to use.
          systemdOverrides.serviceConfig.ReadWritePaths = [ "/var/lib/sillytavern/extra" ];
        };
      };
      plainSc = plain.config.systemd.services.sillytavern.serviceConfig;
      overSc = over.config.systemd.services.sillytavern.serviceConfig;
      # Every directive the plain unit sets must survive the override.
      dropped = builtins.filter (k: !(overSc ? ${k})) (builtins.attrNames plainSc);
    in
    assert dropped == [ ];
    assert overSc ? ReadWritePaths;
    assert overSc.ReadWritePaths == [ "/var/lib/sillytavern/extra" ];
    pkgs.runCommand "sillytavern-check-systemd-overrides-merge" { }
      ''
        echo "PASS systemd-overrides-merge (plain: ${toString (builtins.length (builtins.attrNames plainSc))} directives, overridden: ${toString (builtins.length (builtins.attrNames overSc))})"
        touch "$out"
      '';

  # ── 17. The unit is actually pulled in at boot ─────────────────────────────
  #
  # `after = [ "network-online.target" ]` without `wantedBy` gives a unit that
  # is correctly ORDERED and never STARTED. There is no error for it: the
  # machine boots, and `systemctl status sillytavern` says "inactive (dead)".
  wantedByIsSet =
    pkgs:
    let
      system = evalSystem pkgs { services.sillytavern-nixos.enable = true; };
      wantedBy = system.config.systemd.services.sillytavern.wantedBy;
    in
    assert lib.elem "multi-user.target" wantedBy;
    pkgs.runCommand "sillytavern-check-wantedby" { }
      ''
        echo "PASS wantedby (${lib.concatStringsSep " " wantedBy})"
        touch "$out"
      '';

  # ── 18. Per-file `policy` / `mode` reach the seeder ─────────────────────────
  #
  # `scripts/st_seed_files.py` has implemented and tested `policy_for` /
  # `mode_for` for the whole life of this project, and the Nix option declared
  # neither — so they were unreachable and the one-file-overrides-the-global
  # use case could not be expressed at all.
  #
  # Also pins the "unset means absent" contract: an entry that declares neither
  # must NOT carry a `policy: null` into the spec, so the rendered bytes do not
  # change for everyone who never opts in.
  perFilePolicyAndMode =
    pkgs:
    let
      system = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          files = {
            common = {
              "themes/plain.json" = { json = { a = 1; }; };
              "themes/locked.json" = { json = { b = 2; }; };
            };
            byUser.seanc = {
              "themes/authoritative.json" = {
                json = { c = 3; };
                policy = "overwrite";
                mode = "0644";
              };
            };
          };
        };
      };
      files = system.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.files;
      plain = files."themes/plain.json";
      locked = files."themes/locked.json";
      mine = files."themes/authoritative.json";
    in
    # Unset knobs stay OUT of the spec rather than riding along as nulls.
    assert !(plain ? policy);
    assert !(plain ? mode);
    assert !(locked ? policy);
    assert !(locked ? mode);
    # A per-user override lands verbatim.
    assert mine.policy == "overwrite";
    assert mine.mode == "0644";
    pkgs.runCommand "sillytavern-check-per-file-policy-mode" { }
      ''
        echo "PASS per-file-policy-mode"
        touch "$out"
      '';

  # ── 19. Reserved paths and bad modes are caught at EVAL time ───────────────
  #
  # Both used to fail only at ACTIVATION, from the unit's `preStart`, which
  # means the seeder exits non-zero, `ExecStartPre` fails and THE SERVICE DOES
  # NOT START — after a green `nixos-rebuild`, with the entries visited before
  # the bad one already written.
  #
  # Each case asserts the assertion FIRES; the mirror-image case (a legal path
  # and a legal mode must NOT trip anything) stops this from being satisfied by
  # an assertion that is simply always false.
  reservedPathsAsserted =
    pkgs:
    let
      nFailures =
        block:
        builtins.length (
          builtins.filter (a: !a.assertion)
            (evalSystem pkgs {
              services.sillytavern-nixos = {
                enable = true;
                config.enableUserAccounts = true;
                users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
                files.byUser.seanc = block;
              };
            }).config.assertions
        );
      # These all pass the seeder's deny-list.
      refused = {
        "backups/x.json" = { json = { }; };
        "_cache/model.json" = { json = { }; };
        "_webpack/lib.json" = { json = { }; };
        "_storage/blob" = { json = { }; };
        "stats.json" = { json = { }; };
        "config.yaml" = { json = { }; };
      };
      # Legal, and must trip NOTHING.
      legal = {
        "themes/ok.json" = { json = { }; policy = "overwrite"; mode = "0644"; };
        "worlds/book.json" = { json = { }; };
        # `backups` is only reserved at the TOP level of the account dir.
        "user/backups/ok.json" = { json = { }; };
      };
      badModes = {
        "themes/a.json" = { json = { }; mode = "644"; };
        "themes/b.json" = { json = { }; mode = "8888"; };
        "themes/c.json" = { json = { }; mode = "06444"; };
      };
      # The deny-list is ONE assertion covering every entry, not one assertion
      # per entry, so `nFailures` counts ASSERTIONS. Each reserved path is
      # therefore exercised ON ITS OWN: if they were passed together, a single
      # assertion firing once would look identical to all six being caught.
      missed = builtins.filter (rel: nFailures { ${rel} = refused.${rel}; } < 1) (
        builtins.attrNames refused
      );
      missedModes = builtins.filter (rel: nFailures { ${rel} = badModes.${rel}; } < 1) (
        builtins.attrNames badModes
      );
    in
    assert missed == [ ];
    assert missedModes == [ ];
    # …and the legal set must trip nothing at all, or the checks above would be
    # satisfiable by an assertion that is simply always false.
    assert nFailures legal == 0;
    pkgs.runCommand "sillytavern-check-reserved-paths" { }
      ''
        echo "PASS reserved-paths-asserted"
        touch "$out"
      '';

  # ── 20. `files.byUser` does not break evaluation ───────────────────────────
  #
  # The one that mattered most. `config.assertions` is reached by
  # `system.build.toplevel`, which is what `nixos-rebuild switch` builds, so a
  # broken assertion expression was not a latent test gap — it made the
  # per-account seeding feature unusable in anger:
  #
  #   error: expected a list but found a set: { "themes/mine.json" = «thunk»; }
  #
  # Two expressions were wrong: one passed a list of ATTRSETS to
  # `lib.concatLists`, and two more called `lib.mapAttrs lib.attrNames`, where
  # `mapAttrs` invokes its function as `f name value` and `attrNames` is
  # arity-1, so it received the HANDLE NAME and died with
  # `expected a set but found a string: "seanc"`.
  #
  # Nothing in the suite set `files.byUser`, so it was never forced.
  #
  # Asserted on `system.build.toplevel` specifically, not on some convenient
  # leaf, because "does the whole system evaluate" is the actual contract.
  filesByUserEvaluates =
    pkgs:
    let
      system = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          config.enableUserAccounts = true;
          users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
          files.byUser.seanc = {
            "themes/Azure.json".json = { palette.accent = "#ff0000"; };
            "settings.json".json = { main_api = "custom"; };
          };
        };
      };
      drvPath = system.config.system.build.toplevel.drvPath;
    in
    assert builtins.isString drvPath;
    pkgs.runCommand "sillytavern-check-files-by-user-evaluates" { }
      ''
        echo "PASS files-by-user-evaluates"
        touch "$out"
      '';

  # ── 20a. settings/files merge DEEPLY, not shallowly ─────────────────────────
  #
  # This merges `settings.common` with `settings.byUser.<handle>` (and
  # `files.common` with `files.byUser.<handle>`). The merge MUST be deep: a
  # per-account override of one leaf has to leave the sibling keys the account
  # did not restate intact.
  #
  # It used to be `//`, which is SHALLOW: it replaced the whole subtree, so
  # overriding `oai_settings.openai_max_context` silently deleted
  # `oai_settings.custom_url` from the account's settings.json. The option's
  # description and docs/options.md both promised a deep merge; the code did
  # not do one. This check is what makes the promise true and keeps it true.
  #
  # It asserts on the RENDERED seed spec, so it covers the whole path: the Nix
  # merge, the option types, and the JSON that the seeder will write to disk.
  settingsDeepMerge =
    pkgs:
    let
      system = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          config.enableUserAccounts = true;
          users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
          settings = {
            common.oai_settings = {
              openai_max_context = 100;
              custom_url = "https://common.example.com";
            };
            common.power_user.font_scale = 1.2;
            byUser.seanc.oai_settings.openai_max_context = 200;
          };
        };
      };
      merged = system.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.settings;

      # A sibling key the account did NOT override must survive.
      siblingSurvived = merged.oai_settings ? custom_url;
      # The overridden leaf must take the account's value.
      leafOverrode = merged.oai_settings.openai_max_context == 200;
      # A whole subtree the account never mentioned must survive untouched.
      otherSubtreeSurvived = merged.power_user.font_scale == 1.2;
    in
    assert siblingSurvived && leafOverrode && otherSubtreeSurvived;
    pkgs.runCommand "sillytavern-check-settings-deep-merge" { }
      ''
        echo "PASS settings-deep-merge"
        touch "$out"
      '';

  # ── 21b. settingsExtra lands in every account's settings.json ──────────────
  settingsExtraRendered =
    pkgs:
    let
      system = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          config.enableUserAccounts = true;
          users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
          settingsExtra = {
            mainApi = "kobold";
            maxContext = 8192;
            background.url = "https://example.com/bg.png";
            swipes = false;
            username = "Seanc";
            proxies = [
              { name = "Corp"; url = "http://proxy:8080"; password = "secret"; }
            ];
            selectedProxy = 1;
            extensionSettings.disabledExtensions = [ "caption" ];
          };
        };
      };
      s = system.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.settings;
    in
    assert s.main_api == "kobold";
    assert s.max_context == 8192;
    assert s.background.url == "https://example.com/bg.png";
    assert s.swipes == false;
    assert s.username == "Seanc";
    assert s.proxies == [ { name = "Corp"; url = "http://proxy:8080"; password = "secret"; } ];
    assert s.selected_proxy == 1;
    assert s.extension_settings.disabledExtensions == [ "caption" ];
    # defaults present when unset
    assert s.background.fitting == "cover";
    pkgs.runCommand "sillytavern-check-settings-extra" { }
      ''
        echo "PASS settings-extra"
        touch "$out"
      '';

  # ── 21c. settingsExtra deep-merges with settings.common ───────────────────
  settingsExtraMergeOrder =
    pkgs:
    let
      system = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          config.enableUserAccounts = true;
          users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
          settingsExtra.mainApi = "kobold";
          settings.common.main_api = "openai";
        };
      };
      s = system.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.settings;
    in
    # settings.common wins over settingsExtra defaults (common is merged later)
    assert s.main_api == "openai";
    pkgs.runCommand "sillytavern-check-settings-extra-merge" { }
      ''
        echo "PASS settings-extra-merge"
        touch "$out"
      '';

  # ── 21. The hardening block is PINNED ──────────────────────────────────────
  #
  # `moduleEvaluates` pins exactly ONE of the ~26 hardening directives
  # (`ProtectSystem`), and nothing in the suite mentions `NoNewPrivileges`,
  # `SystemCallFilter`, `CapabilityBoundingSet`, `RestrictAddressFamilies`,
  # `ProtectHome` and the rest. Deleting or loosening any of them is therefore
  # invisible. (`MemoryDenyWriteExecute` is the exception in the other
  # direction: `hardeningPinned` FORBIDS it, because it is fatal to V8 — see
  # the `forbidden` attrset below.)
  #
  # That is a real exposure rather than a theoretical one: this unit runs a
  # Node server that parses attacker-controlled JSON and renders user-supplied
  # HTML, serving it out of a read-only store path.
  #
  # Asserted on the `serviceConfig` ATTRSET rather than by grepping the rendered
  # unit, which is strictly stronger: NixOS renders these attribute names
  # verbatim into the unit file (`memoryMax` would become an unknown directive
  # and be ignored — see the note in modules/services.nix), so the attribute
  # name IS the directive, and asserting the VALUE catches a directive that was
  # kept but weakened.
  # ── Extracting the option surface from upstream's own default/config.yaml ──
  #
  # Used by the `libHelpers` check to generate its cases from the real
  # document, so a key added upstream is covered the next time it runs rather
  # than needing someone to remember to add a case.
  #
  # Two levels only. The module's option surface tracks the shape of the real
  # document, and the deeper keys follow from their parent; flattening the whole
  # file would produce hundreds of paths differing only in a leaf nobody sets.
  configKeyPaths =
    text:
    let
      # lib.splitString, not builtins.split: builtins.split takes a LIST of
      # separators, so passing "\n" splits on each newline CHARACTER and
      # yields the empty strings between them.
      lines = lib.splitString "\n" text;

# builtins.match is a FULL match, hence the trailing `.*`, and it
              # returns null when it does not match. Blank lines, comments
              # and list items all return null and are skipped.
              top = line: builtins.match "^([A-Za-z_][A-Za-z0-9_]*):.*" line;
              second = line: builtins.match "^  ([A-Za-z_][A-Za-z0-9_]*):.*" line;
              head1 = m: builtins.head m;

      # One pass, carrying the current top-level key so a second-level name can
      # be joined to its parent. Comment and list lines match neither pattern
      # and fall through untouched.
      walk =
        lib.foldl'
          (
            acc: line:
            let
              t = top line;
              s = second line;
            in
            if t != null then
              {
                keys = acc.keys ++ [ (head1 t) ];
                top = head1 t;
              }
            else if s != null && acc.top != null then
              {
                keys = acc.keys ++ [ "${acc.top}.${head1 s}" ];
                inherit (acc) top;
              }
            else acc
          )
          {
            keys = [ ];
            top = null;
          }
          lines;

      inherit (walk) keys;
    in
    keys;

  # ── libHelpers — pins the pure helpers in lib/default.nix ─────────────────
  #
  # `lib.keyToEnv` is a deliberate REIMPLEMENTATION of upstream's `keyToEnv`
  # in src/util.js. Nix cannot import a JS function, so nothing forces the two
  # to agree: get it wrong and every `SILLYTAVERN_*` override silently stops
  # taking effect, with no error anywhere and no failed evaluation.
  #
  # The two halves are computed by the two languages that own them:
  #
  #   * Nix evaluates the real `lib/default.nix` — here, at EVAL time, on the
  #     host. Not at build time: a build sandbox has no writable
  #     /nix/var/nix/profiles, so `nix eval` and `nix-instantiate` both fail
  #     inside one with "Permission denied". Evaluating on the host and
  #     passing the result in as JSON sidesteps that entirely.
  #   * Node runs the real `src/util.js` — in the build, where it belongs.
  #
  # The cases come from upstream's own default/config.yaml, plus the keys that
  # are awkward on purpose. `keyToEnv` uppercases and maps '.' to '_' but does
  # NOT split camelCase, so `enableCorsProxy` becomes SILLYTAVERN_ENABLECORSPROXY
  # with no underscore. That irregularity is the whole reason the check exists.
  libHelpers =
    pkgs:
    let
      edgeCases = [
        "extensions.models.speechToText"
        "browserLaunch.enabled"
        "enableCorsProxy"
        "basicAuthMode"
        "requestProxyBypass"
        "logging.accessLog"
        "unstable_forwardProxyMode"
        "extensionSettings"
        "a.b.c.d.e"
        "already_upper"
        "with_underscore"
        "Mixed_Case.Key"
      ];

      configText = builtins.readFile ../default/config.yaml;
      keys = lib.unique (configKeyPaths configText ++ edgeCases);

      # The Nix side of the comparison, computed here rather than in the build.
      nixSide = builtins.listToAttrs (
        map (key: {
          name = key;
          value = st.keyToEnv key;
        })
        keys
      );
    in
    pkgs.runCommand "sillytavern-check-lib-helpers"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.python3
        ];
      }
      ''
        cp ${./test_key_to_env.py} ./test_key_to_env.py

        # Both sides of the comparison, plus the two upstream files the check
        # reads them from.
        cp ${pkgs.writeText "key_to_env_from_nix.json" (builtins.toJSON nixSide)} ./key_to_env_from_nix.json
        cp ${../default/config.yaml} ./config.yaml
        mkdir -p ./src
        cp ${../src/util.js} ./src/util.js

        python3 ./test_key_to_env.py
        touch $out
      '';

  # ── 24. The settings-key guard knows real settings from imaginary ones ────
  #
  # `settings.json` is read by direct property access, so a key that upstream
  # does not have is inert — written to disk, never read, no warning. The guard
  # in modules/assertions.nix refuses those keys, using the inventory derived
  # from upstream's own sources (lib/settings-inventory.json).
  #
  # A guard that refuses everything is as useless as no guard, so BOTH
  # directions are asserted here:
  #
  #   1. a rich, REAL settings configuration must produce NO failure — several
  #      subtrees, a free-form map, a nested upstream object, a per-account
  #      override, and the top-level keys the client writes;
  #   2. a typo must produce exactly one failure that NAMES the path.
  #
  # Direction 1 is the one that catches a false positive, which is the failure
  # mode a key checker is most likely to have: upstream's field names are
  # snake_case with a few camelCase exceptions, and a checker that normalised
  # them would reject the real thing.
  settingsKeysKnown =
    pkgs:
    let
      auth = {
        enable = true;
        config.enableUserAccounts = true;
        users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
      };

      # Every field below exists upstream, at the pinned version. The names are
      # taken from lib/settings-inventory.json, which is derived from the
      # source — this list is a SAMPLE of it, not a copy.
      valid = evalSystem pkgs {
        services.sillytavern-nixos = auth // {
          settings = {
            common = {
              main_api = "openai";
              username = "seanc";
              max_context = 32768;
              oai_settings = {
                custom_url = "https://llm.example.com/v1";
                openai_max_context = 32768;
                temp_openai = 0.7;
                stream_openai = true;
              };
              power_user = {
                font_scale = 1.2;
                fast_ui_mode = false;
                chat_width = 60;
                # A free-form map: keyed by persona name, so ANY key is legal.
                personas.Alice = "A description.";
                # A nested upstream object, set as a whole.
                instruct.preset = "Alpaca";
              };
              world_info_settings = {
                world_info_depth = 4;
                world_info_recursive = true;
              };
              extension_settings = {
                caption.enabled = true;
              };
              tags = [ "tag" ];
            };
            byUser.seanc.oai_settings.openai_max_context = 65536;
          };
        };
      };

      # The guard's own message, so the check asserts on THIS guard and not on
      # some other assertion that happens to fire.
      guardPattern = ".*not settings SillyTavern has.*";
      validFailures = ourFailuresMatching valid.config guardPattern;

      typo = evalSystem pkgs {
        services.sillytavern-nixos = auth // {
          settings.common.power_user.font_scal = 1.2;
        };
      };
      typoFailures = ourFailuresMatching typo.config guardPattern;
      typoNames = lib.any (e: builtins.match ".*font_scal.*" e.message != null) typoFailures;

      # A key outside the client's save payload is a DIFFERENT failure: the
      # browser deletes it at the next save.
      strayPattern = ".*the browser DISCARDS them.*";
      stray = evalSystem pkgs {
        services.sillytavern-nixos = auth // {
          settings.common.my_own_key = 1;
        };
      };
      strayFailures = ourFailuresMatching stray.config strayPattern;

      # And a value of the WRONG KIND is a third failure. In JavaScript a
      # non-empty string is TRUE, so `waifuMode = "false"` would leave the
      # setting ON while the configuration says OFF — silently.
      typePattern = ".*not the type upstream expects.*";
      mistyped = evalSystem pkgs {
        services.sillytavern-nixos = auth // {
          settings.common.power_user.waifuMode = "false";
        };
      };
      mistypedFailures = ourFailuresMatching mistyped.config typePattern;
    in
    assert validFailures == [ ];
    assert builtins.length typoFailures == 1;
    assert typoNames;
    assert builtins.length strayFailures == 1;
    assert builtins.length mistypedFailures == 1;
    pkgs.runCommand "sillytavern-check-settings-keys-known" { }
      ''
        echo "PASS settings-keys-known (real settings accepted; typo, stray key and mistyped value all refused)"
        touch "$out"
      '';

  # ── 24b. The typed settings tree covers every setting upstream has ───────
  #
  # `settingsExtra.powerUser` and its six siblings are a TYPED mirror of the
  # `settings.json` subtrees: one option per setting, with upstream's own
  # name, the right type, and upstream's default in the description.
  #
  # The tree is generated from `lib/settings-inventory.json`, so it cannot
  # drift from upstream by hand — but "generated" is a claim, and this check
  # is the measurement: it sets EVERY field in the inventory to a value of the
  # right type, and asserts that the rendered `settings.json` then contains
  # exactly those paths, and nothing else.
  #
  # That covers three things at once:
  #   * every setting upstream has is settable (the tree is complete);
  #   * no setting that upstream does not have is settable (the tree is
  #     exactly the inventory, no more);
  #   * the types are right — a field whose type did not match would fail the
  #     option's own type check, and a field that is missing from the tree
  #     would fail the "does not exist" check.
  settingsTypedTree =
    pkgs:
    let
      inventory = builtins.fromJSON (builtins.readFile ../lib/settings-inventory.json);

      # A value of the right type for a field.
      sampleValue =
        field:
        if field.type == "bool" then
          true
        else if field.type == "int" then
          1
        else if field.type == "float" then
          1.5
        else if field.type == "array" then
          [ ]
        else
          # `unknown` (an upstream constant) and `null` are `anything`.
          "s";

      # A nested attrset from dotted paths.
      insert =
        attrs: path: value:
        let
          parts = lib.splitString "." path;
          name = lib.head parts;
          rest = lib.tail parts;
        in
        if rest == [ ] then
          attrs // { ${name} = value; }
        else
          attrs // {
            ${name} = insert (attrs.${name} or { }) (lib.concatStringsSep "." rest) value;
          };

      sampleFor =
        surface:
        lib.foldl' (acc: field: insert acc field.path (sampleValue field)) { }
          inventory.surfaces.${surface}.fields;

      # The leaf paths of a rendered JSON object, as dotted strings.
      pathsOf =
        attrs:
        lib.concatMap
          (name:
            let
              value = attrs.${name};
            in
            if lib.isAttrs value then
              map (p: "${name}.${p}") (pathsOf value)
            else
              [ name ])
          (lib.attrNames attrs);

      system = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          config.enableUserAccounts = true;
          users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
          settingsExtra = {
            powerUser = sampleFor "power_user";
            oaiSettings = sampleFor "oai_settings";
            textGenerationSettings = sampleFor "textgenerationwebui_settings";
            naiSettings = sampleFor "nai_settings";
            kaiSettings = sampleFor "kai_settings";
            hordeSettings = sampleFor "horde_settings";
            worldInfoSettings = sampleFor "world_info_settings";
          };
        };
      };
      rendered = system.config.services.sillytavern-nixos.internal.seedSpecJson.users."default-user".settings;

      # The JSON key a typed option lands under is the SURFACE NAME itself —
      # `powerUser` is the Nix option, `power_user` is what lands in
      # `settings.json`. Getting that backwards makes the check compare the
      # rendered tree against an empty one, which "passes" for the wrong
      # reason.
      expected =
        lib.mapAttrs (
          surface: fields: lib.map (field: field.path) fields.fields
        ) inventory.surfaces;

      actual = lib.mapAttrs (surface: _: pathsOf (rendered.${surface} or { })) inventory.surfaces;

      # `builtins.sort` takes a COMPARATOR first — `lib.sort` is that
      # built-in, not a one-argument convenience.
      mismatched = lib.filterAttrs (
        surface: paths: builtins.sort (a: b: a < b) paths
        != builtins.sort (a: b: a < b) (expected.${surface} or [ ])
      ) actual;
    in
    assert mismatched == { };
    # And nothing null survived the prune: a null in `settings.json` would
    # OVERRIDE upstream's own default with null, which is the opposite of
    # what "not declared" is supposed to mean.
    assert lib.all (value: value != null) (lib.concatLists (lib.attrValues actual));
    pkgs.runCommand "sillytavern-check-settings-typed-tree" { }
      ''
        echo "PASS settings-typed-tree (every upstream setting is settable, and nothing else is)"
        touch "$out"
      '';

  # ── 24c. A typo in the typed tree is refused ──────────────────────────────
  #
  # The point of the tree is that a mistake is LOUD. The module system says
  # "The option `…font_scal' does not exist. Did you mean `…font_scale'?" —
  # which is exactly the error a person wants at `nixos-rebuild` time rather
  # than a setting that quietly does nothing.
  #
  # `builtins.tryEval` cannot report the message, so this asserts the part
  # that matters: the evaluation FAILS. A tree that accepted the typo would
  # evaluate cleanly, and this check would go red.
  settingsTypedTreeRefusesTypos =
    pkgs:
    let
      tree = import ../lib/settings-tree.nix {
        inherit lib;
        inventory = builtins.fromJSON (builtins.readFile ../lib/settings-inventory.json);
      };

      # A module system with ONE option, typed with the tree's own type.
      #
      # The whole NixOS system is not needed to test this: what is under test
      # is the TYPE, and the type is the same object the module uses. Building
      # a full system here would add a minute of evaluation to prove the same
      # thing — and, as it turns out, would hide it: the unmatched-definition
      # check in `nixosSystem` is eager, so the error escapes `tryEval`
      # instead of being caught by it.
      typed =
        value:
        lib.evalModules {
          modules = [
            (
              { lib, ... }:
              {
                options.typed = lib.mkOption {
                  type = tree.surfaceType "power_user";
                  default = { };
                };
              }
            )
            { typed = value; }
          ];
        };

      # The parentheses around the WHOLE expression matter: `tryEval (f x).y`
      # applies `.y` to tryEval's RESULT, so the evaluation that throws
      # happens outside the tryEval and the error escapes it.
      forces = value: builtins.tryEval ((typed value).config.typed);

      good = forces { font_scale = 1.2; };
      typo = forces { font_scal = 1.2; };

      # The WRONG TYPE is a different beast: a type error inside a submodule
      # is raised while that submodule's own fixpoint is computed, which is
      # eager — so `builtins.tryEval` cannot catch it and it escapes as a
      # hard error. (An unknown option CAN be caught: that check is a `seq`
      # on the config, so it stays lazy.) The type mapping is therefore
      # asserted directly, through the tree's own type for that path.
      numberType = tree.typeOfPath "power_user" "font_scale";
      stringType = tree.typeOfPath "oai_settings" "custom_url";
      boolType = tree.typeOfPath "power_user" "waifuMode";
    in
    assert good.success;
    assert !typo.success;
    # A number accepts a number and refuses a string; a string accepts a
    # string and refuses a number; a boolean accepts only a boolean.
    assert numberType.check 1.2;
    assert numberType.check 1;
    assert !numberType.check "big";
    assert stringType.check "https://llm.example.com/v1";
    assert !stringType.check 123;
    assert boolType.check true;
    assert !boolType.check "false";
    pkgs.runCommand "sillytavern-check-settings-typed-tree-refuses-typos" { }
      ''
        echo "PASS settings-typed-tree-refuses-typos (unknown field refused; types checked)"
        touch "$out"
      '';

  # ── 25. The settings inventory matches the source it was derived from ─────
  #
  # lib/settings-inventory.json is what the settings-key guard reasons about.
  # If it goes stale, the guard starts refusing settings that upstream added
  # (or accepting ones it removed) — and it would do so quietly, because the
  # guard itself would still be "working".
  #
  # So the inventory is regenerated from the source and compared, in the build,
  # by the same script that produced it. A mismatch fails the build with the
  # command to fix it.
  settingsInventoryFresh =
    pkgs:
    pkgs.runCommand "sillytavern-check-settings-inventory-fresh"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        # The generator resolves the repository root from its own location, so
        # the layout has to be reproduced rather than flattened.
        mkdir -p scripts public default lib
        # Explicit target name: a store path's basename is hash-prefixed
        # (`<hash>-extract_settings_inventory.mjs`), so `cp src scripts/`
        # would land the file under that name and node would not find it.
        cp ${../scripts/extract_settings_inventory.mjs} scripts/extract_settings_inventory.mjs
        # `/.` — copying the directory itself would nest it (`public/public`),
        # because the target directory already exists.
        cp -r ${../public}/. public/
        cp -r ${../default}/. default/
        cp ${../lib/settings-inventory.json} lib/settings-inventory.json

        node scripts/extract_settings_inventory.mjs --check
        touch "$out"
      '';

  # ── presetsMatchUpstream — the named-profile buckets are upstream's ───────
  #
  # The `presets` option group is a set of claims about upstream: that the
  # Text Completion presets live in a directory called "TextGen Settings", that
  # the API id `textgenerationwebui` reads them, and so on.
  #
  # Every one of those claims is a DIRECTORY NAME, and a wrong one is
  # silent: the seeder writes the file, the account's directory is created,
  # and the server simply never shows it in the dropdown. There is no error
  # anywhere, and the only symptom is a preset that does not appear.
  #
  # So the claims are checked against upstream's own source rather than
  # trusted: `scripts/extract_preset_directories.mjs` reads
  # `USER_DIRECTORY_TEMPLATE` out of `src/constants.js` and the API id ->
  # directory switch out of `src/endpoints/presets.js`, and this check
  # compares that with the module's own table in `lib/default.nix`.
  #
  # An upstream rename fails the build instead of quietly emptying a
  # dropdown.
  presetsMatchUpstream =
    pkgs:
    pkgs.runCommand "sillytavern-check-presets-match-upstream"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        # The generator resolves the repository root from its own location, so
        # the layout has to be reproduced rather than flattened.
        mkdir -p scripts src/endpoints src public/scripts/extensions/quick-reply/src

        # Explicit target name: a store path's basename is hash-prefixed
        # (`<hash>-extract_preset_directories.mjs`), so `cp src scripts/`
        # would land the file under that name and node would not find it.
        cp ${../scripts/extract_preset_directories.mjs} scripts/extract_preset_directories.mjs

        # The upstream files the generator reads.
        cp ${../src/constants.js} src/constants.js
        cp ${../src/endpoints/presets.js} src/endpoints/presets.js
        cp ${../public/scripts/preset-manager.js} public/scripts/preset-manager.js
        cp ${../public/scripts/power-user.js} public/scripts/power-user.js
        cp ${../public/scripts/extensions/quick-reply/src/QuickReplySet.js} public/scripts/extensions/quick-reply/src/QuickReplySet.js

        # What the module believes, rendered from `lib/default.nix`.
        cat > expected.json <<'EOF'
        ${builtins.toJSON st.presetFacts}
        EOF

        node scripts/extract_preset_directories.mjs --check expected.json
        touch "$out"
      '';

  # ── presetsRendered — the named-profile layer reaches the data root ───────
  #
  # `presets` is a layer over `files`: a bucket and a name become a path, and
  # for the buckets whose dropdown label comes from inside the JSON, a `name`
  # field is filled in.
  #
  # Both halves are easy to get subtly wrong, and both are silent:
  #
  #   * A path that is one directory off produces a file the server never
  #     reads, and the dropdown is simply empty.
  #   * A missing `name` produces a preset that appears in the dropdown as
  #     "undefined".
  #
  # So the rendered seed spec is compared against the expected paths and the
  # expected content, here.
  presetsRendered =
    pkgs:
    let
      spec = (evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          config.enableUserAccounts = true;
          presets.common = {
            # A label-from-content bucket: the `name` is injected.
            instruct."Alpaca".json = {
              identifier = "alpaca";
              content = "IN";
            };
            themes."Azure".json = {
              blur_strength = 11;
            };
            # A label-from-file bucket: the `name` must NOT be injected, or
            # the file would carry a field upstream does not put there.
            textGeneration."Fast".json = {
              temperature = 0.9;
            };
            worlds."Lore".json = {
              entries = { };
            };
          };
          presets.byUser.seanc = {
            sysprompt."Roleplay".json = {
              content = "Write {{char}} as {{user}} would.";
            };
          };
        };
      }).config.services.sillytavern-nixos.internal.seedSpecJson;

      commonFiles = spec.users."default-user".files;
      userFiles = spec.users.seanc.files;

      expectedCommonPaths = [
        "TextGen Settings/Fast.json"
        "instruct/Alpaca.json"
        "themes/Azure.json"
        "worlds/Lore.json"
      ];
      actualCommonPaths = builtins.attrNames commonFiles;

      # The `name` field, present exactly where the label comes from the
      # content and absent where it comes from the file name.
      injectsName = builtins.attrNames (
        lib.filterAttrs (_: entry: entry.json != null && (entry.json ? name)) commonFiles
      );
      expectedInjectsName = [
        "instruct/Alpaca.json"
        "themes/Azure.json"
      ];
    in
    assert lib.sort (a: b: a < b) actualCommonPaths == lib.sort (a: b: a < b) expectedCommonPaths;
    assert lib.sort (a: b: a < b) injectsName == lib.sort (a: b: a < b) expectedInjectsName;
    # The per-account override REACHES that account, on top of the common
    # ones — `presets.common` applies to every account, exactly as
    # `files.common` does.
    assert lib.sort (a: b: a < b) (builtins.attrNames userFiles)
      == lib.sort (a: b: a < b) (expectedCommonPaths ++ [ "sysprompt/Roleplay.json" ]);
    assert commonFiles."instruct/Alpaca.json".json.name == "Alpaca";
    assert commonFiles."themes/Azure.json".json.name == "Azure";
    assert !(commonFiles."TextGen Settings/Fast.json".json ? name);
    pkgs.runCommand "sillytavern-check-presets-rendered" { }
      ''
        echo "PASS presets-rendered (${toString (builtins.length expectedCommonPaths)} paths, name injected where the label comes from the content)"
        touch "$out"
      '';

  hardeningPinned =
    pkgs:
    let
      system = evalSystem pkgs { services.sillytavern-nixos.enable = true; };
      sc = system.config.systemd.services.sillytavern.serviceConfig;

      # directive -> the exact value that must be set. Anything not listed here
      # is not pinned, which is the honest state of the block.
      expected = {
        # Filesystem
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        # Processes
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        NoNewPrivileges = true;
        LockPersonality = true;
        # `MemoryDenyWriteExecute` is deliberately NOT here — see `forbidden`.
        # Capabilities
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";
        # Syscalls
        SystemCallErrorNumber = "EPERM";
        # Empty on purpose: the jimp image pipeline is pure JS, so no capability
        # is needed for anything this server does.
        CapabilityBoundingSet = [ ];
        AmbientCapabilities = [ ];
        # Only the three a networked Node process needs — no Bluetooth, no
        # packet sockets, no netlink.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        # `@system-service` minus the privileged and resources groups.
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      };

      # Normalised because `unitOption.merge` CONCATENATES list-valued
      # definitions (`attrsOf unitOption` wraps each in `concatMap`), so a single
      # definition of `[ ]` reads back as `[ [ ] ]`. Flattening both sides makes
      # the comparison uniform across scalars and lists.
      flat =
        x:
        if builtins.isList x && x != [ ] && builtins.isList (builtins.head x) then
          lib.concatLists x
        else
          x;

      missing = builtins.filter (k: !(sc ? ${k})) (builtins.attrNames expected);
      wrong = builtins.filter (k: flat sc.${k} != flat expected.${k}) (builtins.attrNames expected);

      # Directives that must NOT be set, each with the reason. `expected` alone
      # cannot catch a directive being ADDED, and that is exactly how
      # `MemoryDenyWriteExecute` got in: it reads as hardening, and it is fatal
      # to any JIT runtime. The module also asserts this on the RENDERED unit
      # (see `moduleEvaluates`), because a consumer can re-add it through
      # `systemdOverrides` without this attrset ever seeing it.
      forbidden = {
        # Node's V8 allocates W+X pages for its JIT, so the directive makes
        # mprotect fail and the process aborts with SIGTRAP at isolate init
        # (`v8::base::OS::SetPermissions` → `CodeRange::InitReservation` →
        # `node::NewIsolate`). The unit then restart-loops. The JVM and .NET are
        # in the same position.
        MemoryDenyWriteExecute = "crash-loops node/V8 (SIGTRAP at isolate init)";
      };

      forbiddenSet = builtins.filter (k: sc ? ${k}) (builtins.attrNames forbidden);
    in
    # An eval-time failure naming every offender, rather than a shell one.
    assert lib.assertMsg (missing == [ ]) ''
      hardening-pinned: directive(s) missing from the unit: ${
        lib.concatStringsSep ", " missing
      }'';
    assert lib.assertMsg (wrong == [ ]) ''
      hardening-pinned: directive(s) set to the wrong value: ${
        lib.concatStringsSep ", " wrong
      }'';
    assert lib.assertMsg (forbiddenSet == [ ]) ''
      hardening-pinned: directive(s) that must not be set: ${
        lib.concatStringsSep ", " (map (k: "${k} — ${forbidden.${k}}") forbiddenSet)
      }'';
    pkgs.runCommand "sillytavern-check-hardening-pinned" { }
      ''
        echo "PASS hardening-pinned (${toString (builtins.length (builtins.attrNames expected))} directives)"
        touch "$out"
      '';

  # ── Locally-run models ─────────────────────────────────────────────────────
  #
  # SillyTavern runs SOME models itself — the transformers.js ONNX weights
  # behind the extensions — and upstream fetches them from HuggingFace on
  # first use into `<dataRoot>/_cache`, a path it hardcodes
  # (`src/transformers.js:134`).
  #
  # The module gives that path two ways out, and this check proves the
  # load-bearing one actually happened: a model declared in `models.byId` is
  # INSTALLED INTO THE PACKAGE, at the path transformers.js searches second
  # (`localModelPath`, `src/env.js` in the `sillytavern-transformers`
  # package):
  #
  #   <package>/node_modules/sillytavern-transformers/models/<model id>/
  #
  # which is `<package>/node_modules/sillytavern-transformers/models/` — the
  # package's own directory, so the weights are in the store, in the package's
  # closure, and garbage collected with it.
  #
  # This check reads the BUILT package, because the whole point is that the
  # file is where transformers.js will look: an option that renders but does
  # not install would leave the server downloading the model at runtime, into a
  # directory the operator did not choose.
  modelsByIdInstalled =
    pkgs:
    let
      # A stand-in for a model: one file, in the layout transformers.js asks
      # for. The real thing is hundreds of MiB of ONNX weights, and the check
      # is about WHERE the file lands, not what is in it.
      model = pkgs.writeTextDir "config.json" "{}";

      system = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          models.byId."Xenova/whisper-small" = model;
        };
      };
      packaged = system.config.services.sillytavern-nixos.internal.packaged;
    in
    pkgs.runCommand "sillytavern-check-models-installed"
      {
        nativeBuildInputs = [
          pkgs.coreutils
        ];
      }
      ''
        fail() {
          echo "FAIL models-installed: $1" >&2
          exit 1
        }

        link="${packaged}/node_modules/sillytavern-transformers/models/Xenova/whisper-small"

        # A SYMLINK, not a copy: the weights stay one store path, and the
        # package's closure says so.
        [ -L "$link" ] || fail "$link is not a symlink"
        [ "$(readlink "$link")" = "${model}" ] \
          || fail "$link points at $(readlink "$link"), expected ${model}"

        # And it is readable THROUGH the link, which is how transformers.js
        # will read it.
        [ -f "$link/config.json" ] || fail "$link/config.json is not readable"

        echo "PASS models-installed (a Nix-declared model is installed in the package)"
        touch "$out"
      '';

  # The model's DATA DIRECTORY, and the one thing that must follow from it.
  #
  # `models.directory` points upstream's hardcoded cache path
  # (`<dataRoot>/_cache`) at a directory the operator chose. If that directory
  # is a STORE PATH it cannot be written to, and transformers.js downloads a
  # model it cannot find INTO the cache — so a read-only cache turns "the
  # model is not there" into an EROFS write error. The module forces
  # `extensions.models.autoDownload` off in that case, which turns it into the
  # clear "file not found locally".
  #
  # And the wiring has to be REAL: the unit's preStart has to run the linker
  # with the right target, or the cache is never pointed anywhere and the
  # option does nothing.
  modelDirectoryWiring =
    pkgs:
    let
      # A store path: read-only, so `autoDownload` must be forced off.
      storeDirectory = pkgs.writeTextDir "Xenova/whisper-small/config.json" "{}";

      # A plain path: writable, so downloads must still be allowed — and the
      # literal string can be searched for in the unit (a STORE PATH cannot:
      # Nix refuses to put one in a regular expression, which is what
      # `lib.hasInfix` uses).
      plainDirectory = "/var/lib/sillytavern-models";

      withStore = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          models.directory = storeDirectory;
        };
      };
      withPlain = evalSystem pkgs {
        services.sillytavern-nixos = {
          enable = true;
          models.directory = plainDirectory;
        };
      };
      withoutModels = evalSystem pkgs { services.sillytavern-nixos.enable = true; };

      storeCfg = withStore.config.services.sillytavern-nixos;
      plainCfg = withPlain.config.services.sillytavern-nixos;
      plainPreStart = withPlain.config.systemd.services.sillytavern.preStart;
    in
    # The cache directory is handed to the unit, not merely remembered.
    assert storeCfg.internal.modelCacheDir == storeDirectory;
    # And a read-only cache turns autoDownload off.
    assert storeCfg.internal.effectiveConfig.extensions.models.autoDownload == false;
    # A writable one does not: the server can still download a model it does
    # not find locally.
    assert plainCfg.internal.effectiveConfig.extensions.models.autoDownload == true;
    # Without a directory at all, upstream's own value stands — the rendered
    # config.yaml must stay a faithful copy of upstream's document.
    assert withoutModels.config.services.sillytavern-nixos.internal.effectiveConfig.extensions.models.autoDownload == true;
    # The linker runs before the server, with the target.
    assert lib.hasInfix "st_link_models.py" withStore.config.systemd.services.sillytavern.preStart;
    assert lib.hasInfix plainDirectory plainPreStart;
    # And it does NOT run when there is nothing to point at.
    assert !(lib.hasInfix "st_link_models.py" withoutModels.config.systemd.services.sillytavern.preStart);
    pkgs.runCommand "sillytavern-check-model-directory-wiring" { }
      ''
        echo "PASS model-directory-wiring (the cache is pointed at the configured directory)"
        touch "$out"
      '';

  # ── llama.cpp server ───────────────────────────────────────────────────────
  #
  # The backend is a separate module, so these evaluate it WITHOUT the
  # SillyTavern module. That is the cross-module independence the design
  # promises, and it is also what makes the check cheap.
  llamaPresetRendered =
    pkgs:
    let
      apiKey = pkgs.writeText "llama-api-key" "not-a-real-key";
      storeWeights = pkgs.writeText "model-a.gguf" "not a real gguf";
      plainWeights = "/var/lib/llama/model-b.gguf";
      system = evalLlama pkgs {
        services.llama-cpp-nixos = {
          enable = true;
          apiKeyFile = apiKey;
          models."model/a" = {
            weights.path = storeWeights;
            ctxSize = 16384;
            primary = true;
            args = {
              ngl = "all";
              np = 2;
              "chat-template" = "gemma";
              jinja = true;
            };
          };
          models."model-b" = {
            weights.path = plainWeights;
            ctxSize = 8192;
          };
          globalArgs = { c = 4096; };
        };
      };
      cfg = system.config.services.llama-cpp-nixos;
      ini = cfg.internal.modelsPreset;
      unit = system.config.systemd.services.llama-cpp-nixos;
    in
    assert lib.hasInfix "version = 1" ini;
    assert lib.hasInfix "[*]" ini;
    assert lib.hasInfix "[model/a]" ini;
    assert lib.hasInfix "[model-b]" ini;
    assert lib.hasInfix "c = 16384" ini;
    assert lib.hasInfix "c = 8192" ini;
    assert lib.hasInfix "load-on-startup = true" ini;
    assert lib.hasInfix "load-on-startup = false" ini;
    assert lib.hasInfix "ngl = all" ini;
    assert lib.hasInfix "np = 2" ini;
    assert lib.hasInfix "chat-template = gemma" ini;
    assert lib.hasInfix "jinja = true" ini;
    # A plain path, not a store path: `lib.hasInfix` refuses a store path in
    # its regular expression (see RUN-LOG). The store-backed model is covered
    # by the section assertion above.
    assert lib.hasInfix "model = ${plainWeights}" ini;
    # The unit is wired to the rendered file, not merely aware of it.
    assert unit.environment.LLAMA_ARG_MODELS_PRESET == cfg.internal.presetFile;
    assert unit.environment.LLAMA_ARG_HOST == "127.0.0.1";
    assert unit.environment.LLAMA_ARG_PORT == "9931";
    assert unit.environment.LLAMA_CACHE == "/var/lib/llama-cpp/cache";
    assert unit.serviceConfig.StateDirectory == "llama-cpp";
    assert unit.serviceConfig.User == "llama-cpp";
    assert unit.serviceConfig.LoadCredential == "api-key:${toString apiKey}";
    pkgs.runCommand "sillytavern-check-llama-preset" { }
      ''
        echo "PASS llama-preset (sections, context, eager primary, credential)"
        touch "$out"
      '';

  llamaAssertions =
    pkgs:
    let
      failures =
        llamaConfig:
        let
          system = evalLlama pkgs { services.llama-cpp-nixos = llamaConfig; };
        in
        builtins.filter (
          a: !a.assertion && lib.hasInfix "services.llama-cpp-nixos:" (a.message or "")
        ) system.config.assertions;
      count = llamaConfig: builtins.length (failures llamaConfig);
      model = extra: {
        weights.path = "/var/lib/llama/m.gguf";
        primary = true;
      } // extra;
      base = {
        enable = true;
        models."m" = model { };
      };
    in
    assert count base == 0;
    # No primary.
    assert count (base // { models."m" = model { primary = false; }; }) == 1;
    # Two primaries.
    assert count (base // { models = { "m" = model { }; "m2" = model { }; }; }) == 1;
    # Both weights sources.
    assert count (
      base
      // {
        models."m" = model {
          weights = {
            path = "/var/lib/llama/m.gguf";
            url = "https://example.invalid/m.gguf";
            hash = "sha256-0000000000000000000000000000000000000000000=";
          };
        };
      }
    ) == 1;
    # Neither weights source.
    assert count (base // { models."m" = model { weights = { }; }; }) == 1;
    # A reserved key in `args`.
    assert count (base // { models."m" = model { args = { c = 4096; }; }; }) == 1;
    # `model` in the global section.
    assert count (base // { globalArgs = { model = "/var/lib/llama/m.gguf"; }; }) == 1;
    # An id that would break the INI structure.
    assert count (
      base // { models = { "bad]id" = model { }; "m" = model { primary = false; }; }; }
    ) == 1;
    pkgs.runCommand "sillytavern-check-llama-assertions" { }
      ''
        echo "PASS llama-assertions (primary, weights, reserved keys, section names)"
        touch "$out"
      '';

  # ── Model layers (SillyTavern side) ────────────────────────────────────────
  stModelLayerSystem =
    pkgs: modelLayers:
    evalSystem pkgs {
      services.sillytavern-nixos = {
        enable = true;
        config.enableUserAccounts = true;
        users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
        inherit modelLayers;
      };
    };

  # Only the model-layer assertions. A valid config can still fail unrelated
  # module assertions (there is no authentication configured in this minimal
  # system), so filtering by the subject is what makes "good == []" meaningful.
  stModelLayerFailures =
    pkgs: modelLayers:
    builtins.filter (
      a: !a.assertion && lib.hasInfix "services.sillytavern-nixos: modelLayers:" (a.message or "")
    ) (stModelLayerSystem pkgs modelLayers).config.assertions;

  modelLayersPrecedence =
    pkgs:
    let
      system = stModelLayerSystem pkgs {
        enable = true;
        catalog."m1" = {
          contextSize = 16384;
          connection = {
            url = "http://127.0.0.1:9931/v1";
            model = "m1";
          };
          presets.openai = {
            temp_openai = 0.5;
            top_p_openai = 0.9;
          };
        };
        byUser.seanc.models."m1".presets.openai = {
          temp_openai = 0.7;
        };
        byUser.seanc.models."m1".characters."Aria".presets.openai = {
          temp_openai = 0.9;
        };
      };
      files = system.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.files;
      modelPreset = files."OpenAI Settings/m1.json".json;
      charPreset = files."OpenAI Settings/m1 ~ Aria.json".json;
    in
    # PER MODEL: the catalogue value applies.
    # PER USER: the user's leaf wins, and the sibling it did not restate
    # survives (this is a DEEP merge, not `//`).
    assert modelPreset.temp_openai == 0.7;
    assert modelPreset.top_p_openai == 0.9;
    assert modelPreset.openai_max_context == 16384;
    # PER CHARACTER: the character's leaf wins over the user's.
    assert charPreset.temp_openai == 0.9;
    assert charPreset.top_p_openai == 0.9;
    assert charPreset.openai_max_context == 16384;
    pkgs.runCommand "sillytavern-check-model-layers-precedence" { }
      ''
        echo "PASS model-layers-precedence (catalog -> user -> character)"
        touch "$out"
      '';

  modelLayersFiles =
    pkgs:
    let
      system = stModelLayerSystem pkgs {
        enable = true;
        catalog."m1" = {
          contextSize = 16384;
          connection = {
            url = "http://127.0.0.1:9931/v1";
            model = "m1";
          };
          presets = {
            openai = { temp_openai = 0.5; };
            instruct = { input_sequence = "<|user|>"; };
          };
        };
        byUser.seanc.models."m1".characters."Aria" = { };
      };
      files = system.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.files;
      manifest = files."user/files/st-model-layers.json";
    in
    # Presets are user-editable: create-only.
    assert files."OpenAI Settings/m1.json".policy == "missing";
    assert files."instruct/m1.json".policy == "missing";
    # The advanced bucket gets its label injected, as every other preset does.
    assert files."instruct/m1.json".json.name == "m1";
    # Empty buckets are not emitted.
    assert !(files ? "context/m1.json");
    # The manifest is DERIVED state: it must be rewritten, or a stale one
    # would describe models that no longer exist.
    assert manifest.policy == "overwrite";
    assert manifest.json.version == 1;
    assert manifest.json.models.m1.connection.id == st.modelLayers.profileId "m1";
    assert manifest.json.models.m1.connection.model == "m1";
    assert manifest.json.models.m1.presets.openai == "m1";
    assert manifest.json.models.m1.characters.Aria.openai == "m1 ~ Aria";
    assert files ? "OpenAI Settings/m1 ~ Aria.json";
    # The connection is rendered INTO the preset body. An account has ONE
    # `oai_settings`, so this is the only per-model slot upstream has: selecting
    # the preset is then what points the account at this model's backend
    # (`onSettingsPresetChange`, gated by the global `bind_preset_to_connection`,
    # whose upstream default is true).
    assert files."OpenAI Settings/m1.json".json.chat_completion_source == "custom";
    assert files."OpenAI Settings/m1.json".json.custom_url == "http://127.0.0.1:9931/v1";
    assert files."OpenAI Settings/m1.json".json.custom_model == "m1";
    # Character variants carry it too — without it, switching to a character
    # variant would silently keep whatever backend the account already had.
    assert files."OpenAI Settings/m1 ~ Aria.json".json.custom_url == "http://127.0.0.1:9931/v1";
    assert files."OpenAI Settings/m1 ~ Aria.json".json.custom_model == "m1";
    pkgs.runCommand "sillytavern-check-model-layers-files" { }
      ''
        echo "PASS model-layers-files (artifact paths, policies, manifest, connection)"
        touch "$out"
      '';

  # `connection.*` is the single declarative source of the endpoint, so a
  # hand-written connection key in any layer must be refused rather than
  # silently dropped. Mirrors `modelLayersContextSize`.
  modelLayersConnection =
    pkgs:
    let
      base = {
        enable = true;
        catalog."m1" = {
          contextSize = 16384;
          connection = {
            url = "http://127.0.0.1:9931/v1";
            model = "m1";
          };
          presets.openai = { temp_openai = 0.5; };
        };
      };
      catalogConflict = base // {
        catalog."m1" = base.catalog."m1" // {
          presets.openai.custom_url = "http://wrong.invalid:1/v1";
        };
      };
      userConflict = base // {
        byUser.seanc.models."m1".presets.openai.custom_model = "wrong-model";
      };
      charConflict = base // {
        byUser.seanc.models."m1".characters."Aria".presets.openai.chat_completion_source = "openai";
      };
    in
    assert stModelLayerFailures pkgs base == [ ];
    assert builtins.length (stModelLayerFailures pkgs catalogConflict) >= 1;
    assert builtins.length (stModelLayerFailures pkgs userConflict) >= 1;
    assert builtins.length (stModelLayerFailures pkgs charConflict) >= 1;
    pkgs.runCommand "sillytavern-check-model-layers-connection" { }
      ''
        echo "PASS model-layers-connection (connection rendered, drift refused)"
        touch "$out"
      '';

  modelLayersStableIds =
    pkgs:
    let
      a = st.modelLayers.profileId "a/b";
      b = st.modelLayers.profileId "a:b";
    in
    assert lib.hasPrefix "st-nix-a-b-" a;
    # The slug alone collapses `/` and `:` to the same string; the digest is
    # what keeps two models from sharing one profile.
    assert a != b;
    assert st.modelLayers.profileId "a/b" == a;
    pkgs.runCommand "sillytavern-check-model-layers-stable-ids" { }
      ''
        echo "PASS model-layers-stable-ids (stable and collision-free)"
        touch "$out"
      '';

  modelLayersCharacterNames =
    pkgs:
    let
      good = {
        "Aria" = { };
        "Aria Chen" = { };
        "Aria (v2)" = { };
        "Aria's" = { };
      };
      base = {
        enable = true;
        catalog."m1" = {
          connection = {
            url = "http://127.0.0.1:9931/v1";
            model = "m1";
          };
        };
      };
      withChars = characters: base // { byUser.seanc.models."m1".characters = characters; };
      goodSystem = stModelLayerSystem pkgs (withChars good);
      goodFiles = goodSystem.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.files;
      bad = stModelLayerFailures pkgs (withChars { "A/B" = { }; });
      dot = stModelLayerFailures pkgs (withChars { "." = { }; });
      space = stModelLayerFailures pkgs (withChars { " Aria" = { }; });
    in
    assert stModelLayerFailures pkgs (withChars good) == [ ];
    assert builtins.length bad >= 1;
    assert builtins.length dot >= 1;
    assert builtins.length space >= 1;
    # A legal name with a space produces a real, readable file.
    assert goodFiles ? "OpenAI Settings/m1 ~ Aria Chen.json";
    pkgs.runCommand "sillytavern-check-model-layers-character-names" { }
      ''
        echo "PASS model-layers-character-names (safe names accepted, unsafe refused)"
        touch "$out"
      '';

  modelLayersContextSize =
    pkgs:
    let
      base = {
        enable = true;
        catalog."m1" = {
          contextSize = 16384;
          connection = {
            url = "http://127.0.0.1:9931/v1";
            model = "m1";
          };
        };
      };
      files = (stModelLayerSystem pkgs base).config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.files;
      catalogConflict = base // {
        catalog."m1" = base.catalog."m1" // {
          presets.openai.openai_max_context = 8192;
        };
      };
      userConflict = base // {
        byUser.seanc.models."m1".presets.openai.openai_max_context = 8192;
      };
      charConflict = base // {
        byUser.seanc.models."m1".characters."Aria".presets.openai.openai_max_context = 8192;
      };
    in
    # Generated, not hand-written.
    assert files."OpenAI Settings/m1.json".json.openai_max_context == 16384;
    # And a hand-written disagreement is refused in every layer.
    assert builtins.length (stModelLayerFailures pkgs catalogConflict) >= 1;
    assert builtins.length (stModelLayerFailures pkgs userConflict) >= 1;
    assert builtins.length (stModelLayerFailures pkgs charConflict) >= 1;
    pkgs.runCommand "sillytavern-check-model-layers-context-size" { }
      ''
        echo "PASS model-layers-context-size (openai_max_context cannot drift)"
        touch "$out"
      '';

  # The two modules are independent by design, so the model id and the context
  # size are a CONTRACT rather than a cross-module read. This is the check that
  # pins it: one system, both modules, the same id and the same number, and the
  # number appears in BOTH artifacts — `openai_max_context` in the preset and
  # `c` in the llama.cpp INI section. It also proves the two modules can be
  # enabled together without an option or unit collision.
  modelLayersContextMatchesBackend =
    pkgs:
    let
      system = evalWith pkgs [
        {
          services.llama-cpp-nixos = {
            enable = true;
            models."m1" = {
              weights.path = "/var/lib/llama/m1.gguf";
              ctxSize = 16384;
              primary = true;
            };
          };
          services.sillytavern-nixos = {
            enable = true;
            config.enableUserAccounts = true;
            users.seanc.passwordFile = pkgs.writeText "pw" "not-a-real-password";
            modelLayers = {
              enable = true;
              catalog."m1" = {
                contextSize = 16384;
                connection = {
                  url = "http://127.0.0.1:9931/v1";
                  model = "m1";
                };
              };
            };
          };
        }
        ../modules/llama.nix
        modulePath
      ];
      stFiles = system.config.services.sillytavern-nixos.internal.seedSpecJson.users.seanc.files;
      ini = system.config.services.llama-cpp-nixos.internal.modelsPreset;
    in
    assert stFiles."OpenAI Settings/m1.json".json.openai_max_context == 16384;
    assert lib.hasInfix "[m1]" ini;
    assert lib.hasInfix "c = 16384" ini;
    pkgs.runCommand "sillytavern-check-model-layers-context-matches-backend" { }
      ''
        echo "PASS model-layers-context-matches-backend (preset and INI agree)"
        touch "$out"
      '';

  # The flake's own package set allows unfree so the CUDA variant this project
  # targets is usable. This check proves the seam end to end: the attribute
  # evaluates, and the module accepts it as `package` without touching the
  # module's default (a CPU build remains the portable default).
  llamaCudaVariantAvailable =
    pkgs:
    let
      cuda = pkgs.llama-cpp-cuda;
      system = evalLlama pkgs {
        services.llama-cpp-nixos = {
          enable = true;
          package = cuda;
          models."m" = {
            weights.path = "/var/lib/llama/m.gguf";
            primary = true;
          };
        };
      };
    in
    assert lib.isDerivation cuda;
    assert system.config.services.llama-cpp-nixos.package == cuda;
    pkgs.runCommand "sillytavern-check-llama-cuda-variant" { }
      ''
        echo "PASS llama-cuda-variant (unfree package set, selectable package)"
        touch "$out"
      '';

  checks =
    pkgs:
    {
      packageIdentity = packageIdentity pkgs;
      moduleEvaluates = moduleEvaluates pkgs;
      configYamlRoundTrip = configYamlRoundTrip pkgs;
      browserLaunchDisabled = browserLaunchDisabled pkgs;
      publicDirectoriesPresent = publicDirectoriesPresent pkgs;
      secretsExcluded = secretsExcluded pkgs;
      guardsFire = guardsFire pkgs;
      seedSpecCoversCommon = seedSpecCoversCommon pkgs;
      customCssIsolated = customCssIsolated pkgs;
      errorPagesIsolated = errorPagesIsolated pkgs;
      pluginsAndExtensionsAreUsable = pluginsAndExtensionsAreUsable pkgs;
      hardwareCapsApplied = hardwareCapsApplied pkgs;
      upstreamCollisionAsserted = upstreamCollisionAsserted pkgs;
      assertionsDisabledCleanly = assertionsDisabledCleanly pkgs;
      noCrossModuleReads = noCrossModuleReads pkgs;
      seeder = seeder pkgs;
      systemdOverridesMerge = systemdOverridesMerge pkgs;
      wantedByIsSet = wantedByIsSet pkgs;
      perFilePolicyAndMode = perFilePolicyAndMode pkgs;
      reservedPathsAsserted = reservedPathsAsserted pkgs;
      filesByUserEvaluates = filesByUserEvaluates pkgs;
      settingsDeepMerge = settingsDeepMerge pkgs;
      settingsExtraRendered = settingsExtraRendered pkgs;
      settingsExtraMergeOrder = settingsExtraMergeOrder pkgs;
      settingsKeysKnown = settingsKeysKnown pkgs;
      settingsTypedTree = settingsTypedTree pkgs;
      settingsTypedTreeRefusesTypos = settingsTypedTreeRefusesTypos pkgs;
      settingsInventoryFresh = settingsInventoryFresh pkgs;
      presetsMatchUpstream = presetsMatchUpstream pkgs;
      presetsRendered = presetsRendered pkgs;
      hardeningPinned = hardeningPinned pkgs;
      libHelpers = libHelpers pkgs;
      modelsByIdInstalled = modelsByIdInstalled pkgs;
      modelDirectoryWiring = modelDirectoryWiring pkgs;
      llamaPresetRendered = llamaPresetRendered pkgs;
      llamaAssertions = llamaAssertions pkgs;
      modelLayersPrecedence = modelLayersPrecedence pkgs;
      modelLayersFiles = modelLayersFiles pkgs;
      modelLayersStableIds = modelLayersStableIds pkgs;
      modelLayersCharacterNames = modelLayersCharacterNames pkgs;
      modelLayersContextSize = modelLayersContextSize pkgs;
      modelLayersConnection = modelLayersConnection pkgs;
      modelLayersContextMatchesBackend = modelLayersContextMatchesBackend pkgs;
      llamaCudaVariantAvailable = llamaCudaVariantAvailable pkgs;
    };

  packages = pkgs: { };
}
