#!/usr/bin/env bash
#
# nix-tests/live/run.sh — run the live Nix→server/UI test suite.
#
# ── How to run ────────────────────────────────────────────────────────────────
#
#     ./nix-tests/live/run.sh              # everything
#     ./nix-tests/live/run.sh -k settings  # a subset
#
# Requires: nix with flakes enabled, and network access on the first run
# (the nixpkgs fetch). Does NOT need root, a NixOS VM, or a writable HOME.
#
# ── What it is for ────────────────────────────────────────────────────────────
#
# `nix flake check` evaluates. It proves an option exists and renders. It does
# NOT prove the server starts, that it honours the value, or that the UI
# reflects it. Most of the failures this module has actually had were invisible
# to evaluation.
#
# So this suite builds the real package, seeds a real data root, boots the
# real server, and asserts against the real HTTP responses and the real files
# on disk. The chain under test is:
#
#     Nix option → rendered config.yaml / seed spec → seeder → data root
#                → server → UI
#
# ── Why nix shell and not a venv ──────────────────────────────────────────────
#
# The host's python3 has no pytest, and there is no pip. `nix shell` provides
# both without touching the user's profile, which is what makes this runnable
# on a clean checkout.
#
# The `pytest` ENTRY POINT is used, not `python3 -m pytest`: `nix shell` puts
# pytest's bin on PATH, but `python3` still resolves to the HOST python, which
# does not have pytest on its path. The `pytest` wrapper is a shell script
# that sets up PYTHONPATH for the nix python itself, so it works. Calling
# `python3 -m pytest` here fails with ModuleNotFoundError.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# pytest only, no `requests`: the suite deliberately uses the standard library
# for HTTP (urllib) so it has one less thing to depend on.
exec nix shell \
  nixpkgs#python3Packages.pytest \
  nixpkgs#nodejs \
  --command pytest "$REPO/nix-tests/live" "$@"
