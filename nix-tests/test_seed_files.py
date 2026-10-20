#!/usr/bin/env python3
"""Tests for scripts/st_seed_files.py — the JSON-state seeder.

The behaviours worth pinning down here are the ones that would be *data loss*
if they broke: refusing to escape the data root, refusing to touch server
runtime state, deep-merging rather than replacing `settings.json`, and leaving
alone anything a user has already changed through the UI.
"""

from __future__ import annotations

import json
import os
import shutil
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import st_seed_files as seeder  # noqa: E402


def _repo_root() -> Path:
    """Where the application sources live.

    `ST_REPO_ROOT` when the sandboxed `seeder` check stages them, otherwise the
    checkout this file sits in. Exported rather than searched for, so a change
    in either place fails loudly instead of quietly finding nothing.
    """
    env = os.environ.get("ST_REPO_ROOT")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


class DeepMergeTests(unittest.TestCase):
    def test_merges_nested_objects_leaf_by_leaf(self):
        base = {"oai_settings": {"max_context": 4096, "stream": False}}
        patch = {"oai_settings": {"stream": True}}
        self.assertEqual(
            seeder.deep_merge(base, patch),
            {"oai_settings": {"max_context": 4096, "stream": True}},
        )

    def test_patch_wins_on_a_leaf(self):
        self.assertEqual(seeder.deep_merge({"a": 1}, {"a": 2}), {"a": 2})

    def test_a_list_in_the_patch_replaces_rather_than_merges(self):
        self.assertEqual(
            seeder.deep_merge({"tags": ["a", "b"]}, {"tags": ["c"]}), {"tags": ["c"]}
        )

    def test_an_object_replaces_a_scalar(self):
        self.assertEqual(seeder.deep_merge({"a": 1}, {"a": {"b": 2}}), {"a": {"b": 2}})

    def test_a_scalar_replaces_an_object(self):
        self.assertEqual(seeder.deep_merge({"a": {"b": 1}}, {"a": 5}), {"a": 5})

    def test_base_is_not_mutated(self):
        base = {"a": {"b": 1}}
        seeder.deep_merge(base, {"a": {"c": 2}})
        self.assertEqual(base, {"a": {"b": 1}})


class PathSafetyTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()

    def _assertRefused(self, rel):
        with self.assertRaises(seeder.SeedError):
            seeder.safe_join(self.root, rel)

    def _assertAccepted(self, rel):
        """`safe_join` returns a path rather than raising; a return IS acceptance."""
        self.assertTrue(seeder.safe_join(self.root, rel))

    def test_accepts_a_ordinary_relative_path(self):
        self.assertEqual(
            seeder.safe_join(self.root, "sysprompt/Roleplay.json"),
            os.path.join(os.path.realpath(self.root), "sysprompt/Roleplay.json"),
        )

    def test_accepts_spaces(self):
        seeder.safe_join(self.root, "TextGen Settings/Default.json")

    def test_refuses_parent_traversal(self):
        self._assertRefused("../escape.json")
        self._assertRefused("sysprompt/../../escape.json")
        self._assertRefused("a/b/../../../escape.json")

    def test_refuses_absolute_paths(self):
        self._assertRefused("/etc/passwd")

    def test_refuses_an_empty_path(self):
        self._assertRefused("")
        self._assertRefused("   ")

    def test_refuses_reserved_server_state(self):
        for rel in ("stats.json", "config.yaml", "default-user/stats.json"):
            with self.subTest(rel=rel):
                self._assertRefused(rel)

    def test_refuses_reserved_directories(self):
        for rel in ("_storage/x", "_webpack/y", "backups/settings.json"):
            with self.subTest(rel=rel):
                self._assertRefused(rel)

    # ── `_errors/` ───────────────────────────────────────────────────────────
    #
    # `_errors` used to be in RESERVED_TOP_LEVEL, which made branded error
    # pages unreachable from Nix: upstream serves four HTML files from
    # `DATA_ROOT/_errors` on exactly the paths an operator most wants to rebrand,
    # and the module could not override any of them. It is now open — but only to
    # the four filenames upstream actually reads, and only at the top level.
    #
    # These four names are hardcoded at four separate call sites in src/; a
    # change to any of them has to be reflected here or branding silently stops
    # applying, which is exactly what the refusal is here to prevent.

    def test_accepts_the_four_upstream_error_pages(self):
        for name in (
            "unauthorized.html",
            "forbidden-by-whitelist.html",
            "host-not-allowed.html",
            "url-not-found.html",
        ):
            with self.subTest(name=name):
                self._assertAccepted(f"_errors/{name}")

    def test_refuses_an_unknown_error_page(self):
        # Not read by the server anywhere: seeding it would create a file that
        # looks meaningful and is never served.
        for rel in ("_errors/evil.html", "_errors/z", "_errors/", "_errors/Untitled.txt"):
            with self.subTest(rel=rel):
                self._assertRefused(rel)

    def test_refuses_a_nested_error_page(self):
        # The basename alone would pass the allowlist; the depth check is what
        # stops `_errors/sub/x.html` from being accepted.
        self._assertRefused("_errors/sub/unauthorized.html")

    def test_error_page_allowlist_matches_upstream(self):
        # Reads the actual call sites in src/ rather than a second hardcoded
        # copy of the list.
        #
        # The previous version compared `seeder.ALLOWED_ERROR_PAGES` against a
        # literal that lived in this file, which could only fail if someone
        # edited the seeder and forgot to edit the test — it could not detect
        # upstream adding or removing an error page, which is the one thing its
        # own comment claimed to guard.
        #
        # Upstream hardcodes each page at a separate site in the source; grep
        # them out and compare as a set.
        repo_root = _repo_root()
        found = set()
        for js in (repo_root / "src").rglob("*.js"):
            text = js.read_text(encoding="utf-8", errors="replace")
            found |= {
                name
                # Upstream spells it `path.join(DATA_ROOT, '_errors', 'name.html')`
                # — the directory and the filename are two separate arguments,
                # so the join between them is a quote, a comma and a quote.
                for name in re.findall(
                    r"_errors['\"]\s*,\s*['\"]([\w-]+\.html)", text
                )
            }
        self.assertTrue(
            found,
            "no _errors/*.html references found under src/ — the grep is wrong, "
            "not the seeder",
        )
        self.assertEqual(
            seeder.ALLOWED_ERROR_PAGES,
            found,
            "the seeder's allowlist has drifted from src/; update "
            "scripts/st_seed_files.py",
        )
        self.assertNotIn("_errors", seeder.RESERVED_TOP_LEVEL)

    def test_reserved_names_match_the_nix_assertions(self):
        """The Nix side mirrors this deny-list; keep the two copies honest.

        `modules/assertions.nix` refuses the same paths at EVAL time, which is
        strictly better than refusing them at activation — but only if the two
        lists agree. Nothing else connects them, so this test is what stops the
        Nix copy silently going stale: change one without the other and this
        fails naming both.
        """
        repo_root = _repo_root()
        assertions = (repo_root / "modules" / "assertions.nix").read_text(
            encoding="utf-8"
        )

        for name in seeder.RESERVED_BASENAMES:
            with self.subTest(reserved=name):
                self.assertIn(
                    f'"{name}"', assertions, f"{name} is reserved in Python but "
                    "not mirrored in modules/assertions.nix",
                )

        for name in seeder.RESERVED_TOP_LEVEL:
            with self.subTest(reserved=name):
                self.assertIn(
                    f'"{name}"', assertions, f"{name} is reserved in Python but "
                    "not mirrored in modules/assertions.nix",
                )

        for name in seeder.ALLOWED_ERROR_PAGES:
            with self.subTest(error_page=name):
                self.assertIn(
                    f'"{name}"', assertions, f"{name} is allowlisted in Python "
                    "but not mirrored in modules/assertions.nix",
                )

    def test_traversal_that_normalises_back_inside_is_still_refused(self):
        # `a/../b` stays inside the root, but the `..` is still a caller mistake
        # worth surfacing rather than quietly resolving.
        self._assertRefused("a/../b.json")


class SpecEntryTests(unittest.TestCase):
    def test_rejects_an_entry_with_both_json_and_path(self):
        with self.assertRaises(seeder.SeedError):
            seeder.payload_for({"json": {"a": 1}, "path": "/nix/store/x"})

    def test_rejects_an_entry_with_neither(self):
        with self.assertRaises(seeder.SeedError):
            seeder.payload_for({"type": "setAt"})

    def test_json_payload_is_pretty_printed_with_a_trailing_newline(self):
        out = seeder.payload_for({"json": {"a": 1}})
        self.assertEqual(out, b'{\n  "a": 1\n}\n')

    def test_json_payload_preserves_non_ascii(self):
        out = seeder.payload_for({"json": {"name": "café ☕"}})
        self.assertIn("café ☕".encode("utf-8"), out)

    def test_json_payload_serialises_arrays(self):
        self.assertEqual(seeder.payload_for({"json": [1, 2]}), b"[\n  1,\n  2\n]\n")

    def test_path_payload_is_copied_verbatim(self):
        with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as fh:
            fh.write(b'{"verbatim":true}\n')
            src = fh.name
        try:
            self.assertEqual(seeder.payload_for({"path": src}), b'{"verbatim":true}\n')
        finally:
            os.unlink(src)


class SeedBehaviourTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.stats = {"written": 0, "skipped": 0}

    def tearDown(self):
        self.tmp.cleanup()

    def seed(self, rel, content, policy="missing"):
        seeder.seed_file(str(self.root), rel, content, policy, False, self.stats)

    # ── policy ────────────────────────────────────────────────────────────────

    def test_missing_policy_creates_a_file_that_is_not_there(self):
        self.seed("themes/Azure.json", {"json": {"p": 1}})
        self.assertEqual(self.stats["written"], 1)
        self.assertEqual(
            json.loads((self.root / "themes/Azure.json").read_text()), {"p": 1}
        )

    def test_missing_policy_leaves_an_existing_file_alone(self):
        self.seed("themes/Azure.json", {"json": {"p": 1}})
        self.seed("themes/Azure.json", {"json": {"p": 2}})
        self.assertEqual(self.stats["skipped"], 1)
        self.assertEqual(
            json.loads((self.root / "themes/Azure.json").read_text()), {"p": 1}
        )

    def test_overwrite_policy_restores_the_declared_value(self):
        self.seed("themes/Azure.json", {"json": {"p": 1}})
        self.seed("themes/Azure.json", {"json": {"p": 2}}, policy="overwrite")
        self.assertEqual(
            json.loads((self.root / "themes/Azure.json").read_text()), {"p": 2}
        )

    def test_a_ui_edit_survives_the_default_policy(self):
        # The scenario the default exists for: a user tweaks a preset in the UI,
        # then a rebuild happens.
        self.seed("sysprompt/x.json", {"json": {"content": "declared"}})
        (self.root / "sysprompt/x.json").write_text('{"content":"edited in the UI"}')
        self.seed("sysprompt/x.json", {"json": {"content": "declared"}})
        self.assertEqual(
            json.loads((self.root / "sysprompt/x.json").read_text()),
            {"content": "edited in the UI"},
        )

    # ── file mechanics ────────────────────────────────────────────────────────

    def test_written_files_are_owner_only(self):
        self.seed("settings-ish.json", {"json": {"k": "v"}})
        mode = stat.S_IMODE((self.root / "settings-ish.json").stat().st_mode)
        self.assertEqual(mode, 0o600)

    def test_no_temp_files_are_left_behind(self):
        self.seed("themes/Azure.json", {"json": {"p": 1}})
        leftovers = [p.name for p in self.root.rglob(".seed-*")]
        self.assertEqual(leftovers, [])

    def test_dry_run_writes_nothing(self):
        seeder.seed_file(str(self.root), "themes/Azure.json", {"json": {"p": 1}}, "missing", True, self.stats)
        self.assertFalse((self.root / "themes/Azure.json").exists())


class SettingsMergeTests(unittest.TestCase):
    """settings.json is deep-merged under BOTH policies."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.user = Path(self.tmp.name) / "seanc"
        self.user.mkdir(parents=True)
        self.stats = {"written": 0, "skipped": 0}

    def tearDown(self):
        self.tmp.cleanup()

    def test_creates_settings_json_when_absent(self):
        seeder.seed_settings(str(self.user), {"main_api": "custom"}, "missing", False, self.stats)
        self.assertEqual(
            json.loads((self.user / "settings.json").read_text()), {"main_api": "custom"}
        )

    def test_preserves_keys_the_module_never_declared(self):
        write_json(self.user / "settings.json", {"unknown_future_key": 42})
        seeder.seed_settings(str(self.user), {"main_api": "custom"}, "missing", False, self.stats)
        out = json.loads((self.user / "settings.json").read_text())
        self.assertEqual(out, {"unknown_future_key": 42, "main_api": "custom"})

    def test_merges_a_nested_override_without_dropping_its_siblings(self):
        write_json(self.user / "settings.json", {"oai_settings": {"max_context": 4096, "stream": False}})
        seeder.seed_settings(str(self.user), {"oai_settings": {"stream": True}}, "missing", False, self.stats)
        self.assertEqual(
            json.loads((self.user / "settings.json").read_text()),
            {"oai_settings": {"max_context": 4096, "stream": True}},
        )

    def test_overwrite_policy_still_does_not_drop_unknown_keys(self):
        write_json(self.user / "settings.json", {"typed_by_a_human": {"keep": "me"}})
        seeder.seed_settings(str(self.user), {"main_api": "custom"}, "overwrite", False, self.stats)
        self.assertEqual(
            json.loads((self.user / "settings.json").read_text()),
            {"typed_by_a_human": {"keep": "me"}, "main_api": "custom"},
        )

    def test_a_no_op_merge_is_skipped_not_rewritten(self):
        write_json(self.user / "settings.json", {"a": 1})
        before = (self.user / "settings.json").stat().st_mtime_ns
        seeder.seed_settings(str(self.user), {"a": 1}, "missing", False, self.stats)
        self.assertEqual(self.stats["skipped"], 1)
        self.assertEqual((self.user / "settings.json").stat().st_mtime_ns, before)

    def test_refuses_to_overwrite_unparseable_settings(self):
        # A hand-edit with a typo must not be silently destroyed.
        (self.user / "settings.json").write_text("{ this is not json")
        with self.assertRaises(seeder.SeedError):
            seeder.seed_settings(str(self.user), {"a": 1}, "overwrite", False, self.stats)
        self.assertEqual((self.user / "settings.json").read_text(), "{ this is not json")

    def test_refuses_a_settings_json_that_is_not_an_object(self):
        (self.user / "settings.json").write_text("[1, 2, 3]")
        with self.assertRaises(seeder.SeedError):
            seeder.seed_settings(str(self.user), {"a": 1}, "overwrite", False, self.stats)


class SecretsTests(unittest.TestCase):
    """`secrets.json` — the provider API keys 1.19 moved out of settings.json."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.user = self.root / "seanc"
        self.user.mkdir()
        self.stats = {"written": 0, "skipped": 0}
        self.keyfile = self.root / "openai.key"
        self.keyfile.write_text("sk-live-ABCDEF\n")

    def tearDown(self):
        self.tmp.cleanup()

    def seed(self, secrets, policy="missing"):
        return seeder.seed_secrets(str(self.user), secrets, policy, False, self.stats)

    def secrets_json(self):
        return json.loads((self.user / "secrets.json").read_text())

    # ── shape ─────────────────────────────────────────────────────────────────

    def test_writes_the_shape_the_server_reads(self):
        # src/endpoints/secrets.js stores an ARRAY per key and only sends the
        # `active` entry upstream, so a flat map would be silently ignored.
        self.seed({"api_key_openai": {"value": str(self.keyfile)}})
        doc = self.secrets_json()
        self.assertEqual(list(doc), ["api_key_openai"])
        entry = doc["api_key_openai"][0]
        self.assertEqual(entry["value"], "sk-live-ABCDEF")
        self.assertTrue(entry["active"])
        self.assertEqual(entry["label"], "api_key_openai")
        self.assertTrue(entry["id"])  # uuid, so the UI can address the entry

    def test_label_defaults_to_the_key(self):
        self.seed({"api_key_claude": {"value": str(self.keyfile)}})
        self.assertEqual(self.secrets_json()["api_key_claude"][0]["label"], "api_key_claude")

    def test_label_can_be_set(self):
        self.seed({"api_key_claude": {"value": str(self.keyfile), "label": "work"}})
        self.assertEqual(self.secrets_json()["api_key_claude"][0]["label"], "work")

    def test_strips_the_trailing_newline(self):
        # An API key with a stray \n 401s, which is indistinguishable from a
        # bad key in every provider's error message.
        self.seed({"api_key_novel": {"value": str(self.keyfile)}})
        self.assertEqual(self.secrets_json()["api_key_novel"][0]["value"], "sk-live-ABCDEF")

    def test_indent_matches_what_the_server_writes(self):
        # _writeSecretsFile uses 4 spaces and no trailing newline.
        self.seed({"api_key_openai": {"value": str(self.keyfile)}})
        raw = (self.user / "secrets.json").read_text()
        # `id` is the 3rd level of nesting, so it sits at 12 spaces.
        self.assertIn('\n            "id"', raw)
        self.assertFalse(raw.endswith("\n"))

    # ── safety ────────────────────────────────────────────────────────────────

    def test_never_reads_a_value_outside_the_spec(self):
        # The spec carries a PATH. There is no code path that inlines a literal,
        # which is what keeps the key out of the Nix store.
        self.seed({"api_key_openai": {"value": str(self.keyfile)}})
        self.assertNotIn("/tmp", json.dumps(self.secrets_json()))

    def test_refuses_a_missing_key_file_with_a_pointed_message(self):
        with self.assertRaises(seeder.SeedError) as ctx:
            self.seed({"api_key_openai": {"value": str(self.root / "nope")}})
        msg = str(ctx.exception)
        self.assertIn("api_key_openai", msg)
        self.assertIn("agenix", msg)  # the likely cause, named

    def test_refuses_an_entry_without_a_value(self):
        with self.assertRaises(seeder.SeedError):
            self.seed({"api_key_openai": {"label": "work"}})

    def test_refuses_to_touch_a_corrupt_secrets_file(self):
        (self.user / "secrets.json").write_text("{not json")
        with self.assertRaises(seeder.SeedError):
            self.seed({"api_key_openai": {"value": str(self.keyfile)}})

    def test_secrets_json_cannot_be_seeded_through_files(self):
        # Otherwise there are two writers for one file.
        for rel in ("secrets.json", "sub/secrets.json"):
            with self.assertRaises(seeder.SeedError):
                seeder.safe_join(str(self.root), rel)

    # ── idempotence and UI interaction ────────────────────────────────────────

    def test_second_run_is_a_no_op(self):
        self.seed({"api_key_openai": {"value": str(self.keyfile)}})
        first = (self.user / "secrets.json").read_text()
        self.stats["written"] = self.stats["skipped"] = 0
        self.seed({"api_key_openai": {"value": str(self.keyfile)}})
        self.assertEqual((self.user / "secrets.json").read_text(), first)
        self.assertEqual(self.stats["written"], 0)
        self.assertEqual(self.stats["skipped"], 1)

    def test_does_not_override_a_key_set_in_the_ui_by_default(self):
        (self.user / "secrets.json").write_text(
            json.dumps({"api_key_openai": [{"id": "x", "value": "typed-by-hand", "label": "ui", "active": True}]})
        )
        self.seed({"api_key_openai": {"value": str(self.keyfile)}})
        entries = self.secrets_json()["api_key_openai"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["value"], "typed-by-hand")

    def test_overwrite_deactivates_rather_than_deletes(self):
        # The UI's key manager shows history; deleting an entry loses it.
        (self.user / "secrets.json").write_text(
            json.dumps({"api_key_openai": [{"id": "old", "value": "typed-by-hand", "label": "ui", "active": True}]})
        )
        self.seed({"api_key_openai": {"value": str(self.keyfile)}}, policy="overwrite")
        entries = self.secrets_json()["api_key_openai"]
        self.assertEqual(len(entries), 2)
        self.assertFalse(entries[0]["active"])
        self.assertEqual(entries[0]["value"], "typed-by-hand")
        self.assertTrue(entries[1]["active"])

    def test_preserves_other_keys_and_inactive_history(self):
        (self.user / "secrets.json").write_text(
            json.dumps(
                {
                    "api_key_claude": [
                        {"id": "a", "value": "old", "label": "l", "active": False},
                        {"id": "b", "value": "current", "label": "l", "active": True},
                    ]
                }
            )
        )
        self.seed({"api_key_openai": {"value": str(self.keyfile)}})
        doc = self.secrets_json()
        self.assertEqual(sorted(doc), ["api_key_claude", "api_key_openai"])
        self.assertEqual(len(doc["api_key_claude"]), 2)  # untouched

    def test_multiple_keys_in_one_pass(self):
        other = self.root / "claude.key"
        other.write_text("sk-ant-XYZ")
        self.seed(
            {
                "api_key_openai": {"value": str(self.keyfile)},
                "api_key_claude": {"value": str(other)},
            }
        )
        doc = self.secrets_json()
        self.assertEqual(doc["api_key_openai"][0]["value"], "sk-live-ABCDEF")
        self.assertEqual(doc["api_key_claude"][0]["value"], "sk-ant-XYZ")

    # ── through the full spec ─────────────────────────────────────────────────

    def test_reachable_through_apply_spec(self):
        spec = {"users": {"seanc": {"secrets": {"api_key_openai": {"value": str(self.keyfile)}}}}}
        seeder.apply_spec(spec, str(self.root), "missing", False)
        self.assertEqual(self.secrets_json()["api_key_openai"][0]["value"], "sk-live-ABCDEF")

    def test_settings_and_secrets_coexist_in_one_spec(self):
        spec = {
            "users": {
                "seanc": {
                    "settings": {"main_api": "custom"},
                    "secrets": {"api_key_openai": {"value": str(self.keyfile)}},
                }
            }
        }
        seeder.apply_spec(spec, str(self.root), "missing", False)
        self.assertEqual(
            json.loads((self.user / "settings.json").read_text())["main_api"], "custom"
        )
        self.assertIn("api_key_openai", self.secrets_json())


class DirectoryTreeTests(unittest.TestCase):
    """A per-account UI extension is a DIRECTORY, not a file.

    `src/endpoints/extensions.js` installs one into
    `<user>/extensions/<name>/` as a tree of JS plus a manifest. Before this,
    pointing `path` at a directory failed with `Is a directory` — and because
    that is an `OSError` rather than a `SeedError` it exited 1 and stopped the
    whole activation's seeding, so one extension in `files.byUser` took the
    service down with it.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)

        self.src = os.path.join(self.tmp, "src-ext")
        os.makedirs(os.path.join(self.src, "lib"))
        self.write(os.path.join(self.src, "manifest.json"), '{"display_name":"Mine"}')
        self.write(os.path.join(self.src, "index.js"), "console.log(1)\n")
        self.write(os.path.join(self.src, "lib", "helper.js"), "export default 1\n")

        self.root = os.path.join(self.tmp, "data")
        os.makedirs(os.path.join(self.root, "zoe"))

    def write(self, path: str, text: str) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def read(self, path: str) -> str:
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def spec(self, rel: str, **extra) -> str:
        path = os.path.join(self.tmp, "spec.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {"users": {"zoe": {"files": {rel: {"path": self.src, **extra}}}}}, fh
            )
        return path

    def run_seed(self, rel: str, policy: str = "missing", **extra) -> int:
        return subprocess.call(
            [
                sys.executable,
                os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts", "st_seed_files.py"),
                "--data-root", self.root,
                "--spec", self.spec(rel, **extra),
                "--policy", policy,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def target(self, rel: str) -> str:
        return os.path.join(self.root, "zoe", rel)

    def test_copies_the_whole_tree(self) -> None:
        target = self.target("extensions/mine")
        self.assertEqual(self.run_seed("extensions/mine"), 0)
        self.assertEqual(self.read(os.path.join(target, "manifest.json")), '{"display_name":"Mine"}')
        self.assertEqual(self.read(os.path.join(target, "lib", "helper.js")), "export default 1\n")

    def test_applies_the_entry_mode_to_every_file(self) -> None:
        target = self.target("extensions/mine")
        self.run_seed("extensions/mine", mode="0644")
        for rel in ("manifest.json", "index.js", "lib/helper.js"):
            mode = stat.S_IMODE(os.stat(os.path.join(target, rel)).st_mode)
            self.assertEqual(oct(mode), oct(0o644), rel)

    def test_missing_policy_leaves_an_existing_tree_alone(self) -> None:
        target = self.target("extensions/mine")
        self.run_seed("extensions/mine")
        self.write(os.path.join(target, "index.js"), "// edited by the user\n")
        self.run_seed("extensions/mine", policy="missing")
        self.assertEqual(self.read(os.path.join(target, "index.js")), "// edited by the user\n")

    def test_overwrite_policy_restores_it(self) -> None:
        target = self.target("extensions/mine")
        self.run_seed("extensions/mine")
        self.write(os.path.join(target, "index.js"), "// edited by the user\n")
        self.run_seed("extensions/mine", policy="overwrite")
        self.assertEqual(self.read(os.path.join(target, "index.js")), "console.log(1)\n")

    def test_overwrite_never_deletes_files_the_source_dropped(self) -> None:
        # A seed, not a sync: removing a file from the Nix expression must not
        # delete somebody's work from their account.
        target = self.target("extensions/mine")
        self.run_seed("extensions/mine")
        extra = os.path.join(target, "notes.md")
        self.write(extra, "mine\n")
        os.remove(os.path.join(self.src, "index.js"))
        self.run_seed("extensions/mine", policy="overwrite")
        self.assertTrue(os.path.exists(extra))

    def test_a_regular_file_still_works(self) -> None:
        plain = os.path.join(self.tmp, "theme.json")
        self.write(plain, "{}")
        with open(self.spec("themes/t.json"), "w", encoding="utf-8") as fh:
            json.dump({"users": {"zoe": {"files": {"themes/t.json": {"path": plain}}}}}, fh)
        code = subprocess.call(
            [
                sys.executable,
                os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts", "st_seed_files.py"),
                "--data-root", self.root,
                "--spec", os.path.join(self.tmp, "spec.json"),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.assertEqual(code, 0)
        self.assertEqual(self.read(self.target("themes/t.json")), "{}")


class PerEntryOverridesTests(unittest.TestCase):
    """`policy` and `mode` on a single entry — used by `_css/user.css`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.stats = {"written": 0, "skipped": 0}
        self.src = self.root / "in.css"
        self.src.write_text("body { color: red; }\n")

    def tearDown(self):
        self.tmp.cleanup()

    def seed(self, content, policy="missing"):
        return seeder.seed_file(str(self.root), "_css/user.css", content, policy, False, self.stats)

    # ── mode ──────────────────────────────────────────────────────────────────

    def test_default_mode_is_owner_only(self):
        self.seed({"path": str(self.src)})
        self.assertEqual((self.root / "_css/user.css").stat().st_mode & 0o777, 0o600)

    def test_mode_overrides_the_default(self):
        # `_css/user.css` is handed to every visitor by `res.sendFile`; 0600
        # would be wrong there even though it is right for settings.json.
        self.seed({"path": str(self.src), "mode": "0644"})
        self.assertEqual((self.root / "_css/user.css").stat().st_mode & 0o777, 0o644)

    def test_mode_is_parsed_as_octal(self):
        # 0o0640 vs the decimal reading of the same four characters (0o1130)
        # differ, so this catches a decimal parse.
        seeder.seed_file(str(self.root), "x.css", {"path": str(self.src), "mode": "0640"}, "missing", False, self.stats)
        self.assertEqual((self.root / "x.css").stat().st_mode & 0o777, 0o640)

    def test_rejects_a_bad_mode(self):
        for bad in ("644", "0999", 6440, "abc", "0o644"):
            with self.subTest(mode=bad):
                with self.assertRaises(seeder.SeedError):
                    seeder.seed_file(str(self.root), "y.css", {"path": str(self.src), "mode": bad}, "missing", False, self.stats)

    def test_mode_applies_on_overwrite_too(self):
        self.seed({"path": str(self.src), "mode": "0644"})
        os.chmod(self.root / "_css/user.css", 0o600)  # simulate a tampered mode
        self.src.write_text("body { color: blue; }\n")
        self.seed({"path": str(self.src), "mode": "0644"}, policy="overwrite")
        self.assertEqual((self.root / "_css/user.css").stat().st_mode & 0o777, 0o644)

    # ── policy ────────────────────────────────────────────────────────────────

    def test_policy_overwrite_ignores_the_cli_default(self):
        # This is the whole reason the override exists: seedPolicy defaults to
        # "missing", which would freeze the first CSS version in place.
        self.seed({"path": str(self.src), "policy": "overwrite"})
        self.src.write_text("body { color: blue; }\n")
        self.seed({"path": str(self.src), "policy": "overwrite"})
        self.assertEqual((self.root / "_css/user.css").read_text(), "body { color: blue; }\n")
        self.assertEqual(self.stats["written"], 2)

    def test_missing_entry_honours_the_cli_default(self):
        self.seed({"path": str(self.src)})
        self.src.write_text("changed\n")
        self.seed({"path": str(self.src)})
        self.assertEqual((self.root / "_css/user.css").read_text(), "body { color: red; }\n")
        self.assertEqual(self.stats["skipped"], 1)

    def test_entry_policy_overwrite_works_under_a_missing_cli_default(self):
        # The module's actual configuration: seedPolicy="missing" globally,
        # policy="overwrite" on the one file that needs it.
        self.seed({"path": str(self.src), "policy": "overwrite"}, policy="missing")
        self.src.write_text("v2\n")
        self.seed({"path": str(self.src), "policy": "overwrite"}, policy="missing")
        self.assertEqual((self.root / "_css/user.css").read_text(), "v2\n")

    def test_rejects_a_bad_policy(self):
        with self.assertRaises(seeder.SeedError):
            self.seed({"path": str(self.src), "policy": "always"})

    def test_overrides_survive_the_full_spec(self):
        spec = {
            "dataRootFiles": {
                "_css/user.css": {"path": str(self.src), "policy": "overwrite", "mode": "0644"}
            }
        }
        seeder.apply_spec(spec, str(self.root), "missing", False)
        target = self.root / "_css/user.css"
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        self.src.write_text("v2\n")
        seeder.apply_spec(spec, str(self.root), "missing", False)
        self.assertEqual(target.read_text(), "v2\n")


class CliTests(unittest.TestCase):
    """End-to-end through main(), which is what the preStart script runs."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.spec = self.root / "spec.json"
        (self.root / "user").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *extra):
        return seeder.main(
            ["--data-root", str(self.root), "--spec", str(self.spec), *extra]
        )

    def test_end_to_end_create_then_leave_alone(self):
        write_json(
            self.spec,
            {
                "users": {
                    "user": {
                        "settings": {"oai_settings": {"max_context": 8192}},
                        "files": {
                            "sysprompt/Roleplay.json": {"json": {"content": "hi"}},
                            "TextGen Settings/Default.json": {"json": [{"a": 1}]},
                        },
                    }
                }
            },
        )
        self.assertEqual(self.run_cli(), 0)
        settings = json.loads((self.root / "user/settings.json").read_text())
        self.assertEqual(settings["oai_settings"]["max_context"], 8192)
        self.assertEqual(
            json.loads((self.root / "user/sysprompt/Roleplay.json").read_text()),
            {"content": "hi"},
        )
        # second run must change nothing
        self.assertEqual(self.run_cli(), 0)
        self.assertEqual(
            json.loads((self.root / "user/settings.json").read_text()), settings
        )

    def test_data_root_level_files(self):
        write_json(self.spec, {"dataRootFiles": {"shared/thing.json": {"json": {"v": 1}}}})
        self.assertEqual(self.run_cli(), 0)
        self.assertEqual(
            json.loads((self.root / "shared/thing.json").read_text()), {"v": 1}
        )

    def test_a_traversing_spec_exits_nonzero_and_writes_nothing(self):
        write_json(
            self.spec,
            {"dataRootFiles": {"../../pwned.json": {"json": {"v": 1}}}},
        )
        self.assertEqual(self.run_cli(), 2)
        self.assertFalse((Path(self.tmp.name).parent / "pwned.json").exists())

    def test_a_reserved_target_exits_nonzero(self):
        write_json(self.spec, {"dataRootFiles": {"stats.json": {"json": {"v": 1}}}})
        self.assertEqual(self.run_cli(), 2)

    def test_dry_run_creates_nothing(self):
        write_json(self.spec, {"dataRootFiles": {"x.json": {"json": {"v": 1}}}})
        self.assertEqual(self.run_cli("--dry-run"), 0)
        self.assertFalse((self.root / "x.json").exists())

    def test_a_bad_spec_path_exits_one(self):
        rc = seeder.main(["--data-root", str(self.root), "--spec", str(self.root / "nope.json")])
        self.assertEqual(rc, 1)

    def test_runs_as_a_subprocess(self):
        # The preStart script invokes it as `python3 scripts/st_seed_files.py …`,
        # so the shebang/exec path deserves one real invocation.
        write_json(self.spec, {"dataRootFiles": {"x.json": {"json": {"v": 1}}}})
        proc = subprocess.run(
            [
                sys.executable,
                str(REPO / "scripts" / "st_seed_files.py"),
                "--data-root",
                str(self.root),
                "--spec",
                str(self.spec),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("written", proc.stderr)
        self.assertTrue((self.root / "x.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)