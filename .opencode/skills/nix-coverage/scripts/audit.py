#!/usr/bin/env python3
"""Audit the Nix wrapper's coverage of SillyTavern's configuration surface.

Answers one question, mechanically: **for every configuration input
SillyTavern accepts, is there a way to set it from Nix?**

The module's own claim is that it covers all of it. That claim is only as good
as the last time someone checked, and the surfaces drift in three directions at
once: upstream adds keys, upstream renames them, and this module adds its own
options. So the audit derives ground truth from the upstream sources at the
pinned version and diffs it against what the module actually renders.

Four surfaces, because they fail in different ways:

  config.yaml keys   rendered into the store config; a missing one is a key with
                     no option, which `configYamlRoundTrip` also catches but
                     only as a build failure with no list of what changed
  CLI flags         argv outranks config.yaml (src/util.js), so an uncovered
                     flag is a config value that silently wins over Nix
  SILLYTAVERN_* env getConfigValue checks env FIRST (src/util.js:90), so an
                     env var silently overrides the rendered config — a Nix
                     option can be correct and still lose
  data-root state   per-account files, seedable through files.byUser, plus the
                     paths that must NOT be seedable

Everything is derived, never hardcoded: the key list comes from
default/config.yaml, the flag list from src/command-line.js, and the module's
side from evaluating Nix. Hardcoding a second copy of the surface is exactly
how the coverage map goes stale without anyone noticing.

Usage:
    audit.py [--repo PATH] [--json] [--strict]

Exit status is 0 unless --strict is given and a gap is found, so this is
usable as a CI check as well as a discovery tool.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# ── Surfaces deliberately NOT required to be Nix options ───────────────────
#
# Grouped by WHY they are excluded. Adding to these lists needs a reason, not
# a preference — that is what keeps the exclusion list from becoming a place
# where gaps go to be forgotten.

# Runtime state that is the user's own writing. Seeding it would overwrite
# what they did. Correctly not configurable.
NEVER_SEEDABLE = [
    "chats",
    "chat",
    "group chats",
    "backups",
    "assets",
    "user",
    "users",
    "_storage",
]

# Read-only material that ships in the package and is served from there.
# A Nix option would be a lie: there is no writable location to point it at.
# (See docs/ui-surface.md §5.1 for the locale case, which is the one that
# needed an upstream change rather than an exclusion.)
NOT_A_NIX_SURFACE = [
    "locales",
    "language",
    "css",
    "third-party",
]


def _split_top_level(text: str, sep: str = ",") -> list[str]:
    """Split on `sep`, ignoring separators nested inside [] { } or quotes."""
    parts: list[str] = []
    depth = 0
    quote: str | None = None
    current = ""

    for char in text:
        if quote:
            current += char
            if char == quote:
                quote = None
            continue
        if char in "'\"":
            quote = char
            current += char
            continue
        if char in "[{(":
            depth += 1
        elif char in "]})":
            depth -= 1
        if char == sep and depth == 0:
            parts.append(current)
            current = ""
            continue
        current += char

    if current.strip():
        parts.append(current)
    return [p.strip() for p in parts if p.strip()]


def _parse_flow(body: str) -> list[tuple[str, bool]]:
    """Parse the body of an inline `{a: 1, b: 2}` map into (key, has_value)."""
    entries: list[tuple[str, bool]] = []
    for part in _split_top_level(body):
        match = re.match(r"^['\"]?([A-Za-z_][A-Za-z0-9_.-]*)['\"]?\s*:", part)
        if not match:
            continue
        entries.append((match.group(1), bool(part.split(":", 1)[1].strip())))
    return entries


def repo_root(explicit: str | None) -> Path:
    """Locate the repository root.

    An explicit --repo wins. Otherwise walk up from this script looking for a
    directory that actually contains the files being audited — the script lives
    at <repo>/.opencode/skills/nix-coverage/scripts/, so counting parents gets
    it wrong, and checking for a marker file is what makes it correct from any
    depth.
    """
    if explicit:
        return Path(explicit).resolve()

    marker = Path("default/config.yaml")
    for candidate in [Path(__file__).resolve().parent, *Path(__file__).resolve().parents]:
        if (candidate / marker).exists():
            return candidate

    raise SystemExit(
        "could not find the repository root (no default/config.yaml above this "
        "script) — pass --repo"
    )


class Audit:
    def __init__(self, repo: Path) -> None:
        self.repo = repo
        self.findings: list[dict] = []
        self.notes: list[str] = []

    def read(self, rel: str) -> str:
        path = self.repo / rel
        if not path.exists():
            raise SystemExit(f"missing required file: {rel}")
        return path.read_text(encoding="utf-8", errors="replace")

    def finding(self, surface: str, subject: str, detail: str, severity: str) -> None:
        self.findings.append(
            {
                "surface": surface,
                "subject": subject,
                "detail": detail,
                "severity": severity,
            }
        )

    # ── 0b. settings.json keys (the UI's own settings) ──────────────────────
    #
    # `settings.json` is the OTHER backend: `config.yaml` drives the server,
    # `settings.json` drives the browser. It is written by the client
    # (`public/script.js`, `saveSettings()`) and read by direct property
    # access, so a key that upstream does not have is silently inert.
    #
    # The field list comes from `lib/settings-inventory.json`, which is
    # DERIVED from upstream's own sources by
    # `scripts/extract_settings_inventory.mjs` — never typed out by hand. The
    # audit therefore measures it rather than asserting it.
    def settings_json_surface(self) -> dict:
        path = self.repo / "lib" / "settings-inventory.json"
        if not path.exists():
            self.finding(
                "settings.json",
                "lib/settings-inventory.json",
                "missing: the settings-key guard has nothing to reason about",
                "error",
            )
            return {"total": 0, "subtrees": {}, "top_level": 0}
        data = json.loads(path.read_text(encoding="utf-8"))
        subtrees = {
            name: len(surface["fields"]) for name, surface in data["surfaces"].items()
        }
        return {
            "total": sum(subtrees.values()),
            "subtrees": subtrees,
            "top_level": len(data["topLevelKeys"]),
        }

    # ── 1. config.yaml keys ──────────────────────────────────────────────────

    def config_yaml_keys(self) -> list[str]:
        """Every mapping key path in default/config.yaml, fully flattened."""
        text = self.read("default/config.yaml")
        return sorted(self._flatten_yaml_keys(text))

    def _flatten_yaml_keys(self, text: str) -> set[str]:
        """Flatten nested YAML mappings into dotted paths.

        Written by hand rather than with a YAML library so that comment-only
        lines and the document's list-of-strings style cannot produce phantom
        paths. Indentation is the only structural signal used.

        Only LEAF keys are returned — a parent that opens a nested mapping is
        a container, not a setting. `logging:` on its own is not a thing a user
        sets; `logging.accessLog` is. Reporting containers as gaps would swamp
        the real findings with noise.
        """
        leaves: set[str] = set()
        # Stack of (indent, full_path, has_value). The FULL PATH is stored on
        # each entry rather than a bare key name: when a sibling is popped its
        # parent has already gone from the stack, so rebuilding the path from
        # the remaining stack would chain one sibling onto the next
        # (`dimensions.bg.avatar.persona`). Storing the path as it was when the
        # entry was pushed is the only way to get it right once entries start
        # closing in a different order than they were opened.
        stack: list[tuple[int, str, bool]] = []

        for raw in text.splitlines():
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue

            indent = len(raw) - len(raw.lstrip(" "))
            stripped = raw.strip()

            # A list item cannot introduce a mapping key at this level.
            if stripped.startswith("- "):
                continue

            match = re.match(r"^([A-Za-z_][A-Za-z0-9_.-]*):(\s|$)", stripped)
            if not match:
                continue
            name = match.group(1)

            # An inline flow map — `dimensions: { 'bg': [160, 90], ... }` —
            # carries its children on the same line, so a block parser would
            # see one leaf and miss every child. config.yaml has exactly one
            # of these, and it is the one place upstream models a fixed-key
            # list that the module exposes as an attrsOf. Expand it into the
            # equivalent block form before descending.
            inline = re.match(r"^([A-Za-z_][A-Za-z0-9_.-]*):\s*\{(.*)\}\s*$", stripped)
            if inline:
                while stack and stack[-1][0] >= indent:
                    _i, path, had = stack.pop()
                    if had:
                        leaves.add(path)
                # The parent path must be the FULL path, not the bare key: this
                # line can be nested (`thumbnails:` then `dimensions: { … }`),
                # and using the bare name silently drops every ancestor, which
                # then reports `dimensions.bg` as an uncovered key that is in
                # fact covered by `config.thumbnails.dimensions.bg`.
                parent_path = stack[-1][1] if stack else ""
                parent = inline.group(1)
                parent = f"{parent_path}.{parent}" if parent_path else parent
                stack.append((indent, parent, False))
                for child_name, child_value in _parse_flow(inline.group(2)):
                    stack.append((indent + 1, f"{parent}.{child_name}", child_value))
                continue

            # A key that carries a value on its own line is a leaf; one written
            # as bare `key:` opens a container whose children follow.
            # Everything after the first colon, stripped, is the value — empty
            # means container.
            value = stripped.split(":", 1)[1].strip()
            has_value: bool = bool(value)

            while stack and stack[-1][0] >= indent:
                _i, path, had = stack.pop()
                if had:
                    leaves.add(path)

            parent_path = stack[-1][1] if stack else ""
            path = f"{parent_path}.{name}" if parent_path else name
            stack.append((indent, path, has_value))

        # Close whatever is still open at EOF.
        while stack:
            _i, path, had = stack.pop()
            if had:
                leaves.add(path)

        return leaves

    # ── 2. CLI flags ────────────────────────────────────────────────────────

    def cli_flags(self) -> list[str]:
        """Every flag the command line accepts, from src/command-line.js.

        The file uses yargs: `.option('name', …)`, `.alias(…)`, `.describe(…)`.
        Long flags are single-dashed, `--foo` and `-f`, matching yargs.
        """
        text = self.read("src/command-line.js")
        names = set()

        for match in re.finditer(r"\.option\(\s*['\"]([^'\"]+)['\"]", text):
            names.add(match.group(1))
        for match in re.finditer(r"\.alias\(\s*['\"]([^'\"]+)['\"]", text):
            names.add(match.group(1))
        # The `command:` blocks describe positional arguments, not flags.
        for match in re.finditer(r"^\s{4}([a-z][a-zA-Z0-9]*)\s*:\s*\{", text, re.M):
            names.add(match.group(1))

        return sorted(n for n in names if n and not n.startswith("-"))

    # ── 3. SILLYTAVERN_* env vars ───────────────────────────────────────────

    def check_env_precedence(self) -> None:
        """Report that env outranks config.yaml, and what the module does.

        src/util.js getConfigValue checks process.env BEFORE the config object.
        A SILLYTAVERN_* variable therefore silently overrides the rendered
        config.yaml. If the module lets a user set one for a key it also
        exposes an option for, the option can be correct and still lose.

        The check looks for the *behaviour* — a membership test against
        process.env that short-circuits a return — rather than one exact
        spelling of it. A bare substring match is defeated by a refactor that
        renames the variable while keeping the semantics, and by one that keeps
        the string but changes the order.
        """
        util = self.read("src/util.js")

        env_test = re.search(
            r"(\w+)\s+in\s+process\.env", util
        ) or re.search(r"process\.env\[(\w+)\]", util)

        if not env_test:
            self.finding(
                "env",
                "SILLYTAVERN_* precedence",
                "src/util.js no longer contains a recognisable process.env "
                "lookup in getConfigValue. Upstream may have changed how "
                "config values are resolved — re-read src/util.js and update "
                "this audit before trusting the coverage report.",
                "high",
            )
            return

        # The decisive property is ORDER: the env read must come before the
        # config read inside getConfigValue.
        func = util[util.find("export function getConfigValue") :]
        env_at = func.find("process.env")
        config_at = func.find("getConfig()")

        if config_at == -1:
            self.notes.append(
                "getConfigValue no longer calls getConfig(); the precedence "
                "model in this audit needs re-checking against src/util.js."
            )
        elif env_at != -1 and env_at < config_at:
            # Hazard confirmed and still live — this is expected, and is why
            # the escape hatch and docs below matter.
            pass
        elif env_at != -1:
            self.notes.append(
                "getConfigValue appears to read config BEFORE env — upstream "
                "changed the precedence. Re-check whether the 'SILLYTAVERN_* "
                "overrides config.yaml' warning in COVERAGE.md is still true."
            )

        # The escape hatches that make the hazard safe.
        options = self.read("modules/options.nix")
        has_escape_hatch = "extraConfigEnv" in options
        docs = self.read("docs/installing.md") + self.read("docs/options.md")

        if not has_escape_hatch:
            self.finding(
                "env",
                "SILLYTAVERN_* precedence",
                "getConfigValue reads process.env before config.yaml, so an "
                "env var silently overrides the rendered config. No "
                "extraConfigEnv escape hatch found in modules/options.nix.",
                "high",
            )

        if "SILLYTAVERN_" not in docs:
            self.finding(
                "docs",
                "env precedence",
                "docs do not mention that SILLYTAVERN_* overrides "
                "config.yaml. This is the single most surprising behaviour of "
                "the config system.",
                "medium",
            )

    # ── 4. The Nix module's own surface ─────────────────────────────────────

    def nix_option_paths(self) -> list[str]:
        """Every option path the module declares, from Nix itself.

        Nix is the source of truth for the module's side: hand-parsing Nix is
        unreliable, and a stale parse here would report phantom gaps.

        The list comes from `lib.optionAttrSetToDocList`, nixpkgs' own
        supported introspection API, applied to a real evaluated system. It is
        used rather than a hand-rolled recursion because `system.options` is a
        tree whose leaves are option declarations but whose intermediate nodes
        also contain functions and paths; recursing by hand into every attrset
        walks off the end, and nixpkgs already solved this.
        """
        expr = (
            """
        let
          f = builtins.getFlake (toString %s);
          lib = f.inputs.nixpkgs.lib;
          system = lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              f.nixosModules.sillytavern
              { boot.loader.grub.enable = false;
                fileSystems."/" = { device = "/dev/null"; fsType = "tmpfs"; };
                nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
                system.stateVersion = "25.05"; }
            ];
          };
          docs = lib.optionAttrSetToDocList
            system.options.services.sillytavern-nixos;
        in builtins.filter (n: lib.hasPrefix "services.sillytavern-nixos." n)
             (map (d: d.name) docs)
        """
        ) % json.dumps(str(self.repo))

        completed = subprocess.run(
            ["nix", "eval", "--impure", "--json", "--expr", expr],
            capture_output=True,
            text=True,
            cwd=self.repo,
        )
        if completed.returncode != 0:
            raise SystemExit(
                "could not evaluate the module's options — is the tree broken?\n"
                + completed.stderr
            )
        return sorted(json.loads(completed.stdout))

        completed = subprocess.run(
            ["nix", "eval", "--impure", "--json", "--expr", expr],
            capture_output=True,
            text=True,
            cwd=self.repo,
        )
        if completed.returncode != 0:
            raise SystemExit(
                "could not evaluate the module's options — is the tree broken?\n"
                + completed.stderr
            )
        return sorted(json.loads(completed.stdout))

    # ── The audit ───────────────────────────────────────────────────────────

    def run(self) -> dict:
        config_keys = self.config_yaml_keys()
        cli_flags = self.cli_flags()
        options = self.nix_option_paths()
        settings_surface = self.settings_json_surface()

        self.check_env_precedence()

        # config.yaml coverage: an option exists for key K if any declared
        # option path ends with `.<K>` or equals it. Nesting differs between
        # upstream YAML and the module, so match on the leaf path suffix.
        option_set = set(options)
        config_prefix = "services.sillytavern-nixos.config."
        # The option's path below `config.`, or None if it is not under it.
        config_options = {
            opt[len(config_prefix) :] for opt in option_set if opt.startswith(config_prefix)
        }
        uncovered_keys = []
        for key in config_keys:
            # An option covers a config key only if it sits under `config` AND
            # its path from there matches. Matching on a bare leaf suffix
            # anywhere in the option set is far too loose: `cli.port` would
            # "cover" `config.port`, so renaming the config option would still
            # report full coverage.
            if key not in config_options:
                uncovered_keys.append(key)

        cli_prefix = "services.sillytavern-nixos.cli."
        cli_options = {
            opt[len(cli_prefix) :] for opt in option_set if opt.startswith(cli_prefix)
        }
        uncovered_flags = [flag for flag in cli_flags if flag not in cli_options]

        return {
            "config_keys_total": len(config_keys),
            "config_keys_covered": len(config_keys) - len(uncovered_keys),
            "uncovered_config_keys": uncovered_keys,
            "cli_flags_total": len(cli_flags),
            "cli_flags_covered": len(cli_flags) - len(uncovered_flags),
            "uncovered_cli_flags": uncovered_flags,
            "options_total": len(options),
            "options": options,
            "settings_json_fields_total": settings_surface["total"],
            "settings_json_subtrees": settings_surface["subtrees"],
            "settings_json_top_level_keys": settings_surface["top_level"],
            "findings": self.findings,
            "notes": self.notes,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=None, help="repository root")
    parser.add_argument("--json", action="store_true", help="machine-readable")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero when a gap is found (for CI)",
    )
    args = parser.parse_args()

    audit = Audit(repo_root(args.repo))
    result = audit.run()

    if args.json:
        print(json.dumps(result, indent=2))
        return 1 if (args.strict and result["findings"]) else 0

    uncovered_flags = result["uncovered_cli_flags"]

    cov = result["config_keys_total"]
    covered = result["config_keys_covered"]
    pct = (covered / cov * 100) if cov else 0.0

    cli_total = result["cli_flags_total"]
    cli_covered = result["cli_flags_covered"]
    cli_pct = (cli_covered / cli_total * 100) if cli_total else 0.0

    print("=" * 66)
    print("  Nix coverage audit — SillyTavern configuration surface")
    print("=" * 66)
    print(f"\nconfig.yaml keys   {covered}/{cov} covered ({pct:.1f}%)")
    print(f"CLI flags          {cli_covered}/{cli_total} covered ({cli_pct:.1f}%)")
    print(
        f"settings.json      {result['settings_json_fields_total']} leaf fields "
        f"over {len(result['settings_json_subtrees'])} UI subtrees "
        f"({result['settings_json_top_level_keys']} top-level keys)"
    )
    print(
        f"typed options      {result['settings_json_fields_total']} settings.json "
        f"fields have a typed option (generated from the same inventory)"
    )
    print(f"module options     {result['options_total']} declared in Nix")

    if result["uncovered_config_keys"]:
        print(f"\nKeys with no matching option ({len(result['uncovered_config_keys'])}):")
        for key in result["uncovered_config_keys"]:
            print(f"  - {key}")

    if uncovered_flags:
        print(f"\nCLI flags with no matching option ({len(uncovered_flags)}):")
        for flag in uncovered_flags:
            print(f"  - {flag}")

    for finding in result["findings"]:
        print(
            f"\n[{finding['severity'].upper()}] {finding['surface']}: "
            f"{finding['subject']}\n  {finding['detail']}"
        )

    for note in result["notes"]:
        print(f"\n  note: {note}")

    print()
    return 1 if (args.strict and result["findings"]) else 0


if __name__ == "__main__":
    sys.exit(main())