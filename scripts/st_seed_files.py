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
    `_webpack/` and `config.yaml` are refused outright. `_errors/` is refused
    too, except for the four filenames upstream actually serves — see
    `ALLOWED_ERROR_PAGES`.
  * Paths are confined to the data root. A relative path containing `..`, or an
    absolute path, is an error rather than a write outside the root.

Spec format (JSON):

    {
      "dataRootFiles": {
        "<rel path>": {
          "json": <any>, "path": "/nix/store/…",
          # Optional per-file overrides:
          #   "policy": "overwrite"  — ignore the CLI default for this file
          #   "mode":   "0644"       — ignore the owner-only default (0600)
        }
      },
      "users": {
        "<handle>": {
          "settings": { <deep-merged into settings.json> },
          "files":    { "<rel path>": {"json": …} | {"path": …} },
          "secrets":  { "<SECRET_KEY>": {"value": "/run/agenix/…", "label": "work"} }
        }
      }
    }

Only `users` carries `settings`; `settings.json` is per-account by construction.

`secrets` is `secrets.json`, where SillyTavern 1.19 keeps every provider API key
(`api_key_openai`, `api_key_claude`, `api_key_novel`, ...). Its `value` is a
PATH, never a literal: a secret must not pass through the Nix store, so the
rendered spec carries `/run/agenix/...` and the bytes are read here, at
activation time.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import uuid
from typing import Any

# Written by the server as it runs. Never configuration, never ours.
# `secrets.json` is reserved because it has its own `secrets` mechanism below,
# not because it is runtime state: it must be reachable through that mechanism
# so the value can be sourced from a file rather than rendered into the store.
RESERVED_BASENAMES = frozenset({"stats.json", "config.yaml", "secrets.json"})
# `_cache` is the transformers.js model cache (`DATA_ROOT/_cache`, see
# src/transformers.js) — hundreds of MiB of downloaded ONNX weights, pure
# runtime state, and never something a spec should be able to declare.
#
# `_errors` used to be reserved outright, which made branded error pages
# unreachable from Nix: upstream serves four HTML files from `DATA_ROOT/_errors`
# on exactly the paths an operator most wants to rebrand (failed login, blocked
# IP, rejected Host, 404), and there was no way to override any of them. They
# are configuration, not runtime state — the content manager copies them once
# from `default/content/index.json` and never overwrites — so they are handled
# by the narrow allowlist below rather than by a blanket refusal.
RESERVED_TOP_LEVEL = frozenset({"_storage", "_webpack", "_sc", "_cache", "backups"})

# The only files allowed under `_errors/`. Exactly upstream's four, hardcoded at
# four separate call sites; anything else in that directory is never read, so
# allowing it would only create a file that looks meaningful and is not.
#
#   forbidden-by-whitelist.html  src/middleware/whitelist.js:59
#   host-not-allowed.html        src/middleware/hostWhitelist.js:14
#   unauthorized.html            src/endpoints/users-public.js
#   url-not-found.html           src/server-main.js:456
ALLOWED_ERROR_PAGES = frozenset(
    {
        "forbidden-by-whitelist.html",
        "host-not-allowed.html",
        "unauthorized.html",
        "url-not-found.html",
    }
)
ERROR_DIR = "_errors"

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
    # `_errors/` is open, but only to the four filenames upstream actually reads,
    # and only at the top level of it: no `_errors/subdir/x.html`, which would
    # pass the basename check and still be a file nothing ever serves.
    if parts and parts[0] == ERROR_DIR:
        if len(parts) != 2 or parts[1] not in ALLOWED_ERROR_PAGES:
            raise SeedError(
                f"refusing to seed {ERROR_DIR!r} path: {rel!r}; "
                f"only {', '.join(sorted(ALLOWED_ERROR_PAGES))} are read by the server"
            )
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


def write_atomic(path: str, payload: bytes, dry_run: bool, mode: int = FILE_MODE) -> bool:
    """Write via a temp file in the same directory, then rename over.

    A crash midway must not leave a half-written `settings.json`; the rename is
    atomic within a filesystem, which the same-directory temp file guarantees.

    `mode` defaults to the owner-only `FILE_MODE` because almost everything here
    may hold a key. A caller seeding something that is SERVED to browsers must
    pass its own mode — `0644` for `_css/user.css`, which `userCssMiddleware`
    hands to every visitor via `res.sendFile`.
    """
    if dry_run:
        return True
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".seed-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(payload)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True


def mode_for(entry: dict, default: int = FILE_MODE) -> int:
    """Resolve a per-entry `mode`, which is a 4-digit octal STRING like "0644".

    A string rather than a number because that is what a Nix string literal
    carries. Only strings are accepted: an int would silently bypass the
    octal-string check, so `6440` would be taken as decimal rather than rejected,
    and the resulting `os.chmod` argument would be nonsense. The error is worth
    more than the convenience — the only caller is a rendered spec.
    """
    raw = entry.get("mode")
    if raw is None:
        return default
    if not isinstance(raw, str) or len(raw) != 4 or any(c not in "01234567" for c in raw):
        raise SeedError(
            f"`mode` must be a 4-digit octal string such as \"0644\", got {raw!r}"
        )
    return int(raw, 8)


def policy_for(entry: dict, default: str) -> str:
    """Resolve a per-entry `policy`, overriding the CLI-wide default.

    This exists for exactly one caller: `_css/user.css`, which must be
    overwritten on every activation regardless of `seedPolicy` because nothing
    in the server ever UPDATES it — content seeding copies
    `default/content/user.css` into place on first start and then never
    overwrites it — so create-only would mean the file is written once and then
    never changed again.
    """
    raw = entry.get("policy")
    if raw is None:
        return default
    if raw not in ("missing", "overwrite"):
        raise SeedError(
            f"`policy` must be \"missing\" or \"overwrite\", got {raw!r}"
        )
    return raw


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
    """Seed one file, honouring the entry's own `policy` and `mode` overrides."""
    target = safe_join(root, rel)
    effective_policy = policy_for(content, policy)
    effective_mode = mode_for(content)
    exists = os.path.exists(target)
    if exists and effective_policy == "missing":
        stats["skipped"] += 1
        return
    write_atomic(target, payload_for(content), dry_run, effective_mode)
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


def seed_secrets(
    user_dir: str, secrets: dict, policy: str, dry_run: bool, stats: dict
) -> None:
    """Merge declared provider API keys into an account's `secrets.json`.

    The on-disk shape is NOT a flat map. `src/endpoints/secrets.js` stores an
    array of `{id, value, label, active}` per key so a key can be rotated
    without losing the old one, and only the entry with `active: true` is sent
    upstream. So this preserves every existing entry for a key and only touches
    the active slot, which means:

      * a key with no existing entries gets one active entry;
      * a key whose active entry already has our value is left alone, so this
        is idempotent across `nixos-rebuild`;
      * under `overwrite`, the previously-active entry is DEACTIVATED rather
        than deleted, keeping the history the UI's key manager expects.

    Values are read from a file, never inlined: the spec only carries a path so
    the secret itself never enters the Nix store.
    """
    target = os.path.join(user_dir, "secrets.json")
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
            raise SeedError(
                f"{target} is not valid JSON ({exc}); refusing to touch it"
            ) from exc

    merged = dict(existing)
    changed = False
    for key, spec in secrets.items():
        if not isinstance(spec, dict) or "value" not in spec:
            raise SeedError(
                f"secrets.{key} must be {{ value = <path>; label = …; }}, got {spec!r}"
            )
        src = spec["value"]
        if not isinstance(src, str):
            raise SeedError(f"secrets.{key}.value must be a path string")
        try:
            with open(src, "r", encoding="utf-8") as fh:
                # Trailing newlines are an artefact of how the secret file was
                # written; an API key with a stray \n fails auth with a 401
                # that looks like a bad key.
                value = fh.read().strip()
        except OSError as exc:
            raise SeedError(
                f"secrets.{key}: cannot read {src} ({exc}). A secret file is "
                f"missing when agenix has not decrypted it yet — check the "
                f"agenix service, or that this handle is declared on a host "
                f"that has the key."
            ) from exc

        label = spec.get("label", key)
        entries = list(merged.get(key) or [])
        active = next((e for e in entries if isinstance(e, dict) and e.get("active")), None)

        if active is not None and active.get("value") == value:
            stats["skipped"] += 1
            continue

        if active is not None and policy == "missing":
            # An operator added this key through the UI. Respect that.
            stats["skipped"] += 1
            continue

        if active is not None:
            # `overwrite`: retire the old entry, keep it for the key manager's
            # history, and add ours as the new active one.
            entries = [
                {**e, "active": False} if isinstance(e, dict) and e.get("active") else e
                for e in entries
            ]
        entries.append(
            {"id": str(uuid.uuid4()), "value": value, "label": label, "active": True}
        )
        merged[key] = entries
        changed = True
        stats["written"] += 1
        if not dry_run:
            _log(f"seeded secret {key} ({label})")

    if not changed:
        return
    # The server writes this with a 4-space indent and no trailing newline.
    write_atomic(
        target, json.dumps(merged, indent=4, ensure_ascii=False).encode("utf-8"), dry_run
    )


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
        secrets = userspec.get("secrets") or {}
        if secrets:
            seed_secrets(user_dir, secrets, policy, dry_run, stats)
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