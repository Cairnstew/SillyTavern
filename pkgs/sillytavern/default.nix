# pkgs/sillytavern/default.nix
#
# `pkgs.sillytavern` — the SillyTavern server, built from this repository.
#
# ── Why this is a two-stage build ─────────────────────────────────────────────
#
# SillyTavern is a Node application with a committed `package-lock.json`
# (lockfileVersion 3, so the full transitive tree is pinned with integrity
# hashes). Reproducing `node_modules` needs the npm registry, which is exactly
# what a fixed-output derivation is for:
#
#   nodeModules   FOD, runs `npm ci`, output pinned by a NAR hash. This is the
#                 only impure step, and the hash makes its output verifiable.
#   sillytavern   ordinary derivation. Copies the filtered source and links the
#                 FOD's node_modules in. Runs no network access at all.
#
# Doing this as ONE fixed-output derivation would also work, but then the hash
# covers the assembled package too, so any change to what we install — a new
# file, a wrapper edit — invalidates a hash that has nothing to do with
# dependency resolution.
#
# ── Why `--omit=dev` and `--ignore-scripts` ───────────────────────────────────
#
# `.npmrc` in the repository root already sets `ignore-scripts=true`, and the
# Dockerfile passes `--omit=dev --ignore-scripts` as well. We pass both
# explicitly rather than relying on `.npmrc` being present in the filtered
# source, because a silent switch to "run install scripts" would turn the build
# into an arbitrary-code-execution surface with no hash protecting it.
#
# devDependencies are excluded: they are the ESLint/TypeScript/Playwright
# toolchain, none of which the server loads at runtime. `webpack` is NOT a
# devDependency — see the note in the wrapper below for why that matters.
#
# ── What the server writes at runtime, and why that is not our problem ────────
#
# The server recompiles its frontend library bundle on EVERY start
# (`await webpackMiddleware.runWebpackCompiler(...)` in src/server-main.js) into
# `$DATA_ROOT/_webpack/<cacheVersion>/output/lib.js`. That is why:
#
#   * `webpack` must be a production dependency, and it is;
#   * the data root has to be WRITABLE at runtime — the module gives it a
#     systemd `StateDirectory`, not a store path;
#   * there is nothing to pre-bake here. The Dockerfile pre-bakes with
#     `docker/build-lib.js`, but that only warms the cache for the image's own
#     first start; doing it at build time would cost a webpack run in the
#     sandbox and be overwritten on the first real start anyway.
#
# The consequence for operators is that startup is not instant, which the
# module surfaces as `services.sillytavern-nixos.startupTimeout` and, if
# `config.heartbeatInterval` is non-zero, as a working systemd healthcheck via
# `src/healthcheck.js`.
{
  lib,
  stdenvNoCC,
  nodejs,
  writeShellApplication,
  fetchgit,
  src ? null,
  version ? "1.19.0",
  # The NAR hash of `node ci` against this repository's package-lock.json.
  # Changing the lockfile, or bumping nixpkgs' npm, changes it — re-derive with
  # `nix build .#sillytavern` and read the "got:" line out of the error.
  nodeModulesHash ? "sha256-c1DYkaY0sN4USmQIIF5uj0StiVFnk7/J3rtwDq1VT8o=",
  # A PEM bundle of extra certificate authorities for the `npm ci` step.
  #
  # Needed on any network that intercepts TLS — a corporate proxy, a CI runner
  # with a custom root, a Nix builder behind a filtering middlebox. Node does NOT
  # read the system CA store; it uses the bundle compiled into the binary, so
  # `curl` and `git` can both succeed while `npm` fails with
  # UNABLE_TO_GET_ISSUER_CERT_LOCALLY. Point this at the system bundle:
  #
  #   caCertFile = /etc/ssl/certs/ca-certificates.crt;
  #
  # It is an INPUT to the fixed-output hash's derivation, not a secret, and null
  # (the default) leaves Node's own trust store in place.
  caCertFile ? null,
  ...
}:

let
  # The application source. `src` is the filtered checkout (see source.nix);
  # `fetchgit` is the escape hatch for building a specific upstream revision
  # from a consumer who does not have this repository checked out.
  source =
    if src != null then
      src
    else
      fetchgit {
        url = "https://github.com/Cairnstew/SillyTavern.git";
        rev = "release";
        # Pinned at lock time; see the flake's `sillytavern` input.
        hash = lib.fakeHash;
      };

  # ── Stage 1: node_modules ───────────────────────────────────────────────────
  nodeModules =
    stdenvNoCC.mkDerivation {
      pname = "sillytavern-node-modules";
      inherit version;

      # Only package.json and package-lock.json matter here, but the whole
      # filtered source is cheap to make available and `npm ci` refuses to run
      # in a directory that has no lockfile.
      src = source;

      # `nodejs` ships npm in the same directory and puts it on PATH, so there
      # is no separate `npm` argument: nixpkgs has no top-level `npm`
      # attribute, and mixing a bundled npm with a separately-packaged nodejs is
      # how you get "npm ci" failing on a lockfileVersion its own npm cannot read.
      nativeBuildInputs = [ nodejs ];

      # `npm ci` deletes and reinstalls node_modules from the lockfile, so the
      # source only has to be present, not pristine.
      dontConfigure = true;
      dontBuild = true;

      installPhase = ''
        runHook preInstall

        # npm needs a writable HOME for its cache and its debug logs, and
        # $TMPDIR is the only writable place inside the sandbox.
        export HOME="$TMPDIR"

        ${lib.optionalString (caCertFile != null) ''
          # See the `caCertFile` argument. Node does NOT read the system CA
          # store -- it uses the bundle compiled into the binary -- so without
          # this `npm ci` fails with UNABLE_TO_GET_ISSUER_CERT_LOCALLY on any
          # network that intercepts TLS, even though curl and git work.
          export NODE_EXTRA_CA_CERTS="${caCertFile}"
        ''}

        # `npm ci` installs into ./node_modules relative to the CWD and insists
        # on finding package.json and package-lock.json there, so the build runs
        # in a scratch directory holding just those three files (plus .npmrc,
        # which carries upstream's own `ignore-scripts=true` and
        # `min-release-age=7`). Installing directly into $out would need them
        # copied into the store path first, which mixes inputs and outputs.
        mkdir -p "$TMPDIR/build"
        cp package.json package-lock.json .npmrc "$TMPDIR/build/"
        cd "$TMPDIR/build"

        # --omit=dev drops the ESLint/TypeScript/Playwright toolchain, none of
        # which the server loads. --ignore-scripts is belt-and-braces: .npmrc
        # already sets it, and running an install script would turn this into an
        # arbitrary-code-execution surface with only a NAR hash protecting it.
        npm ci \
          --omit=dev \
          --ignore-scripts \
          --no-audit \
          --no-fund \
          --no-progress \
          --loglevel=error

        mkdir -p "$out"
        mv node_modules "$out/node_modules"

        runHook postInstall
      '';

      # `dontFixup` is load-bearing for hash stability.
      #
      # A fixed-output derivation's hash covers its output AFTER fixupPhase, and
      # fixupPhase's `patchShebangs` rewrites `#!/bin/sh` into the *builder's*
      # bash store path (`/nix/store/…-bash-5.3p15/bin/sh`). That means bumping
      # bash in nixpkgs would change this hash even though nothing about the
      # dependency tree changed — a spurious "your lockfile is out of date"
      # failure on an unrelated nixpkgs upgrade.
      #
      # So the FOD emits npm's raw output, and the outer derivation (whose
      # output is not hash-pinned) does the shebang patching after copying it
      # in. `node_modules/.bin` shebangs end up correct either way, and the
      # server does not invoke those binaries anyway: it calls `webpack()`
      # programmatically rather than through the `webpack` CLI.
      dontFixup = true;

      outputHashMode = "recursive";
      # Filled in by the first `nix build`; `lib.fakeHash` makes Nix report the
      # hash it actually got. There is no honest way to guess this.
      outputHash = nodeModulesHash;

      outputHashAlgo = "sha256";

      # No `__noChroot` here: Nix relaxes the sandbox for a fixed-output
      # derivation on its own, and setting it explicitly is rejected outright
      # when `sandbox = true` ("has '__noChroot' set, but that's not allowed
      # when 'sandbox' is 'true'"). The registry fetch is the whole point of
      # being a FOD, and the output hash is what makes it verifiable.

      meta = {
        description = "node_modules for SillyTavern ${version} (fixed-output)";
        platforms = lib.platforms.unix;
      };
    };

  # ── The launchers ───────────────────────────────────────────────────────────
  #
  # `node server.js` on its own is not a runnable command worth shipping: it has
  # no `NODE_ENV`, no PATH, and no guard against the one flag that would put the
  # data root outside systemd's control.
  #
  # `writeShellApplication` gives `set -euo pipefail`, a pinned bash, and a
  # shellcheck pass ENFORCED AT BUILD TIME — so a broken launcher is a build
  # failure rather than a 3am surprise. (Inside `passthru`, which is a *nested*
  # attrset and therefore NOT self-recursive, these have to be bound in `let`.)
  #
  # ── Why the entrypoint is `$SILLYTAVERN_BIN_DIR/server.js` and not the source
  #    store path ─────────────────────────────────────────────────────────────
  #
  # It has to be inside `$out`. Node resolves `import 'yargs'` by walking UP from
  # the importing file's directory looking for `node_modules`, so running the
  # copy in the filtered source store path fails with ERR_MODULE_NOT_FOUND even
  # though `$out/node_modules` is fully populated — the source path is a
  # different directory tree with no node_modules anywhere above it.
  #
  # `SILLYTAVERN_BIN_DIR` overrides the location for a developer running the
  # launcher straight out of a build directory; unset, the launcher finds itself.
  #
  # It runs `server.js`, not `src/server-global.js` (which is what package.json's
  # `bin` field names): global mode resolves its config and data through XDG
  # directories and ignores both `--configPath` and `--dataRoot`, so it is
  # incompatible with a systemd `StateDirectory`. The module asserts
  # `cli.global = false` and this refuses the flag for the same reason.
  launcher =
    writeShellApplication {
      name = "sillytavern";
      runtimeInputs = [ nodejs ];
      text = ''
        # Baked in rather than added by `wrapProgram --set-default`: the
        # Dockerfile sets NODE_ENV=production too, and it is what makes
        # `src/util.js` skip its verbose debug paths.
        export NODE_ENV=production

        # Refuse global mode loudly rather than silently ignoring --dataRoot
        # and --configPath, which is what command-line.js does with them.
        for arg in "$@"; do
          case "$arg" in
            --global|--global=*)
              echo "sillytavern: --global is not supported by the Nix package." >&2
              echo "  It resolves config and data through XDG directories, ignoring" >&2
              echo "  --configPath and --dataRoot, so the data root cannot be a" >&2
              echo "  systemd StateDirectory." >&2
              echo "  Use services.sillytavern-nixos, or invoke the store path directly." >&2
              exit 2
              ;;
          esac
        done

        # Locate ourselves rather than relying on an environment variable.
        # `SILLYTAVERN_BIN_DIR` remains as an override for running the launcher
        # out of a build directory, but the default has to work with no
        # environment at all: a store path has to be self-contained.
        if [ -n "''${SILLYTAVERN_BIN_DIR:-}" ]; then
          server_dir="$SILLYTAVERN_BIN_DIR"
        else
          # $0 -> .../bin/sillytavern ; two dirnames up is the package root,
          # which is where server.js lives.
          server_dir="$(dirname "$(dirname "$(readlink -f "$0")")")"
        fi
        server_js="$server_dir/server.js"

        if [ ! -f "$server_js" ]; then
          echo "sillytavern: $server_js not found." >&2
          echo "  Expected server.js beside the package's bin/ directory." >&2
          echo "  Set SILYTAVERN_BIN_DIR to override the location." >&2
          exit 1
        fi

        # server.js chdirs into the server directory itself and resolves
        # relative paths (certs/, default/content) from there, so it is invoked
        # by absolute path and no `cd` is needed here.
        #
        # `exec` so node inherits this PID: systemd then signals node directly,
        # and its SIGTERM handler (exitProcess in src/server-main.js) gets to run.
        exec node "$server_js" "$@"
      '';
    };

  # `sillytavern-healthcheck` runs the server's OWN probe,
  # `src/healthcheck.js`, which exits non-zero when
  # `<dataRoot>/heartbeat.json` has not been touched within two intervals.
  #
  # It reads `SILLYTAVERN_HEARTBEATINTERVAL` and `SILLYTAVERN_DATAROOT` from the
  # environment. Both matter: with the interval unset the script parses "0",
  # treats that as "heartbeat disabled" and `process.exit(0)` immediately —
  # reporting success without having checked anything at all.
  healthcheck =
    writeShellApplication {
      name = "sillytavern-healthcheck";
      runtimeInputs = [ nodejs ];
      text = ''
        export NODE_ENV=production

        if [ -z "''${SILLYTAVERN_HEARTBEATINTERVAL:-}" ]; then
          echo "sillytavern-healthcheck: SILLYTAVERN_HEARTBEATINTERVAL is not set." >&2
          echo "  Without it the probe exits 0 unconditionally. Set" >&2
          echo "  services.sillytavern-nixos.config.heartbeatInterval > 0." >&2
          exit 1
        fi

        if [ -n "''${SILLYTAVERN_BIN_DIR:-}" ]; then
          server_dir="$SILLYTAVERN_BIN_DIR"
        else
          server_dir="$(dirname "$(dirname "$(readlink -f "$0")")")"
        fi
        exec node "$server_dir/src/healthcheck.js"
      '';
    };
in
stdenvNoCC.mkDerivation {
  pname = "sillytavern";
  inherit version;

  # `writeShellApplication` is NOT listed here: it is a function that returns a
  # derivation, not a package, and `nativeBuildInputs` rejects anything that is
  # not one. It is called in the `let` below and its output is simply realised
  # as a dependency of the install phase.
  nativeBuildInputs = [ nodejs ];

  dontConfigure = true;
  dontBuild = true;

  # Nothing to unpack: `installPhase` copies the (already filtered) `source`
  # store path directly rather than relying on the unpack phase to have
  # materialised it in the working directory. `dontUnpack` is what tells stdenv
  # that the absence of `$src` in the build directory is intentional — without
  # it the unpack phase fails with "variable $src or $srcs should point to the
  # source".
  dontUnpack = true;

  # The tree that gets installed. `lib.cleanSourceWith` has already dropped
  # `.git`, `node_modules`, `dist` and `result` — but ONLY for the flake's
  # own `source`, which is a git snapshot.
  #
  # `${source}` is a path literal here, and a path literal is resolved to
  # whatever the directory contains AT BUILD TIME. When the package is built
  # from a `path:` flake (`nix build -f`, or `builtins.getFlake "path:…"`)
  # rather than a git one, that is the working directory as it is on disk —
  # including UNTRACKED files the filter never saw.
  #
  # The two that matter:
  #
  #   result/         a `nix build --out-link result` symlink. Copied in, it
  #                   points at the PREVIOUS build's store path, which is not
  #                   in this build's closure — so the fixup phase rejects the
  #                   whole package:
  #
  #                     ERROR: noBrokenSymlinks: the symlink …/result points
  #                     to a missing target: /nix/store/…-sillytavern-1.19.0
  #
  #   */node_modules/ a nested dependency tree (e.g. `.opencode/node_modules`,
  #                   63 MiB) that the top-level-only filter does not match,
  #                   because the filter compares the BASENAME.
  #
  # So the cleanup below is not redundant with the filter — it is the
  # belt to the filter's braces, and it is what makes the package buildable
  # from a working tree at all.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r --no-preserve=mode,ownership,timestamps ${source}/. "$out/"

    rm -rf "$out/.git" "$out/node_modules" "$out/dist"
    # `result` is a SYMLINK to a store path, so `rm -rf` would follow it and
    # delete the target's contents. Remove the link itself.
    [ -L "$out/result" ] && rm -f "$out/result" || rm -rf "$out/result"
    # Every nested node_modules tree, at any depth.
    find "$out" -type d -name node_modules -prune -exec rm -rf {} +
    chmod -R u+w "$out"

    # node_modules from the fixed-output derivation. Copied rather than
    # symlinked so the result is a single self-contained store path that
    # `nix-store --realise` on another machine pulls in one piece.
    cp -r --no-preserve=mode,ownership,timestamps ${nodeModules}/node_modules "$out/node_modules"

    # Directories the server expects to exist. The Dockerfile creates exactly
    # this set, and the comment there explains why: `constants.js` hardcodes
    # directory names that must be present for a non-root, volumeless run.
    #
    #   config/   where a `config.yaml` is conventionally kept
    #   data/     the default data root, when --dataRoot is not passed
    #   plugins/  server plugins
    #   backups/  PUBLIC_DIRECTORIES.backups is served over HTTP
    #   public/scripts/extensions/third-party/  UI extensions
    mkdir -p "$out/config" "$out/data" "$out/plugins" "$out/backups" \
             "$out/public/scripts/extensions/third-party"

    # `certs/` holds the TLS material. It is created here so a consumer
    # pointing `ssl.certPath` at a relative path gets a clear ENOENT about the
    # file rather than about the directory.
    mkdir -p "$out/certs"

    mkdir -p "$out/bin"
    install -m 0755 ${launcher}/bin/sillytavern "$out/bin/sillytavern"
    install -m 0755 ${healthcheck}/bin/sillytavern-healthcheck "$out/bin/sillytavern-healthcheck"

    runHook postInstall
  '';

  # ── The wrapper ─────────────────────────────────────────────────────────────
  #
  # `node server.js` on its own is not a runnable command: it needs a specific
  # NODE_ENV, and it is easier to break by accident. The wrapper pins
  # NODE_ENV=production (which is what the Dockerfile sets, and what makes
  # `util.js` skip its verbose debug paths) and refuses `--global`, which the
  # module already forbids but which a hand-run `sillytavern --global` should
  # not be able to do by accident either.
  passthru = {
    inherit source nodeModules launcher healthcheck;
    # The server's own version, which is what `/api/ping` reports. Exposed so a
    # consumer can assert their own configuration against it; this module makes
    # no version assertion of its own.
    appVersion = version;
  };

  meta = {
    description = "SillyTavern LLM front-end and server (${version})";
    longDescription = ''
      SillyTavern is a user interface for LLMs: it serves a web chat front-end
      and a proxying backend that adapts many providers (OpenAI-compatible,
      Anthropic, Google, Mistral, Ollama, KoboldCpp and many more) to one
      internal format, and it persists chats, characters, lorebooks and
      per-user settings.

      This package is the server as it ships, built from this repository's
      source with `npm ci --omit=dev --ignore-scripts` against the committed
      lockfile. It is intended to be run by the `services.sillytavern-nixos` NixOS
      module in this flake, which supplies the config file, the data root and
      the systemd unit.
    '';
    homepage = "https://github.com/SillyTavern/SillyTavern";
    documentation = "https://docs.sillytavern.app/";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.unix;
    mainProgram = "sillytavern";
  };
}
