#!/usr/bin/env python3
"""Pin lib.keyToEnv against upstream's real keyToEnv.

`lib/default.nix` reimplements `keyToEnv` from `src/util.js` rather than
deriving it, because Nix cannot import a JS function. Nothing forces the two to
agree. Getting it wrong is silent: every ``SILLYTAVERN_*`` environment override
simply stops taking effect, with no error, no warning, and no failed
evaluation.

So this check compares them. Node computes the expected value by running the
actual upstream function, read out of the real source file. Nix computes the
actual value by evaluating the real expression from ``lib/default.nix``. The
cases are generated from upstream's own ``default/config.yaml`` rather than
hand-written, so a key added upstream is covered the next time this runs.

The Nix side is extracted by ``nix eval --expr`` on the snippet that
``lib/tests.nix`` copies out of the library; there is deliberately no second
copy of the mapping in the test.
"""

from __future__ import annotations

import json

import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_YAML = HERE / "config.yaml"

# Keys that are awkward on purpose. The upstream function uppercases and turns
# '.' into '_', and does NOT split camelCase — so `enableCorsProxy` becomes
# SILLYTAVERN_ENABLECORSPROXY, with no underscore before CORSPROXY. That
# irregularity is the whole reason this check exists, so the cases that would
# catch a well-meaning "cleanup" are pinned explicitly rather than left to
# whatever the YAML happens to contain.
#
# The Nix side of this check computes its own case list, in lib/tests.nix
# (`edgeCases`). Both lists must agree: `main()` asserts that every key here
# has a mapping on the Nix side, so a key added to one and not the other fails
# the build rather than being silently skipped.
EDGE_CASES = [
    "extensions.models.speechToText",
    "browserLaunch.enabled",
    "enableCorsProxy",
    "basicAuthMode",
    "requestProxyBypass",
    "logging.accessLog",
    "unstable_forwardProxyMode",
    "extensionSettings",
    "a.b.c.d.e",
    "already_upper",
    "with_underscore",
    "Mixed_Case.Key",
]


def config_key_paths(path: Path) -> list[str]:
    """Top-level and second-level dotted key paths from default/config.yaml.

    Two levels is deliberate. The module's option surface tracks the shape of
    the real document, and the deeper keys follow from their parent. Flattening
    the whole file would produce hundreds of paths that differ only in a leaf
    nobody configures.
    """
    top: list[str] = []
    second: list[str] = []
    current: str | None = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue

        # Indent 0: a top-level key.
        if not raw.startswith((" ", "\t", "-")):
            match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", raw)
            if match:
                current = str(match.group(1))
                top.append(current)
                continue

        # Indent 2 and a mapping key (not a list item): a second-level key.
        match = re.match(r"^  ([A-Za-z_][A-Za-z0-9_]*):", raw)
        if match and current is not None:
            second.append(f"{current}.{match.group(1)}")

    return top + second


def upstream_key_to_env(node: str, keys: list[str]) -> dict[str, str]:
    """Run upstream's actual keyToEnv, extracted from the real source."""
    source = Path("src/util.js")
    if not source.exists():
        raise SystemExit("src/util.js not found — cannot verify against upstream")

    body = source.read_text(encoding="utf-8")
    match = re.search(
        r"export const keyToEnv = \(key\)\s*=>\s*(.+?);\s*$", body, re.MULTILINE | re.DOTALL
    )
    if not match:
        raise SystemExit("could not locate keyToEnv in src/util.js — upstream changed?")

    # Evaluate the real expression, but as a named export we can require.
    script = (
        "const keyToEnv = (key) => "
        + match.group(1)
        + ";\n"
        "const keys = JSON.parse(process.argv[1]);\n"
        "const out = {};\n"
        "for (const k of keys) out[k] = keyToEnv(k);\n"
        "console.log(JSON.stringify(out));\n"
    )

    completed = subprocess.run(
        [node, "-e", script, json.dumps(keys)],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)


def nix_key_to_env(_keys: list[str]) -> dict[str, str]:
    """Load the Nix side of the comparison, computed at EVAL time.

    `lib/tests.nix` evaluates the real `lib/default.nix` on the host, where
    `nix eval` works, and passes the resulting mapping in as JSON. It is not
    computed here because a build sandbox has no writable
    `/nix/var/nix/profiles`: both `nix eval` and `nix-instantiate` fail inside
    one with "Permission denied". Splitting the work this way means the Nix
    half still comes from the shipped library, not from a copy.
    """
    side_file = HERE / "key_to_env_from_nix.json"
    if not side_file.exists():
        raise SystemExit(
            "key_to_env_from_nix.json not found — lib/tests.nix did not copy it"
        )
    return json.loads(side_file.read_text(encoding="utf-8"))


def main() -> int:
    node = shutil.which("node")
    if not node:
        raise SystemExit("node not found — cannot verify against upstream")

    keys = config_key_paths(CONFIG_YAML)
    if not keys:
        raise SystemExit("no keys parsed from config.yaml — parser is broken")
    keys += EDGE_CASES

    # Dedupe, preserve order.
    keys = list(dict.fromkeys(keys))

    expected = upstream_key_to_env(node, keys)
    actual = nix_key_to_env(keys)

    failures = [k for k in keys if expected.get(k) != actual.get(k)]

    print(f"libHelpers: compared {len(keys)} keyToEnv cases against upstream")
    print(f"  from default/config.yaml : {len(keys) - len(EDGE_CASES)}")
    print(f"  edge cases               : {len(EDGE_CASES)}")

    # If the Nix side is missing a key the comparison cannot catch it, because
    # both `.get()` calls would return None and compare equal.
    uncovered = [k for k in keys if k not in actual]
    if uncovered:
        print(
            f"\nFAIL: the Nix side produced no mapping for {len(uncovered)} key(s):",
            file=sys.stderr,
        )
        for key in uncovered[:20]:
            print(f"  {key}", file=sys.stderr)
        return 1

    if failures:
        print(f"\nFAIL: {len(failures)} mapping(s) differ from upstream:", file=sys.stderr)
        for key in failures[:20]:
            print(f"  {key}", file=sys.stderr)
            print(f"    upstream: {expected.get(key)}", file=sys.stderr)
            print(f"    nix     : {actual.get(key)}", file=sys.stderr)
        if len(failures) > 20:
            print(f"  … and {len(failures) - 20} more", file=sys.stderr)
        return 1

    print("  all mappings agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())