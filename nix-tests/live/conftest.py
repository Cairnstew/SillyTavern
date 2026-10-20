"""Pytest fixtures for live Nix→server/UI testing.

Builds the SillyTavern package from the current flake, seeds a data root,
boots the server, and provides HTTP helpers for assertions.

Usage:
    pytest nix-tests/live/
"""

from __future__ import annotations

import http.cookiejar
import json
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from pathlib import Path
from typing import Any, Dict, Optional

import pytest

REPO = Path(__file__).resolve().parent.parent.parent

# The account password. Lives in a constant because the seeder hashes it and
# the test logs in with it; it is a throwaway value for a throwaway server.
PASSWORD = "test-password"


def _free_port() -> int:
    """Find a free TCP port on localhost."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class StoreFile:
    """A file whose content lives in the Nix store.

    Used instead of a host path so the seeded files are store-backed, exactly
    as they are in a real deployment. A host path would be copied into the
    store by Nix anyway, but only because the build is impure; making the
    intent explicit keeps the test honest about what it exercises.
    """

    def __init__(self, content: str, name: str = "file"):
        self.content = content
        self.name = name


def _nix_repr(value: Any) -> str:
    """Convert a Python value to its Nix representation."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        # Nix floats need an explicit fractional part, or `1.0` is an int.
        return repr(value) if value != int(value) else f"{value}.0"
    if isinstance(value, str):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    if isinstance(value, StoreFile):
        escaped = value.content.replace("\\", "\\\\").replace('"', '\\"')
        return f'(pkgs.writeText "{value.name}" "{escaped}")'
    if isinstance(value, list):
        return "[ " + " ".join(_nix_repr(v) for v in value) + " ]"
    if isinstance(value, dict):
        items = []
        for k, v in value.items():
            key = k if k.replace("_", "").isalnum() else f'"{k}"'
            items.append(f"{key} = {_nix_repr(v)};")
        return "{ " + " ".join(items) + " }"
    raise TypeError(f"Cannot convert {type(value)} to Nix")


def _generate_nix_expr(config: dict) -> str:
    """Generate the nix expression for building the live package.

    Note the module list has NO trailing semicolon after the module attrset:
    Nix rejects a trailing `;` on a list's final element
    (`[ a b; ]` is a syntax error; `[ a b ]` is not). Getting this wrong
    fails with "syntax error, unexpected ';'" pointing at the `};` that
    looks perfectly correct.
    """
    config_nix = _nix_repr(config)
    return f"""
let
  f = builtins.getFlake "path:{REPO}";
  lib = f.inputs.nixpkgs.lib;
  pkgs = import f.inputs.nixpkgs {{ system = "x86_64-linux"; }};
  cfg = (lib.nixosSystem {{
    system = "x86_64-linux";
    modules = [
      f.nixosModules.sillytavern
      {{
        boot.loader.grub.enable = false;
        fileSystems."/" = {{ device = "/dev/null"; fsType = "tmpfs"; }};
        system.stateVersion = "25.05";
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
        services.sillytavern-nixos = {config_nix};
      }}
    ];
  }}).config;
  st = cfg.services.sillytavern-nixos;
  # The password file's store path, exported so the test can hand the
  # seeder the SAME path the module was given. If the two disagree, the
  # account gets a password nobody knows, and the test would fail at login
  # for reasons that look like a server bug.
  passwordPath = cfg.services.sillytavern-nixos.users.me.passwordFile;
in
pkgs.runCommand "live" {{ }} ''
  mkdir -p $out
  cp ${{st.internal.renderedConfig}} $out/config.yaml
  cp ${{st.internal.seedSpec}} $out/spec.json
  cp -r ${{st.internal.packaged}} $out/package
  # The seeders come from the flake's own source, not from a host path: a
  # plain string in a derivation is NOT copied into the store, so the build
  # sandbox cannot see it ("cp: cannot stat ..."). Referencing a path
  # interpolates it into the store instead.
  cp ${{f.outPath}}/scripts/st_seed_files.py $out/seeder.py
  cp ${{f.outPath}}/scripts/st_seed_users.py $out/seeder-users.py
  echo "${{passwordPath}}" > $out/password-path
''
"""


def _build_live(config: dict, work_dir: Path) -> Path:
    """Build the live package with nix and return the store path."""
    nix_expr = _generate_nix_expr(config)
    nix_file = work_dir / "live.nix"
    nix_file.write_text(nix_expr)

    result = subprocess.run(
        ["nix", "build", "--impure", "--no-link", "--print-out-paths", "-f", str(nix_file)],
        capture_output=True,
        text=True,
        cwd=str(REPO),
        timeout=600,
    )
    if result.returncode != 0:
        raise RuntimeError(f"nix build failed:\n{result.stderr}")
    return Path(result.stdout.strip())


def _seed(data_root: Path, store_path: Path, handle: str, password: str) -> None:
    """Run the seeders to populate the data root.

    The password file must be the SAME path the module was given, so the
    account the seeder creates has the password the test will use. The build
    exports it as `password-path` for exactly this.
    """
    pw_file = store_path / "password-path"
    if not pw_file.exists():
        raise RuntimeError(f"build did not export the password path: {pw_file}")
    # The exported file holds the PATH of the password file, not its content.
    actual = pw_file.read_text().strip()
    content = Path(actual).read_text().strip()
    if content != password:
        raise RuntimeError(
            f"password file at {actual} holds {content!r}, expected {password!r} — "
            "the module and the seeder disagree about the account password"
        )

    subprocess.run(
        [
            "python3",
            str(store_path / "seeder-users.py"),
            "--data-root",
            str(data_root),
            "--user",
            f"handle={handle},name={handle.title()},admin=true,enabled=true,passwordFile={actual}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        [
            "python3",
            str(store_path / "seeder.py"),
            "--data-root",
            str(data_root),
            "--spec",
            str(store_path / "spec.json"),
            "--policy",
            "missing",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def _wait_for_server(base_url: str, timeout: int = 120) -> None:
    """Wait until the server responds to HTTP requests."""
    deadline = time.monotonic() + timeout
    last_err: Optional[Exception] = None
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request(base_url, method="GET")
            with urllib.request.urlopen(req, timeout=5) as resp:
                if resp.status in (200, 302, 401, 403):
                    return
        except (urllib.error.URLError, ConnectionError, OSError) as e:
            last_err = e
            time.sleep(1)
    raise RuntimeError(f"Server did not start within {timeout}s. Last error: {last_err}")


class LiveServer:
    """A live SillyTavern server built from Nix."""

    def __init__(self, store_path: Path, data_root: Path, port: int, process: subprocess.Popen):
        self.store_path = store_path
        self.data_root = data_root
        self.port = port
        self.process = process
        self.base_url = f"http://127.0.0.1:{port}"

    def get(self, path: str, **kwargs: Any) -> Any:
        """Make a GET request and return the response."""
        return urllib.request.urlopen(f"{self.base_url}{path}", **kwargs)

    def post(
        self,
        path: str,
        data: Optional[bytes] = None,
        headers: Optional[Dict[str, str]] = None,
        **kwargs: Any,
    ) -> Any:
        """Make a POST request and return the response."""
        req = urllib.request.Request(
            f"{self.base_url}{path}", data=data, headers=headers or {}, method="POST"
        )
        return urllib.request.urlopen(req, **kwargs)

    def login(self, handle: str = "me", password: str = PASSWORD) -> urllib.request.OpenerDirector:
        """Log in and return an opener with cookies."""
        cj = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
        data = json.dumps({"handle": handle, "password": password}).encode()
        req = urllib.request.Request(
            f"{self.base_url}/api/users/login",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        opener.open(req)
        return opener

    def post_json(self, path: str, payload: Optional[Dict[str, Any]] = None) -> Any:
        """Log in, POST a JSON body, and return the parsed response.

        The per-user router authenticates before serving anything, so a
        request that needs the ACCOUNT's own state has to carry the session
        cookie. `login()` returns the opener that holds it, and it is used
        here rather than the bare `post` above, which has no cookies.

        `POST /api/settings/get` is the interesting one: it is what the
        browser asks for on load, and its response is where the preset
        managers, the theme list and the World Info list come from — the
        dropdowns themselves.
        """
        opener = self.login()
        data = json.dumps(payload or {}).encode()
        req = urllib.request.Request(
            f"{self.base_url}{path}",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with opener.open(req) as resp:
            return json.loads(resp.read())

    def teardown(self) -> None:
        """Kill the server and clean up."""
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
        shutil.rmtree(self.data_root, ignore_errors=True)


def _default_config(data_root: Path, port: int) -> dict:
    """Build the default test config with per-account files."""
    return {
        "enable": True,
        "dataRoot": str(data_root),
        "config": {
            "enableUserAccounts": True,
            "logging": {"minLogLevel": 2},
            "listen": True,
            "whitelist": ["::1", "127.0.0.1", "100.64.0.0/10"],
            "hostWhitelist": {
                "scan": True,
                "hosts": ["localhost", "127.0.0.1"],
            },
        },
        "users": {
            "me": {
                "name": "Me",
                # A store path, as a real deployment would use (agenix
                # decrypts to /run/agenix/<name>). The seeder reads the
                # PLAINTEXT from it at activation and hashes it, so the
                # password itself never lands in settings.json.
                "passwordFile": StoreFile(PASSWORD, "password"),
                "admin": True,
            },
        },
        "settings": {
            "common": {
                "main_api": "openai",
                # `openai_max_context`, not `max_context`: the latter is not
                # a setting SillyTavern has (the top-level `max_context` is),
                # and the settings-key guard now refuses it.
                "oai_settings": {"openai_max_context": 32768},
                "power_user": {"font_scale": 1.1},
            },
            "byUser": {
                "me": {
                    "oai_settings": {"openai_max_context": 131072},
                },
            },
        },
        # The TYPED tree: the same settings, declared as options with
        # upstream's own names. It is a different layer (`settingsExtra` is
        # the base, `settings.common` overrides it), so it is declared on
        # fields the free-form layer does not touch.
        "settingsExtra": {
            "powerUser": {
                "chat_width": 60,
                "instruct": {"preset": "Alpaca"},
            },
            "worldInfoSettings": {
                "world_info_depth": 4,
            },
        },
        "files": {
            "byUser": {
                "me": {
                    "User Avatars/me.png": {"path": StoreFile("fake-png-bytes", "avatar")},
                    "backgrounds/nature.png": {"path": StoreFile("fake-png-bytes", "bg")},
                    "assets/sfx.mp3": {"path": StoreFile("fake-mp3-bytes", "asset")},
                    "user/images/photo.png": {"path": StoreFile("fake-png-bytes", "img")},
                    "user/files/notes.txt": {"path": StoreFile("seeded notes", "notes")},
                    "user/workflows/comfy.json": {"json": {"name": "test workflow", "nodes": []}},
                    "vectors/docs/a.json": {"json": {"id": "a", "text": "seeded vector doc"}},
                    "characters/TestChar/sprites/sprite1.png": {"path": StoreFile("fake-png-bytes", "sprite")},
                    "themes/Live Test.json": {"json": {"name": "Live Test", "palette": {"accent": "#ff0000"}}},
                },
            },
        },
        # The NAMED-PROFILE layer: a bucket and a name, with the directory
        # derived. One bucket whose dropdown label comes from inside the JSON
        # (`instruct`, `themes`) and one whose label is the file name
        # (`textGeneration`).
        #
        # The `name` is deliberately NOT written in the content for the
        # label-from-content buckets: the module fills it in from the key, and
        # a preset that reached the dropdown as "undefined" would be a silent
        # failure the tests below would not notice.
        "presets": {
            "common": {
                "instruct": {
                    "Live Instruct": {"json": {"identifier": "live", "content": "INSTRUCTION"}},
                },
                "themes": {
                    "Live Preset Theme": {"json": {"blur_strength": 3}},
                },
                "textGeneration": {
                    "Live TextGen": {"json": {"temperature": 0.42}},
                },
                "worlds": {
                    "Live Lore": {"json": {"entries": {}}},
                },
            },
        },
    }


def _create_test_files(data_root: Path) -> None:
    """Create the data root.

    The seeded FILE CONTENTS come from the Nix store now, so all this has to
    do is make the directory the data root points at.
    """
    data_root.mkdir(parents=True, exist_ok=True)


@pytest.fixture(scope="session")
def live_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[LiveServer]:
    """Build, seed, and boot a live SillyTavern server for the test session."""
    work_dir = tmp_path_factory.mktemp("live-server")
    data_root = work_dir / "data"
    port = _free_port()

    _create_test_files(data_root)
    config = _default_config(data_root, port)
    store_path = _build_live(config, work_dir)
    _seed(data_root, store_path, "me", PASSWORD)

    proc = subprocess.Popen(
        [
            str(store_path / "package" / "bin" / "sillytavern"),
            f"--configPath={store_path / 'config.yaml'}",
            f"--dataRoot={data_root}",
            f"--port={port}",
            "--disableCsrf",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        cwd=str(data_root),
    )

    server = LiveServer(store_path, data_root, port, proc)

    try:
        _wait_for_server(server.base_url, timeout=120)
    except RuntimeError:
        output = proc.stdout.read() if proc.stdout else ""
        server.teardown()
        raise RuntimeError(f"Server failed to start.\nOutput:\n{output}")

    yield server
    server.teardown()
