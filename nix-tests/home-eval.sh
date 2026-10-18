#!/usr/bin/env bash
#
# nix-tests/home-eval.sh — evaluate modules/home.nix against real Home Manager.
#
# ── How to run ────────────────────────────────────────────────────────────────
#
#     ./nix-tests/home-eval.sh
#
# No flake input is required, and none is added: whether this flake should carry
# a `home-manager` input is an open decision, so this script talks to the network
# directly and pins the revision itself. If that decision goes the other way,
# replace the `HM_REV` fetch below with the flake input and delete the fetch.
#
# Requires: bash, nix with flakes enabled, and network access to github.com on the
# first run only (afterwards the revision is in the store). Does NOT need a NixOS
# VM, root, or a writable HOME — the systems are evaluation-only.
#
# ── What it is for ────────────────────────────────────────────────────────────
#
# modules/home.nix read `osConfig.services.sillytavern`, which resolves to
# NIXPKGS' module, not ours (`services.sillytavern-nixos`). That path has no
# `config` sub-option, so `instance.config.ssl.enabled` was a hard evaluation
# error and the module could not be built at all whenever a SillyTavern instance
# was in scope. The `or null` fallback hid it, because the module only ever
# "worked" in the one case where it could not.
#
# ── The trap this harness is built around ─────────────────────────────────────
#
# DO NOT assert with `builtins.attrNames cfg.home.packages`. That succeeds even
# when the module is broken, because the generated script's URL lives inside the
# derivation's `text` attribute, which is LAZY — it is only forced when the
# derivation is built. A package that fails to evaluate is happily listed by
# name.
#
# So every case here BUILDS the package and greps the resulting file. That is the
# only assertion style that would have caught the bug. See "FORCING" below.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pinned, and deliberately not resolved at runtime: a harness whose subject
# moves under it is not a test.
HM_REV="640725978b99076e18e069f6e7d2959124584f8f"
HM_FLAKE="github:nix-community/home-manager/${HM_REV}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

failures=0

# ── The Nix fixture ───────────────────────────────────────────────────────────
#
# Parameterised by `case`. Emits, as JSON:
#   builtName  — name of the generated package, or "" when none is produced
#   builtText  — the CONTENTS of the built script (FORCING, see below)
#   warnings   — config.warnings
#
# `builtText` comes from actually building `home.packages` and reading the file,
# never from the derivation's attributes.
cat > "$WORK/fixture.nix" <<'FIXTURE'
{ case ? "on" }:
let
  hm = builtins.getFlake HM_FLAKE;
  st = builtins.getFlake REPO_FLAKE;
  pkgs = import hm.inputs.nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;

  base = {
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "/dev/null"; fsType = "tmpfs"; };
    system.stateVersion = "25.05";
  };

  mk = block: st.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ st.nixosModules.sillytavern (base // block) ];
  };

  stOn  = mk { services.sillytavern-nixos = { enable = true; config.port = 8138; }; };
  stSsl = mk { services.sillytavern-nixos = { enable = true; config.port = 8443; config.ssl.enabled = true; }; };
  stOff = mk { services.sillytavern-nixos.enable = false; };

  osCfg =
    if case == "on" || case == "no_outputs" then stOn.config
    else if case == "ssl" then stSsl.config
    else if case == "nixos_disabled" then stOff.config
    else { };

  stHome =
    if case == "no_outputs" then { sillytavern.enable = true; }
    else if case == "home_disabled" then { }
    else { sillytavern = { enable = true; openInBrowser = true; }; };

  cfg = hm.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      st.homeModules.sillytavern
      { home.username = "seanc"; home.homeDirectory = "/tmp/home-eval"; home.stateVersion = "25.05"; }
      stHome
      { _module.args.osConfig = osCfg; }
    ];
  };

  # Pick the module's OWN packages out of home.packages. Filtered by NAME, not
  # just "has a text attribute" — home-manager contributes several of its own
  # script packages (hm-session-vars.sh) and those are not ours.
  ours = builtins.filter
    (p: lib.hasPrefix "sillytavern-" (p.name or ""))
    cfg.config.home.packages;
in {
  # The DERIVATIONS themselves: `nix build` needs derivations, and building them
  # is what forces the lazy `text`. Returning only names would silently pass.
  derivations = ours;
  packages = map (p: p.name) ours;
  warnings = cfg.config.warnings;
}
FIXTURE

# ── FORCING ───────────────────────────────────────────────────────────────────
#
# `nix build` on the home configuration's activation derivation, then read the
# script off disk. This is the part that matters: it forces the lazy `text`, so
# a module that cannot evaluate fails here instead of passing silently.
build_script() {
  local case_name="$1"
  local out="$WORK/build-$case_name"

  rm -rf "$out"
  # Building the DERIVATION is the assertion. If the module cannot evaluate,
  # this fails; if it can, the script exists on disk and is read below.
  #
  # `--out-link` on a LIST of derivations produces a directory of symlinks.
  nix build --impure \
    --expr "(import $WORK/fixture.nix { case = \"$case_name\"; }).derivations" \
    --out-link "$out" >/dev/null 2>"$WORK/err-$case_name" || return 1

  find -L "$out" -type f -exec cat {} + 2>/dev/null || true
}

# ── Check helpers ─────────────────────────────────────────────────────────────

# eval_warnings <case> — warnings as one line each.
eval_warnings() {
  nix eval --json --impure --expr "import $WORK/fixture.nix { case = \"$1\"; }" \
    2>/dev/null \
    | grep -v '^warning: Git tree' \
    | python3 -c 'import json,sys; [print(w.splitlines()[0]) for w in json.load(sys.stdin)["warnings"]]'
}

eval_packages() {
  nix eval --json --impure --expr "import $WORK/fixture.nix { case = \"$1\"; }" \
    2>/dev/null \
    | grep -v '^warning: Git tree' \
    | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["packages"]))'
}

check() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == *"$want"* ]]; then
    green "  PASS  $label"
  else
    red   "  FAIL  $label"
    red   "        expected to contain: $want"
    red   "        got: ${got:-<empty>}"
    failures=$((failures + 1))
  fi
}

check_empty() {
  local label="$1" got="$2"
  if [[ -z "${got// /}" ]]; then
    green "  PASS  $label"
  else
    red   "  FAIL  $label (expected nothing, got: $got)"
    failures=$((failures + 1))
  fi
}

# ── Cases ─────────────────────────────────────────────────────────────────────

echo "home.nix evaluation harness (home-manager ${HM_REV:0:12})"
echo

export HM_FLAKE REPO_FLAKE="git+file://${REPO}"

# Recreate fixture.nix now that the env vars it interpolates are exported.
sed -i "s|HM_FLAKE|\"${HM_FLAKE}\"|; s|REPO_FLAKE|\"${REPO_FLAKE}\"|" "$WORK/fixture.nix"

echo "case: instance on, port 8138 — URL must come from OUR module"
if out="$(build_script on)"; then
  check "sillytavern-open built and embeds the system port" "http://localhost:8138/" "$out"
else
  red "  FAIL  the configuration did not evaluate at all"
  sed -n '1,12p' "$WORK/err-on" | sed 's/^/        /'
  failures=$((failures + 1))
fi
check "no warnings" "" "$(eval_warnings on)"
echo

echo "case: ssl.enabled = true — scheme must become https"
if out="$(build_script ssl)"; then
  check "https scheme and the right port" "https://localhost:8443/" "$out"
else
  red "  FAIL  did not evaluate"
  failures=$((failures + 1))
fi
echo

echo "case: NixOS module imported but enable = false"
check "warns that there is nothing to reach" \
  "services.sillytavern-nixos.enable\` is false" "$(eval_warnings nixos_disabled)"
echo

echo "case: no services.sillytavern-nixos in scope at all"
check "warns by the CORRECT option name (not nixpkgs')" \
  "no \`services.sillytavern-nixos\` module was" "$(eval_warnings none)"
echo

echo "case: enable = true but neither output option set"
check "warns that this produces nothing (silent-no-op guard)" \
  "neither sillytavern.openInBrowser nor" "$(eval_warnings no_outputs)"
check_empty "and nothing is generated" "$(eval_packages no_outputs)"
echo

echo "case: module not enabled at all"
check_empty "no packages" "$(eval_packages home_disabled)"
check_empty "no warnings" "$(eval_warnings home_disabled)"
echo

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $failures -eq 0 ]]; then
  green "home.nix: all cases pass"
else
  red "home.nix: $failures case(s) failed"
  exit 1
fi