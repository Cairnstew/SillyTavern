# justfile — task runner for the SillyTavern NixOS module.
#
# ── Why a justfile ────────────────────────────────────────────────────────────
#
# This repo has four kinds of work in it, and they each want a different
# invocation:
#
#   1. Nix evaluation and builds   → `nix flake check`, `nix build`
#   2. Python test suites           → pytest
#   3. A live server boot           → build, seed, boot, assert over HTTP
#   4. JavaScript                   → eslint, npm
#
# Spelling those out in a shell every time is how commands drift out of sync
# with each other — and then CI runs something nobody ran locally. Every
# recipe here is a command the maintainer actually typed.
#
# ── Running a command in the dev shell ───────────────────────────────────────
#
# `just develop <cmd>` runs `<cmd>` inside `nix develop`, via `--command`.
# That is the whole point of the `--command` flag: it makes the dev shell
# usable from a script or a CI step, where an interactive `nix develop` would
# hang waiting for input.
#
#     just develop pytest nix-tests/
#     just develop eslint --version
#
# Recipes that need a dev-shell tool go through `develop`, so they work
# whether or not you happen to be sitting in the shell already.
#
# ── Listing the recipes ──────────────────────────────────────────────────────
#
#     just --list          # every recipe, with its doc comment
#     just --summary       # names only
#
# Run `just` with no arguments for the same list.

# ── Configuration ─────────────────────────────────────────────────────────────

# The flake to operate on. Override to point at a different checkout.
flake := env_var_or_default("ST_FLAKE", ".")

# The system to build for. Override for aarch64.
system := env_var_or_default("ST_SYSTEM", "x86_64-linux")

# The account the live tests use.
live_handle := env_var_or_default("ST_LIVE_HANDLE", "me")

# The Python test suites under `nix-tests/`, excluding the live ones (they
# need a built server and take minutes, so they are a separate recipe).
unit_tests := "nix-tests/test_seed_files.py nix-tests/test_seed_users.py nix-tests/test_link_models.py"

# The coverage audit script.
audit_script := ".opencode/skills/nix-coverage/scripts/audit.py"

# Nix files that hold the module's own logic. Deliberately NOT the whole
# tree: `pkgs/` and `default.nix` are thin, and `flake.nix` is formatted by
# hand in a way neither formatter agrees with.
nix_sources := "flake.nix lib modules pkgs overlay.nix default.nix"

# Default recipe: show the recipes.
default:
    @just --list --unsorted

# ── The dev shell ────────────────────────────────────────────────────────────

# Run a shell command inside the dev shell: `just develop "<cmd>"`
#
# Uses `nix develop --command`, so it works non-interactively — from a
# script, from CI, or from an editor task. The dev shell is where pytest,
# eslint and the rest live.
#
#     just develop "pytest nix-tests/"
#     just develop "eslint --version"
#
# The command is handed to `bash -c` as ONE string, which is how
# `nix develop --command` wants it: it execs the program it is given, so
# `bash -c` is the program and the string is the script.
#
# Quoting note: `just` re-splits a variadic argument on whitespace, so
# `just develop echo "hello world"` would arrive as `echo` `hello` `world`
# — three words, and the shell would run `echo hello world` with the
# quotes already gone. That is fine for a command line, which is why the
# argument is a single quoted string here: `just develop "echo 'hello
# world'"`. Recipes below use that form.
develop cmd:
    nix develop {{flake}} --command bash -c {{quote(cmd)}}

# Open the dev shell interactively.
shell:
    nix develop {{flake}}

# Print the dev shell's tool versions. Useful for "is my environment right?".
env:
    @just develop 'echo "node    $(node --version)"; echo "npm     $(npm --version)"; echo "python  $(python3 --version)"; echo "pytest  $(pytest --version)"; echo "nix     $(nix --version)"; echo "just    $(just --version)"'

# ── Build ────────────────────────────────────────────────────────────────────

# Build the SillyTavern package.
build:
    nix build {{flake}}#packages.{{system}}.sillytavern

# Build everything `nix flake check` will build, plus the checks themselves.
build-all:
    nix build {{flake}}#packages.{{system}}.default {{flake}}#checks.{{system}}.*

# Build the Breeze TTS Vulkan package (the module's default backend).
tts-build:
    nix build {{flake}}#packages.{{system}}.breeze-tts

# Build the CPU-only Breeze TTS package.
tts-build-cpu:
    nix build {{flake}}#packages.{{system}}.breeze-tts-cpu

# The Breeze TTS evaluation checks: unit rendering, assertions, and the VRAM
# guard run against a stubbed driver. No GPU and no weights needed.
tts-test:
    nix build -L --no-link {{flake}}#checks.{{system}}.breezeTtsCatalog {{flake}}#checks.{{system}}.breezeTtsPackage {{flake}}#checks.{{system}}.breezeTtsVoiceDefaults {{flake}}#checks.{{system}}.breezeTtsUnit {{flake}}#checks.{{system}}.breezeTtsAssertions {{flake}}#checks.{{system}}.breezeTtsVramGuard {{flake}}#checks.{{system}}.breezeTtsVoices {{flake}}#checks.{{system}}.breezeTtsVoicesInstall {{flake}}#checks.{{system}}.breezeTtsSillyTavernWiring

# Live smoke test: builds the server, loads a real GGUF, generates a clip and
# reports the real-time factor. Needs a GPU and the weights.
#
#   BREEZE_TTS_MODEL=/var/lib/breeze-tts/models/breeze-tts-2-q4_k.gguf just tts-live
tts-live:
    ./nix-tests/live/test_tts_server.sh

# Build the package and leave a `result` symlink in the working tree.
result:
    nix build {{flake}}#packages.{{system}}.sillytavern --out-link result

# Build and install the package into the Nix store, then print its path.
install:
    nix profile install {{flake}}#packages.{{system}}.sillytavern

# Remove the `result` symlink and any build leftovers.
clean:
    rm -rf result
    rm -rf .pytest_cache
    find . -name __pycache__ -type d -prune -exec rm -rf {} +

# Remove the live test's build artefacts.
clean-live:
    rm -rf /tmp/live

# ── Check ────────────────────────────────────────────────────────────────────

# Run every flake check. This is what CI runs.
check:
    nix flake check {{flake}}

# Run every flake check but only evaluate — no builds. Much faster.
check-eval:
    nix flake check {{flake}} --no-build

# Run ONE flake check by name: `just check-one settingsDeepMerge`
#
# The list of names is in lib/tests.nix, under `checks =`.
check-one name:
    nix build {{flake}}#checks.{{system}}.{{name}} --no-link --print-out-paths

# Everything CI runs, in the order CI runs it.
#
# Mirrors .github/workflows/pr-checks.yml, which does eslint and the app's
# own JavaScript unit tests, plus this repo's own gates: the flake checks
# and the Python suites.
#
# NOT included: `test-live` and `test-home`. The live suite builds a server
# and boots it, and the Home Manager harness fetches from the network;
# neither belongs in a pull-request gate. Run them locally before pushing.
ci: lint-gate check test-quiet npm-test

# Everything, including the slow suites. What you run before a release.
ci-full: ci test-live test-home audit-strict

# ── Test ─────────────────────────────────────────────────────────────────────

# Run the Python unit suites (the seeders).
test:
    @just develop 'pytest {{unit_tests}} -v'

# Run the Python unit suites quietly — the default for a quick check.
test-quiet:
    @just develop 'pytest {{unit_tests}} -q'

# Run ONE test by name: `just test-one test_deep_merge`
test-one name:
    @just develop 'pytest {{unit_tests}} -k {{name}} -v'

# Run the live Nix→server→UI suite. Builds a real server and boots it.
#
# This is the only test that proves the server actually starts and honours
# the values Nix rendered. It takes a couple of minutes.
test-live:
    @just develop 'pytest nix-tests/live -v'

# Run the live suite quietly.
test-live-quiet:
    @just develop 'pytest nix-tests/live -q'

# Run the Home Manager evaluation harness. Needs network on the first run.
test-home:
    ./nix-tests/home-eval.sh

# Run every test suite: unit, live, and Home Manager.
test-all: test test-live test-home

# ── Coverage audit ───────────────────────────────────────────────────────────

# Audit the Nix coverage of upstream's configuration surface.
#
# Derives ground truth from upstream's own sources and diffs it against the
# module's real option tree, which it gets from Nix. 100% means the
# `config.yaml` surface is genuinely complete.
audit:
    @just develop 'python3 {{audit_script}}'

# The audit, but non-zero exit on any finding. For CI.
audit-strict:
    @just develop 'python3 {{audit_script}} --strict'

# The audit, as JSON.
audit-json:
    @just develop 'python3 {{audit_script}} --json'

# Regenerate the settings inventory from upstream's own source.
#
# The inventory is what the settings-key guard reasons about, so it must never
# be edited by hand: regenerate it, and let the diff show what upstream
# changed. `nix flake check` fails if the committed file no longer matches.
settings-inventory:
    @just develop 'node scripts/extract_settings_inventory.mjs'

# The same, but non-zero exit if it is stale. For CI.
settings-inventory-check:
    @just develop 'node scripts/extract_settings_inventory.mjs --check'

# ── Lint ─────────────────────────────────────────────────────────────────────
#
# Two kinds of linter live here, and the distinction matters:
#
#   GATES      fail on a finding, and the tree is currently CLEAN:
#              `lint`, `lint-sh`.
#
#   ADVISORY   report findings but exit 0, because the tree is NOT clean:
#              `lint-nix`, `lint-nix-dead`, `fmt-check`.
#
# An advisory linter that fails the build trains people to ignore it, which
# costs more than the findings are worth. These report; they do not gate.
# Fix the findings and they become gates.
#
# ── Why eslint comes from npm, not from nixpkgs ──────────────────────────────
#
# The repo pins `eslint ^8.57.1` in devDependencies and configures it with
# `.eslintrc.cjs` — the pre-v9 format. nixpkgs ships eslint 10, which
# REQUIRES `eslint.config.*` and refuses to read `.eslintrc.*` at all:
#
#     ESLint couldn't find an eslint.config.* file.
#
# So the eslint recipes run the local `node_modules/.bin/eslint` — the
# version the repo actually pins.
#
# NOT `npm exec -- eslint`: when the package is not found locally, `npm exec`
# offers to INSTALL it, and in a non-interactive context that turns a missing
# dependency into a hang rather than an error. The local binary is either
# there or it is not.

# Install the JavaScript dependencies. eslint and the rest live here.
npm-ci:
    @just develop 'npm ci'

# Lint the JavaScript. This is a gate — the tree is clean.
#
# Needs `just npm-ci` first, or a `node_modules/` that is already present.
lint:
    @just develop './node_modules/.bin/eslint "src/**/*.js" "public/**/*.js" ./*.js'

# Lint the JavaScript and fix what can be fixed.
lint-fix:
    @just develop './node_modules/.bin/eslint "src/**/*.js" "public/**/*.js" ./*.js --fix'

# Lint the Nix for anti-patterns. Advisory: reports, does not fail.
#
# Currently finds a handful of "these parentheses can be omitted" warnings.
lint-nix:
    @just develop 'statix check {{nix_sources}} || true'

# Find dead Nix code — unused bindings, unused lambda patterns. Advisory.
#
# Currently finds ~15 real unused bindings across the module. They are
# genuine dead code and worth removing, but until they are, this reports
# rather than failing the build.
lint-nix-dead:
    @just develop 'deadnix {{nix_sources}} || true'

# Lint the shell scripts. This is a gate — the tree is clean.
lint-sh:
    @just develop 'shellcheck nix-tests/home-eval.sh nix-tests/live/run.sh nix-tests/live/test_tts_server.sh'

# Run every linter.
lint-all: lint lint-sh lint-nix lint-nix-dead

# Run only the linters that gate. This is the one to put in CI.
lint-gate: lint lint-sh

# ── Format ───────────────────────────────────────────────────────────────────

# Format the Nix sources.
#
# NOTE: this rewrites files. The tree is not currently formatted with
# either formatter, so the first run is a large diff. That is deliberate and
# separate from `check` — formatting is opt-in, never a gate.
fmt:
    @just develop 'alejandra {{nix_sources}}'

# Check formatting without changing anything. Advisory: the tree is not
# currently formatted with alejandra, so this reports rather than fails.
fmt-check:
    @just develop 'alejandra --check {{nix_sources}} || true'

# Format the JavaScript.
fmt-js:
    @just develop './node_modules/.bin/eslint "src/**/*.js" "public/**/*.js" ./*.js --fix'

# ── Node ─────────────────────────────────────────────────────────────────────

# Run the app from source against ./data.
npm-start:
    @just develop 'npm start'

# Install the app's JavaScript dependencies AND the test suite's.
#
# They are SEPARATE installs: the app's deps are at the repo root and the
# test suite's are under `tests/`, each with its own lockfile. CI does the
# same (two `npm ci` invocations). Skipping the second one makes
# `npm-test` fail with MODULE_NOT_FOUND.
npm-ci-all:
    @just develop 'npm ci && npm ci --prefix tests'

# Run the app's own JavaScript unit tests.
#
# Needs `just npm-ci-all` first, or a `tests/node_modules/` already present.
npm-test:
    @just develop 'npm run test:unit --prefix tests'

# ── Run ──────────────────────────────────────────────────────────────────────

# Run the packaged server straight from the store, on a throwaway data root.
#
# This is the packaged artifact, not the source tree — the closest thing to
# what a user would actually install.
run:
    nix run {{flake}}#sillytavern

# Run the packaged server against a data root you choose.
run-data-root root:
    nix run {{flake}}#sillytavern -- --dataRoot {{root}}

# Seed accounts into a data root.
#
# The password file is read at activation and scrypt-hashed; the plaintext
# never enters the Nix store.
seed handle password_file:
    nix run {{flake}}#seeder -- --data-root ./data \
        --user "handle={{handle}},admin=true,enabled=true,passwordFile={{password_file}}"

# ── Info ─────────────────────────────────────────────────────────────────────

# Show what this flake exposes.
info:
    @just develop 'nix flake show {{flake}}'

# Show the flake's metadata.
metadata:
    @just develop 'nix flake metadata {{flake}}'

# List the flake's outputs.
#
# `nix flake tree` does not exist — the closest thing is `nix flake show`,
# which prints the output structure. It writes the tree to stderr and exits
# non-zero for the systems it omits, so stderr is captured and the exit code
# is discarded.
#
# `||` is written as `|| true` inside a quoted argument, because `just` reads
# a bare `||` as a recipe dependency and would try to run a recipe named
# `true`.
outputs:
    @just develop 'nix flake show {{flake}} 2>&1 | cat' | head -40

# The store path of a flake output: `just path packages.x86_64-linux.sillytavern`
path attr:
    @just develop 'nix build {{flake}}#{{attr}} --no-link --print-out-paths'

# ── Maintenance ──────────────────────────────────────────────────────────────

# Update the flake's lock file.
lock:
    nix flake lock {{flake}} --update-input nixpkgs

# Garbage-collect the Nix store. Destructive and slow; you asked for it.
gc:
    nix store gc
    nix store optimise

# Show what `nix flake check` would do, without doing it.
plan:
    nix flake check {{flake}} --dry-run 2>/dev/null || nix flake check {{flake}} --no-build
