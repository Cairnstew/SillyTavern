#!/usr/bin/env python3
"""Seed SillyTavern's JSON state — settings.json, presets, themes, books.

SillyTavern's real configuration is not `config.yaml`. That file holds ~51
server settings; everything the application actually configures lives in JSON
under the data root. Booting 1.19.0 against an empty data root writes ~150 of
them, and the two that matter are:

  settings.json   26 KB, 19 top-level keys, five levels deep, ~300 leaves
  stats.json      runtime counters, written constantly, must never be seeded

plus one file per preset, theme, world book, quick reply and workflow.

This script seeds those from a declarative spec, so they can come from Nix
instead of from clicking. It is deliberately narrow:

  * CREATE-ONLY by default. A file the UI has written is never clobbered, so an
    edit made in SillyTavern survives `nixos-rebuild`. `--policy overwrite`
    opts out.
  * `settings.json` is DEEP-MERGED rather than replaced, even under
    `--policy overwrite`. The server rewrites that file constantly and adds keys
    this script has never heard of; replacing it wholesale would delete them.
  * Runtime state is never touched: `stats.json`, `backups/`, `_storage/`,
    `_webpack/`, `_errors/` and `config.yaml` are refused outright.
  * Paths are confined to the data root. A relative path containing `..`, or an
    absolute path, is an error rather than a write outside the root.

Spec format (JSON):

    {
      "dataRootFiles": { "<rel path>": {"json": <any>} | {"path": "/nix/store/…"} },
      "users": {
        "<handle>": {
          "settings": { <deep-merged into settings.json> },
          "files":    { "<rel path>": {"json": …} | {"path": …} }
        }
      }
    }

Only `users` carries `settings`; `settings.json` is per-account by construction.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from typing import Any

# Written by the server as it runs. Never configuration, never ours.
RESERVED_BASENAMES = frozenset({"stats.json", "config.yaml"})
RESERVED_TOP_LEVEL = frozenset({"_storage", "_webpack", "_errors", "_sc", "backups"})

# settings.json holds whatever the UI put there, including API keys typed into
# the connection panel. Seeded files are owner-only.
FILE_MODE = 0o600


class SeedError(Exception):
    """A spec that must not be applied at all."""


def _log(msg: str) -> None:
    print(f"st-seed-files: {msg}", file=sys.stderr, flush=True)


# ── path safety ──────────────────────────────────────────────────────────────


def safe_join(root: str, rel: str) -> str:
    """Join `rel` under `root`, refusing anything that escapes it.

    `os.path.normpath` collapses `..` before we touch the filesystem, so
    `../../etc/passwd` is caught here rather than written. The comparison is
    done on resolved paths because the data root itself is normally a symlink
    (systemd's StateDirectory) and a prefix test on the unresolved string would
    reject legitimate writes.
    """
    if not rel or rel.strip() == "":
        raise SeedError("empty path in spec")
    if os.path.isabs(rel):
        raise SeedError(f"absolute path not allowed in spec: {rel!r}")

    root_real = os.path.realpath(root)
    target = os.path.normpath(os.path.join(root_real, rel))

    # normpath already collapsed `..`; this catches anything still climbing out.
    if target != root_real and not target.startswith(root_real + os.sep):
        raise SeedError(f"path escapes the data root: {rel!r}")

    # Check the RAW components, before normpath has a chance to collapse
    # `a/../b.json` into a bare `b.json`. A `..` anywhere in a spec is a caller
    # mistake, and refusing it outright keeps the rule stateable: no `..`, ever.
    parts = rel.replace(os.sep, "/").split("/")
    if os.pardir in parts:
        raise SeedError(f"path escapes the data root: {rel!r}")
    if parts and parts[0] in RESERVED_TOP_LEVEL:
        raise SeedError(f"refusing to seed reserved server state: {rel!r}")
    if os.path.basename(parts[-1]) in RESERVED_BASENAMES:
        raise SeedError(f"refusing to seed reserved server state: {rel!r}")

    return target


# ── merging ──────────────────────────────────────────────────────────────────


def deep_merge(base: dict, patch: dict) -> dict:
    """Merge `patch` over `base`, recursively. `patch` wins on a leaf.

    A value in `patch` replaces the corresponding value in `base` wholesale —
    including when it is itself an object — EXCEPT that two objects are merged
    key by key. That is what lets `settings.common` set a default and
    `settings.byUser.<handle>` override a single nested leaf without repeating
    the other 30 keys beside it.
    """
    out = dict(base)
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


# ── writing ──────────────────────────────────────────────────────────────────


def write_atomic(path: str, payload: bytes, dry_run: bool) -> bool:
    """Write via a temp file in the same directory, then rename over.

    A crash midway must not leave a half-written `settings.json`; the rename is
    atomic within a filesystem, which the same-directory temp file guarantees.
    Returns True if a write happened.
    """
    if dry_run:
        return True
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".seed-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(payload)
        os.chmod(tmp, FILE_MODE)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True


def payload_for(content: dict) -> bytes:
    """Turn one `{"json": …}` / `{"path": …}` entry into bytes on disk."""
    has_json = "json" in content and content["json"] is not None
    has_path = "path" in content and content["path"] is not None
    if has_json == has_path:
        raise SeedError(
            f"entry must set exactly one of `json` or `path`, got "
            f"json={has_json} path={has_path}"
        )
    if has_path:
        src = content["path"]
        if not isinstance(src, str):
            raise SeedError(f"`path` must be a string, got {type(src).__name__}")
        with open(src, "rb") as fh:
            return fh.read()
    # SillyTavern writes its own JSON pretty-printed with two spaces and a
    # trailing newline; match it so a seeded file is not a spurious diff
    # against one the server later rewrites.
    return (json.dumps(content["json"], indent=2, ensure_ascii=False) + "\n").encode("utf-8")


# ── seeding ──────────────────────────────────────────────────────────────────


def seed_file(
    root: str, rel: str, content: dict, policy: str, dry_run: bool, stats: dict
) -> None:
    target = safe_join(root, rel)
    exists = os.path.exists(target)
    if exists and policy == "missing":
        stats["skipped"] += 1
        return
    write_atomic(target, payload_for(content), dry_run)
    stats["written"] += 1
    if not dry_run:
        _log(f"{'restored' if exists else 'created'} {rel}")


def seed_settings(
    user_dir: str, settings: dict, policy: str, dry_run: bool, stats: dict
) -> None:
    """Deep-merge `settings` into an account's settings.json.

    Merged rather than replaced under BOTH policies. The server rewrites this
    file on nearly every interaction and carries keys nobody enumerated, so a
    wholesale write is data loss even when the operator asked to overwrite.
    """
    target = os.path.join(user_dir, "settings.json")
    existing: dict = {}
    if os.path.exists(target):
        try:
            with open(target, "r", encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                existing = loaded
            else:
                raise SeedError(f"{target} is not a JSON object")
        except json.JSONDecodeError as exc:
            # Refuse rather than silently replacing a file we cannot read: it is
            # probably a hand-edit with a typo, and overwriting loses it.
            raise SeedError(f"{target} is not valid JSON ({exc}); refusing to touch it") from exc

    merged = deep_merge(existing, settings)
    if merged == existing and os.path.exists(target):
        stats["skipped"] += 1
        return
    write_atomic(
        target, (json.dumps(merged, indent=2, ensure_ascii=False) + "\n").encode("utf-8"), dry_run
    )
    stats["written"] += 1
    if not dry_run:
        _log(f"merged settings.json ({len(merged)} keys)")


def apply_spec(spec: dict, data_root: str, policy: str, dry_run: bool) -> dict:
    stats = {"written": 0, "skipped": 0}

    for rel, content in (spec.get("dataRootFiles") or {}).items():
        seed_file(data_root, rel, content, policy, dry_run, stats)

    for handle, userspec in (spec.get("users") or {}).items():
        user_dir = safe_join(data_root, handle)
        if os.path.isdir(user_dir) or not dry_run:
            os.makedirs(user_dir, exist_ok=True)
        settings = userspec.get("settings") or {}
        if settings:
            seed_settings(user_dir, settings, policy, dry_run, stats)
        for rel, content in (userspec.get("files") or {}).items():
            seed_file(user_dir, rel, content, policy, dry_run, stats)

    return stats


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-root", required=True)
    ap.add_argument("--spec", required=True, help="JSON file describing what to seed")
    ap.add_argument("--policy", choices=["missing", "overwrite"], default="missing")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    try:
        with open(args.spec, "r", encoding="utf-8") as fh:
            spec = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        _log(f"cannot read spec {args.spec}: {exc}")
        return 1

    try:
        stats = apply_spec(spec, args.data_root, args.policy, args.dry_run)
    except SeedError as exc:
        _log(f"refusing to seed: {exc}")
        return 2
    except OSError as exc:
        _log(f"{exc}")
        return 1

    _log(
        f"{stats['written']} written, {stats['skipped']} left alone "
        f"(policy={args.policy}{', dry run' if args.dry_run else ''})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())