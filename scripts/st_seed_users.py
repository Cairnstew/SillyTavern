#!/usr/bin/env python3
"""Seed SillyTavern user accounts from a declarative, Nix-supplied list.

WHY THIS IS PYTHON AND NOT NIX
------------------------------
SillyTavern does not store accounts in a JSON file. ``src/users.js`` initialises
a `node-persist <https://www.npmjs.com/package/node-persist>`_ key-value store at
``$DATA_ROOT/_storage`` and writes one file per datum, so seeding an account means
computing a scrypt hash and writing a file at a path derived from a SHA-256 of the
key. Nix can do neither without either shelling out to a derivation (for the hash)
or inventing a hash (which the server would then reject).

The hash itself is the second reason. ``src/users.js`` stores::

    crypto.scryptSync(password.normalize(), salt, 64).toString('base64')

Node's ``scryptSync`` defaults to N=16384, r=8, p=1, dklen=64. Python's
``hashlib.scrypt`` takes those explicitly and, with ``maxmem`` raised, produces a
**byte-identical** digest — verified against Node for a password containing
non-ASCII characters (see ``tests/test_seed_users.py``). ``password.normalize()``
is JavaScript's NFC normalisation, which is ``unicodedata.normalize("NFC", …)`` in
Python; skipping it would silently produce a different hash for any password with
a combining character, so a user could not log in with the password they set.

THE ON-DISK FORMAT
------------------
Verified two ways: from node-persist 4.0.4's source, and by running the packaged
server and inspecting the result.

* Filename: ``$DATA_ROOT/_storage/<sha256hex(key)>`` — the hex digest of the key,
  with **no** ``.json`` extension and no directory per key.
* Contents: ``JSON.stringify({key, value, ttl})`` where ``ttl`` is
  ``calcTTL(options.ttl)``. ``initUserStorage`` passes ``ttl: false``, and
  ``calcTTL(False)`` yields ``undefined`` — and ``JSON.stringify`` OMITS keys whose
  value is ``undefined``. So the real files contain exactly ``key`` and ``value``,
  with no ``ttl`` key at all. (Confirmed against a live server: the written file was
  ``{"key":"user:default-user","value":{…}}``.) Writing ``"ttl": false`` would also
  work, since ``isExpired`` tests ``datum.ttl`` for truthiness, but omitting it is
  what the server does and is what the seeder does.
* Key: ``user:<handle>``, from ``KEY_PREFIX = 'user:'`` in ``src/users.js``.

IDEMPOTENCE
-----------
The seeder is CREATE-ONLY. A handle that already has a storage file is left
completely alone, including its password, salt, ``enabled`` and ``admin`` flags.

This is the important property, and it is why the seeder does not simply
"reconcile". Account metadata that users can change through the UI — most
importantly the password — would otherwise be reverted on every single
``nixos-rebuild``, and a password change would appear to be silently undone with
no log line explaining why. Removing a handle from the Nix configuration stops it
being managed; the account and its data stay in the state directory untouched.
"""

from __future__ import annotations

import argparse
import base64
import errno
import hashlib
import json
import os
import stat
import sys
import time
import unicodedata

# Node's `crypto.scryptSync(password, salt, keylen)` defaults. `maxmem` has to be
# raised because OpenSSL's default cap (32 MiB) is below what N=16384, r=8 needs
# (128 * N * r = 16 MiB of memory, but the implementation requests more and errors
# with "memory limit exceeded" rather than allocating).
SCRYPT_N = 16384
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 64
SCRYPT_MAXMEM = 64 * 1024 * 1024

KEY_PREFIX = "user:"

# The salt is what node-persist's owner generates: `crypto.randomBytes(16)`
# base64-encoded, i.e. 24 characters from the base64 alphabet.
SALT_BYTES = 16

# Node-persist stores one file per datum, and `getUserAvatar` / `readSecret` on
# the same store read them back with plain fs calls. 0600 matches what the server
# itself writes (writeFileAtomicSync under the default umask) and is the right
# answer for a file holding a password hash.
STORAGE_DIR_MODE = 0o700
STORAGE_FILE_MODE = 0o600


class SeederError(Exception):
    """A condition the operator needs to fix, reported without a traceback."""


def key_to_env(key: str) -> str:
    """Mirror of ``keyToEnv`` in ``src/util.js``.

    Not used to write anything — the account store is addressed by storage key,
    not environment variable — but kept here so the two mappings cannot drift if
    this script grows a config-writing mode.
    """
    return "SILLYTAVERN_" + key.upper().replace(".", "_")


def user_key(handle: str) -> str:
    """The node-persist key for an account handle."""
    return KEY_PREFIX + handle


def datum_path(storage_dir: str, key: str) -> str:
    """Where node-persist would put ``key``.

    ``getDatumPath`` is ``path.join(dir, sha256(key))`` with
    ``sha256(key) = crypto.createHash('sha256').update(key).digest('hex')`` — hex,
    lowercase, no prefix, and no file extension.
    """
    return os.path.join(storage_dir, hashlib.sha256(key.encode("utf-8")).hexdigest())


def password_hash(password: str, salt: str) -> str:
    """Reproduce ``getPasswordHash`` from ``src/users.js``.

    Two details matter and both are easy to get wrong:

    * ``password.normalize()`` is JavaScript's NFC normalisation. Without the
      matching ``unicodedata.normalize("NFC", …)`` a password containing a
      combining character hashes to something the server can never reproduce, and
      the user cannot log in.
    * The SALT is a JavaScript string, and ``scryptSync`` takes it as bytes — so
      the salt is encoded UTF-8, not left as a Python ``str`` for the default
      encoding to guess at.
    """
    normalised = unicodedata.normalize("NFC", password)
    derived = hashlib.scrypt(
        normalised.encode("utf-8"),
        salt=salt.encode("utf-8"),
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        dklen=SCRYPT_DKLEN,
        maxmem=SCRYPT_MAXMEM,
    )
    return base64.b64encode(derived).decode("ascii")


def new_salt() -> str:
    """A fresh salt, in the shape ``getPasswordSalt`` produces."""
    return base64.b64encode(os.urandom(SALT_BYTES)).decode("ascii")


def read_password(path: str) -> str:
    """Read a password file.

    Trailing newlines are stripped, because every text file has one and a
    password that accidentally includes it is a support ticket. Interior
    whitespace is NOT stripped: it can be legitimate in a passphrase, and
    silently eating it is worse than failing.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as err:
        raise SeederError(f"cannot read password file {path}: {err.strerror}") from err
    return raw.rstrip("\r\n")


def existing_user(storage_dir: str, handle: str):
    """Return the stored value for ``handle``, or ``None``.

    A file that exists but does not parse is reported rather than treated as
    absent: overwriting it would destroy whatever the server had written, and
    treating it as absent would make the seeder "fix" a corruption by replacing
    the evidence.
    """
    path = datum_path(storage_dir, user_key(handle))
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle_file:
            datum = json.load(handle_file)
    except (OSError, ValueError) as err:
        raise SeederError(
            f"account store entry for {handle!r} at {path} exists but is not "
            f"readable JSON ({err}). Refusing to overwrite it."
        ) from err
    if not isinstance(datum, dict) or "key" not in datum or "value" not in datum:
        raise SeederError(
            f"account store entry for {handle!r} at {path} is not in node-persist "
            f"datum shape (expected keys 'key' and 'value'). Refusing to overwrite it."
        )
    return datum


def write_user(
    storage_dir: str,
    handle: str,
    name: str,
    password: str | None,
    admin: bool,
    enabled: bool,
    created: int | None,
) -> str:
    """Create the account if it is absent, and return a status word.

    ``password=None`` writes an empty hash and an empty salt.

    ⚠ THIS IS A PASSWORDLESS ACCOUNT, NOT A DISABLED ONE. Verified against a
    running server: the login check in ``src/endpoints/users-public.js`` is

        if (user.password && user.password !== getPasswordHash(…))

    — the ``user.password &&`` GUARD means that when the stored password is
    empty the comparison is skipped entirely and login SUCCEEDS. An account
    seeded with no password was accepted with the literal string
    "literally-anything" as its password.

    So a passwordless account here is only safe behind SSO
    (``config.sso.autheliaAuth`` or ``config.sso.authentikAuth``) or with
    ``enableDiscreetLogin`` plus a trusted network. modules/assertions.nix
    refuses one unless ``allowPasswordlessUsers`` is set, precisely because
    this is not obvious.
    """
    key = user_key(handle)
    salt = new_salt()
    value = {
        "handle": handle,
        "name": name,
        "created": created if created is not None else int(time.time() * 1000),
        "password": password_hash(password, salt) if password is not None else "",
        "admin": bool(admin),
        "enabled": bool(enabled),
        "salt": salt if password is not None else "",
    }

    os.makedirs(storage_dir, mode=STORAGE_DIR_MODE, exist_ok=True)
    path = datum_path(storage_dir, key)

    # `ttl` is deliberately absent: see the module docstring. `JSON.stringify`
    # drops an undefined value, and the server omits it.
    payload = json.dumps({"key": key, "value": value}, separators=(",", ":"))

    # Write to a temporary file in the SAME directory and rename, so a crash
    # mid-write cannot leave a truncated account file that the seeder would then
    # refuse to touch on the next run.
    tmp = path + ".tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(tmp, flags, STORAGE_FILE_MODE)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle_file:
            handle_file.write(payload)
            handle_file.flush()
            os.fsync(handle_file.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    # `os.replace` preserves the temp file's mode, but an existing umask could
    # have narrowed it, and this file holds a password hash.
    os.chmod(path, STORAGE_FILE_MODE)
    return "created"


def seed(
    storage_dir: str,
    accounts: list[dict],
    dry_run: bool = False,
    quiet: bool = False,
) -> int:
    """Seed ``accounts``. Returns the number of accounts created."""
    created = 0

    if not dry_run:
        try:
            os.makedirs(storage_dir, mode=STORAGE_DIR_MODE, exist_ok=True)
        except OSError as err:
            if err.errno != errno.EEXIST:
                raise SeederError(
                    f"cannot create storage directory {storage_dir}: {err.strerror}"
                ) from err

    for account in accounts:
        handle = account["handle"]

        if not handle or "/" in handle or handle.startswith("."):
            raise SeederError(
                f"invalid account handle {handle!r}: it becomes a directory name "
                f"under the data root, so it must be non-empty, must not contain "
                f"'/', and must not start with '.'"
            )

        if handle == "default-user":
            # initUserStorage creates this one itself, with admin: true and an
            # empty password. Seeding it would be silently ignored by the
            # create-only logic below, so say so rather than appearing to work.
            raise SeederError(
                "handle 'default-user' is reserved: the server creates it on "
                "first start with admin: true and an empty password. Declare a "
                "different handle and set admin = true on it."
            )

        existing = None if dry_run else existing_user(storage_dir, handle)

        if existing is not None:
            if not quiet:
                print(
                    f"sillytavern-seed: {handle}: exists, left untouched",
                    file=sys.stderr,
                )
            continue

        password = (
            read_password(account["passwordFile"])
            if account.get("passwordFile")
            else None
        )

        if dry_run:
            if not quiet:
                print(
                    f"sillytavern-seed: {handle}: would create "
                    f"(admin={bool(account.get('admin'))}, "
                    f"enabled={bool(account.get('enabled', True))}, "
                    f"password={'yes' if password is not None else 'none'})",
                    file=sys.stderr,
                )
            created += 1
            continue

        write_user(
            storage_dir,
            handle,
            account.get("name") or handle,
            password,
            bool(account.get("admin")),
            bool(account.get("enabled", True)),
            account.get("created"),
        )
        created += 1
        if not quiet:
            print(
                f"sillytavern-seed: {handle}: created"
                + (
                    " (NO PASSWORD — this account can be logged into with any "
                    "password; it is only safe behind SSO)"
                    if password is None
                    else ""
                ),
                file=sys.stderr,
            )

    return created


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="st_seed_users.py",
        description="Create missing SillyTavern accounts in the node-persist store.",
    )
    parser.add_argument(
        "--data-root",
        required=True,
        help="The server's data root; the store is at <data-root>/_storage.",
    )
    parser.add_argument(
        "--user",
        action="append",
        default=[],
        metavar="SPEC",
        help=(
            "One account, as key=value pairs. Recognised keys: handle (required), "
            "name, admin, enabled, passwordFile. Repeatable."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be created without writing anything.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress per-account progress lines.",
    )
    return parser.parse_args(argv)


def parse_spec(spec: str) -> dict:
    """Parse one ``key=value`` account specification.

    Values may not contain ``=`` — the first ``=`` separates. That is adequate
    for handles, names, booleans and paths, and it keeps the command line
    readable in a systemd unit.
    """
    account: dict = {}
    for field in spec.split(","):
        if "=" not in field:
            raise SeederError(
                f"malformed --user field {field!r}: expected key=value"
            )
        key, _, value = field.partition("=")
        key = key.strip()
        if not key:
            raise SeederError(f"malformed --user field {field!r}: empty key")
        if key == "admin" or key == "enabled":
            lowered = value.strip().lower()
            if lowered not in ("true", "false", "yes", "no", "1", "0"):
                raise SeederError(
                    f"--user {key} must be a boolean, got {value!r}"
                )
            account[key] = lowered in ("true", "yes", "1")
        elif key in ("handle", "name", "passwordFile"):
            account[key] = value
        elif key == "created":
            account[key] = int(value)
        else:
            raise SeederError(
                f"unknown --user key {key!r}; expected one of handle, name, "
                f"admin, enabled, passwordFile, created"
            )

    if "handle" not in account or not account["handle"]:
        raise SeederError(f"--user spec {spec!r} has no handle")
    account.setdefault("enabled", True)
    account.setdefault("admin", False)
    return account


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    storage_dir = os.path.join(args.data_root, "_storage")

    try:
        accounts = [parse_spec(spec) for spec in args.user]
        created = seed(storage_dir, accounts, dry_run=args.dry_run, quiet=args.quiet)
    except SeederError as err:
        print(f"sillytavern-seed: error: {err}", file=sys.stderr)
        return 1

    if not args.quiet:
        verb = "would create" if args.dry_run else "created"
        print(
            f"sillytavern-seed: {verb} {created} of {len(accounts)} declared "
            f"account(s)",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
