# tests/test_seed_users.py
"""Tests for scripts/st_seed_users.py.

These live in `nix-tests/`, NOT in `tests/` — that directory is UPSTREAM'S
JavaScript suite (jest + playwright), and adding a Python file to it would
make the flake check copy the entire JS test corpus, including its own
node_modules-installing package.json, into the sandbox.

The load-bearing test here is ``test_hash_matches_node``. Everything else about
the seeder can be reasoned about; whether Python's scrypt agrees with Node's is
the one fact that decides whether a Nix-declared password can ever be logged in
with, and "probably" is not good enough — so it is checked against Node itself
when Node is available, and against a hard-coded digest Node produced when it is
not.

Run with:  python3 -m pytest tests/ -v
       or: python3 tests/test_seed_users.py      (stdlib unittest, no pytest needed)
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import st_seed_users as seeder  # noqa: E402


# Produced by Node, not by this project:
#
#   node -e "const c=require('crypto');
#     process.stdout.write(
#       c.scryptSync('correct horse battery staple'.normalize(),
#                     'c2FsdHNhbHRzYWx0c2E=', 64).toString('base64'))"
#
# Hard-coded so the vector is still checked when Node is not installed (CI images
# frequently do not have it). `test_matches_node` recomputes it live when Node
# IS available, so the two cannot drift apart silently.
NODE_SCRYPT_VECTOR = (
    "correct horse battery staple",
    "c2FsdHNhbHRzYWx0c2E=",
    "w7kT+hjk0oJr9FmGhT7Yl+rc8O+j7X0R3cgnvbhy80LO3t/LYiBL0O2aYkg/7FrQm4iAaatMluuTbIJquXmBgA==",
)


def have_node() -> bool:
    return shutil.which("node") is not None


class TestHashing(unittest.TestCase):
    def test_matches_hardcoded_node_vector(self):
        """Python's digest must equal the one Node produced, verbatim."""
        password, salt, expected = NODE_SCRYPT_VECTOR
        self.assertEqual(seeder.password_hash(password, salt), expected)

    def test_normalises_to_nfc(self):
        """A decomposed password must hash the same as its composed form.

        JavaScript's String.prototype.normalize() is NFC. Without the matching
        normalisation here, a password typed with a combining accent would hash
        to something the server can never reproduce — the user sets a password,
        it appears to be accepted, and login always fails.
        """
        # Built from escapes on purpose. A literal "café" written as "e" plus a
        # combining acute looks identical in source and is silently normalised
        # to the composed form by most editors, which would make this test pass
        # vacuously.
        composed = "caf\u00e9"  # U+00E9 LATIN SMALL LETTER E WITH ACUTE
        decomposed = "cafe\u0301"  # "e" + U+0301 COMBINING ACUTE ACCENT
        self.assertNotEqual(composed, decomposed)
        salt = "AAAAAAAAAAAAAAAAAAAAAAAA"
        self.assertEqual(
            seeder.password_hash(composed, salt),
            seeder.password_hash(decomposed, salt),
        )

    def test_salt_is_base64_of_16_bytes(self):
        salt = seeder.new_salt()
        self.assertEqual(len(base64.b64decode(salt)), seeder.SALT_BYTES)
        self.assertNotEqual(salt, seeder.new_salt())

    @unittest.skipUnless(have_node(), "node is not on PATH")
    def test_matches_node(self):
        """Cross-check against Node directly, over a range of awkward inputs."""
        script = (
            "const c=require('crypto');"
            "const [pw,salt]=process.argv.slice(1);"
            "process.stdout.write(c.scryptSync(pw.normalize(),salt,64).toString('base64'));"
        )
        cases = [
            ("hunter2", "c2FsdHNhbHRzYWx0c2E="),
            ("", "c2FsdHNhbHRzYWx0c2E="),
            ("pässwörd☃", "c2FsdHNhbHRzYWx0c2E="),
            ("  leading and trailing  ", "c2FsdHNhbHRzYWx0c2E="),
            ("café", "c2FsdHNhbHRzYWx0c2E="),
            ("x" * 512, "c2FsdHNhbHRzYWx0c2E="),
        ]
        for password, salt in cases:
            with self.subTest(password=password[:24]):
                result = subprocess.run(
                    ["node", "-e", script, password, salt],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                self.assertEqual(
                    seeder.password_hash(password, salt),
                    result.stdout,
                    f"hash mismatch for {password!r}",
                )


class TestKeyLayout(unittest.TestCase):
    def test_user_key(self):
        self.assertEqual(seeder.user_key("alice"), "user:alice")

    def test_datum_path_is_bare_sha256_hex(self):
        """Filename is the hex digest, with no extension and no directory.

        Verified against a running server: `initUserStorage` wrote
        `_storage/3a5bb37a…15dcc` for the handle `default-user`, and
        `sha256("user:default-user")` is exactly that string.
        """
        path = seeder.datum_path("/data/_storage", "user:default-user")
        self.assertEqual(
            os.path.basename(path),
            "3a5bb37ab86ac047d8ef481ee2e7bd3683d694ff8502a7cfe6951af849015dcc",
        )
        self.assertEqual(
            hashlib.sha256(b"user:default-user").hexdigest(),
            "3a5bb37ab86ac047d8ef481ee2e7bd3683d694ff8502a7cfe6951af849015dcc",
        )
        self.assertFalse(path.endswith(".json"))


class TestSeeding(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.storage = os.path.join(self.tmp, "_storage")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _password_file(self, content="s3cret\n"):
        path = os.path.join(self.tmp, "pw")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        return path

    def test_creates_account_with_node_persist_shape(self):
        pw = self._password_file()
        created = seeder.seed(
            self.storage,
            [{"handle": "alice", "name": "Alice", "admin": True, "passwordFile": pw}],
            quiet=True,
        )
        self.assertEqual(created, 1)

        path = seeder.datum_path(self.storage, "user:alice")
        with open(path, encoding="utf-8") as handle:
            datum = json.load(handle)

        # Exactly the two keys node-persist writes. `ttl` must be ABSENT: the
        # server's calcTTL(false) is undefined and JSON.stringify drops it.
        self.assertEqual(set(datum), {"key", "value"})
        self.assertEqual(datum["key"], "user:alice")

        value = datum["value"]
        self.assertEqual(
            set(value),
            {"handle", "name", "created", "password", "admin", "enabled", "salt"},
        )
        self.assertEqual(value["handle"], "alice")
        self.assertEqual(value["name"], "Alice")
        self.assertTrue(value["admin"])
        self.assertTrue(value["enabled"])
        self.assertIsInstance(value["created"], int)
        # The stored hash must verify against the password we supplied.
        self.assertEqual(value["password"], seeder.password_hash("s3cret", value["salt"]))

    def test_file_mode_is_0600(self):
        pw = self._password_file()
        seeder.seed(
            self.storage, [{"handle": "alice", "passwordFile": pw}], quiet=True
        )
        path = seeder.datum_path(self.storage, "user:alice")
        mode = os.stat(path).st_mode & 0o777
        self.assertEqual(mode, 0o600, f"expected 0600, got {oct(mode)}")

    def test_is_idempotent_and_never_overwrites(self):
        """The core promise: a password changed in the UI survives a rebuild."""
        pw = self._password_file("first\n")
        seeder.seed(self.storage, [{"handle": "alice", "passwordFile": pw}], quiet=True)
        path = seeder.datum_path(self.storage, "user:alice")
        with open(path, encoding="utf-8") as handle:
            original = json.load(handle)

        # Simulate the user changing their password through the UI.
        mutated = json.loads(json.dumps(original))
        mutated["value"]["password"] = "changed-in-the-ui"
        mutated["value"]["admin"] = False
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(mutated, handle)

        # Rebuild with a DIFFERENT password file. It must be ignored.
        pw2 = self._password_file("second\n")
        created = seeder.seed(
            self.storage, [{"handle": "alice", "passwordFile": pw2}], quiet=True
        )
        self.assertEqual(created, 0, "must not re-create an existing account")

        with open(path, encoding="utf-8") as handle:
            after = json.load(handle)
        self.assertEqual(after["value"]["password"], "changed-in-the-ui")
        self.assertFalse(after["value"]["admin"])

    def test_trailing_newline_is_stripped_from_password(self):
        other = os.path.join(self.tmp, "other_storage")
        with_nl = self._password_file("s3cret\n")
        without = self._password_file("s3cret")
        a = seeder.seed(
            self.storage, [{"handle": "a", "passwordFile": with_nl}], quiet=True
        )
        b = seeder.seed(
            other, [{"handle": "b", "passwordFile": without}], quiet=True
        )
        self.assertEqual((a, b), (1, 1))

        # Both files must verify against the SAME password with the trailing
        # newline removed. The salts differ (they are random), so the check is
        # a re-hash rather than a comparison of the stored digests.
        for store, handle in ((self.storage, "a"), (other, "b")):
            path = seeder.datum_path(store, "user:" + handle)
            with open(path, encoding="utf-8") as handle_file:
                value = json.load(handle_file)["value"]
            self.assertEqual(
                value["password"], seeder.password_hash("s3cret", value["salt"])
            )

    def test_interior_whitespace_is_preserved(self):
        pw = self._password_file("  spaced out  ")
        seeder.seed(self.storage, [{"handle": "a", "passwordFile": pw}], quiet=True)
        path = seeder.datum_path(self.storage, "user:a")
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)["value"]
        self.assertEqual(
            value["password"], seeder.password_hash("  spaced out  ", value["salt"])
        )

    def test_no_password_gives_unusable_account(self):
        """An SSO-only account: empty hash and empty salt, like DEFAULT_USER."""
        seeder.seed(self.storage, [{"handle": "sso-only"}], quiet=True)
        path = seeder.datum_path(self.storage, "user:sso-only")
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)["value"]
        self.assertEqual(value["password"], "")
        self.assertEqual(value["salt"], "")

    def test_rejects_reserved_handle(self):
        with self.assertRaises(seeder.SeederError) as ctx:
            seeder.seed(self.storage, [{"handle": "default-user"}], quiet=True)
        self.assertIn("reserved", str(ctx.exception))

    def test_rejects_path_traversal_handle(self):
        for bad in ("../escape", "a/b", ".hidden"):
            with self.subTest(handle=bad):
                with self.assertRaises(seeder.SeederError):
                    seeder.seed(self.storage, [{"handle": bad}], quiet=True)

    def test_refuses_to_overwrite_corrupt_entry(self):
        """A corrupt store entry is evidence, not something to paper over."""
        os.makedirs(self.storage, exist_ok=True)
        path = seeder.datum_path(self.storage, "user:alice")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        with self.assertRaises(seeder.SeederError) as ctx:
            seeder.seed(self.storage, [{"handle": "alice"}], quiet=True)
        self.assertIn("Refusing to overwrite", str(ctx.exception))

    def test_dry_run_writes_nothing(self):
        pw = self._password_file()
        created = seeder.seed(
            self.storage,
            [{"handle": "alice", "passwordFile": pw}],
            dry_run=True,
            quiet=True,
        )
        self.assertEqual(created, 1)
        self.assertFalse(
            os.path.exists(seeder.datum_path(self.storage, "user:alice"))
        )


class TestSpecParsing(unittest.TestCase):
    def test_full_spec(self):
        account = seeder.parse_spec(
            "handle=alice,name=Alice A,admin=true,enabled=false,passwordFile=/run/pw"
        )
        self.assertEqual(
            account,
            {
                "handle": "alice",
                "name": "Alice A",
                "admin": True,
                "enabled": False,
                "passwordFile": "/run/pw",
            },
        )

    def test_defaults(self):
        account = seeder.parse_spec("handle=bob")
        self.assertFalse(account["admin"])
        self.assertTrue(account["enabled"])

    def test_rejects_unknown_key(self):
        with self.assertRaises(seeder.SeederError):
            seeder.parse_spec("handle=bob,adminstrue=true")

    def test_rejects_non_boolean(self):
        with self.assertRaises(seeder.SeederError):
            seeder.parse_spec("handle=bob,admin=maybe")

    def test_rejects_missing_handle(self):
        with self.assertRaises(seeder.SeederError):
            seeder.parse_spec("name=Bob")

    def test_rejects_malformed_field(self):
        with self.assertRaises(seeder.SeederError):
            seeder.parse_spec("handle=bob,nonsense")


if __name__ == "__main__":
    unittest.main(verbosity=2)
