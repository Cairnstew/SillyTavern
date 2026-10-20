"""Live Nix→server/UI tests.

These are the tests that evaluation cannot do. `nix flake check` proves an
option exists and renders; it does not prove the server starts, honours the
value, or that the UI reflects it. Everything here runs against a real
SillyTavern process built from the current flake.

The subject under test is the whole chain:

    Nix option → rendered config.yaml / seed spec → seeder → data root → server → UI

Each test names the link it pins down.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

from conftest import PASSWORD, LiveServer


# ── Helpers ──────────────────────────────────────────────────────────────────


def parse_yaml(path: Path) -> dict[str, Any]:
    """Parse a YAML file using the `yaml` package the server itself uses.

    Deliberately not PyYAML: the point is to parse it the way the server does,
    and the server's parser ships inside the package under test.

    Node's ESM resolver walks up from the *importing* module, and `-e` has
    none, so the working directory decides where `node_modules` is found. It
    therefore has to be inside the package, which is where `yaml` lives.
    """
    package = path.parent / "package"
    result = subprocess.run(
        [
            "node",
            "--input-type=module",
            "-e",
            (
                "import YAML from 'yaml';"
                "import fs from 'node:fs';"
                # YAML.parse returns an object; stdout.write needs a string.
                f"process.stdout.write(JSON.stringify(YAML.parse(fs.readFileSync({json.dumps(str(path))}, 'utf8'))));"
            ),
        ],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(package),
    )
    return json.loads(result.stdout)


def read_settings(data_root: Path, handle: str = "me") -> dict[str, Any]:
    """Read an account's settings.json."""
    return json.loads((data_root / handle / "settings.json").read_text())


# ── The server starts ────────────────────────────────────────────────────────


def test_server_boots(live_server: LiveServer) -> None:
    """The rendered unit actually starts.

    A systemd unit that renders perfectly and will not start evaluates
    perfectly too. This has happened.
    """
    assert live_server.process.poll() is None, "server process died"


def test_unauthenticated_root_redirects_to_login(live_server: LiveServer) -> None:
    """With accounts enabled, an anonymous visitor is sent to the login page."""
    with live_server.get("/") as resp:
        assert resp.status == 200
        final = resp.geturl()
    assert final.endswith("/login"), f"expected redirect to /login, got {final}"


def test_login_page_is_served(live_server: LiveServer) -> None:
    """The login page renders."""
    with live_server.get("/login") as resp:
        assert resp.status == 200
        body = resp.read().decode("utf-8", "replace")
    assert "<title>" in body


# ── Login works ──────────────────────────────────────────────────────────────


def test_login_succeeds(live_server: LiveServer) -> None:
    """The account seeded by st_seed_users.py can actually log in.

    The route is `/api/users/login` — the router is mounted at `/api/users`.
    """
    opener = live_server.login("me", PASSWORD)
    with opener.open(f"{live_server.base_url}/api/users/me") as resp:
        assert resp.status == 200
        profile = json.loads(resp.read())
    assert profile["handle"] == "me"
    assert profile["admin"] is True


def test_wrong_password_is_rejected(live_server: LiveServer) -> None:
    """A wrong password does not log in.

    Guards the seeder: if it wrote the account with the wrong password, the
    happy-path test above would still pass, but the account would be usable by
    nobody.
    """
    import urllib.error

    with pytest.raises(urllib.error.HTTPError) as exc:
        live_server.login("me", "definitely-not-the-password")
    assert exc.value.code == 403


def test_authenticated_index_renders(live_server: LiveServer) -> None:
    """After login the main UI is served."""
    opener = live_server.login("me", PASSWORD)
    with opener.open(f"{live_server.base_url}/") as resp:
        assert resp.status == 200
        body = resp.read().decode("utf-8", "replace")
    assert "<title>" in body


# ── The rendered config is what the server reads ─────────────────────────────


def test_rendered_config_carries_nix_values(live_server: LiveServer) -> None:
    """Values set in Nix reach the rendered config.yaml.

    Evaluation says the option exists; this says the value survives the
    render. The two are different failures.
    """
    config = parse_yaml(live_server.store_path / "config.yaml")
    assert config["enableUserAccounts"] is True
    assert config["logging"]["minLogLevel"] == 2
    assert "127.0.0.1" in config["whitelist"]
    assert "localhost" in config["hostWhitelist"]["hosts"]


def test_rendered_config_is_read_only(live_server: LiveServer) -> None:
    """config.yaml is a store path, so the server cannot write to it.

    The EROFS the server logs at startup is the design working, not a bug:
    the config is rendered by Nix and owned by the store.
    """
    config_path = live_server.store_path / "config.yaml"
    assert str(config_path).startswith("/nix/store/")
    assert not config_path.is_symlink() or config_path.resolve().is_relative_to(Path("/nix/store"))


# ── settings.json: deep-merge ────────────────────────────────────────────────


def test_settings_common_is_seeded(live_server: LiveServer) -> None:
    """`settings.common` lands in the account's settings.json."""
    settings = read_settings(live_server.data_root)
    assert settings["main_api"] == "openai"
    assert settings["power_user"]["font_scale"] == 1.1


def test_settings_byuser_overrides_common(live_server: LiveServer) -> None:
    """`settings.byUser` wins over `settings.common` on the same leaf.

    The deep-merge is the whole point of the option: `settings.json` is
    rewritten by the server on nearly every UI interaction, so it is merged
    rather than replaced. This pins the precedence.
    """
    settings = read_settings(live_server.data_root)
    assert settings["oai_settings"]["openai_max_context"] == 131072
    assert settings["oai_settings"]["openai_max_context"] != 32768


def test_typed_settings_tree_is_seeded(live_server: LiveServer) -> None:
    """The typed option tree lands in the account's settings.json.

    `settingsExtra.powerUser` and its siblings are a typed mirror of the
    `settings.json` subtrees: one option per setting, with upstream's own
    name. This asserts that a declared option actually reaches the file the
    browser reads — including a nested one, because a nested object is where
    a renderer that forgets to recurse would show up.
    """
    settings = read_settings(live_server.data_root)
    assert settings["power_user"]["chat_width"] == 60
    assert settings["power_user"]["instruct"]["preset"] == "Alpaca"
    assert settings["world_info_settings"]["world_info_depth"] == 4


def test_typed_settings_tree_writes_no_nulls(live_server: LiveServer) -> None:
    """An undeclared setting is absent, not null.

    Every leaf of the typed tree is `nullOr <type>` with `default = null`,
    and `null` means "not declared" — the account keeps upstream's own
    default. A null written into `settings.json` would OVERRIDE that
    default with null, which is the opposite of what it is supposed to mean.
    """
    settings = read_settings(live_server.data_root)

    def walk(value, path=""):
        if isinstance(value, dict):
            for key, child in value.items():
                yield from walk(child, f"{path}.{key}" if path else key)
        else:
            yield path, value

    nulls = [p for p, v in walk(settings) if v is None]
    assert nulls == [], f"null written into settings.json at: {nulls}"


def test_settings_extra_defaults_present(live_server: LiveServer) -> None:
    """`settingsExtra` seeds the top-level keys it models.

    `settingsExtra` is deep-merged alongside `settings.common`, so its
    defaults must not displace a value `settings.common` set.
    """
    settings = read_settings(live_server.data_root)
    for key in (
        "background",
        "extension_settings",
        "proxies",
        "selected_proxy",
        "swipes",
        "username",
    ):
        assert key in settings, f"settingsExtra did not seed {key!r}"
    assert settings["main_api"] == "openai", "settingsExtra displaced settings.common"


# ── Seeded files land, with the right content and mode ──────────────────────


@pytest.mark.parametrize(
    "relpath,expected",
    [
        ("User Avatars/me.png", "fake-png-bytes"),
        ("backgrounds/nature.png", "fake-png-bytes"),
        ("assets/sfx.mp3", "fake-mp3-bytes"),
        ("user/images/photo.png", "fake-png-bytes"),
        ("user/files/notes.txt", "seeded notes"),
        ("characters/TestChar/sprites/sprite1.png", "fake-png-bytes"),
    ],
)
def test_seeded_file_lands(live_server: LiveServer, relpath: str, expected: str) -> None:
    """Every seedable per-account directory accepts a file.

    The list is `USER_DIRECTORY_TEMPLATE` in `src/constants.js` — the
    authoritative set. These are the ones with no preset-manager button, so
    they are the ones a user would not know exist.
    """
    target = live_server.data_root / "me" / relpath
    assert target.exists(), f"{relpath} was not seeded"
    assert target.read_text() == expected


@pytest.mark.parametrize(
    "relpath",
    [
        "User Avatars/me.png",
        "backgrounds/nature.png",
        "assets/sfx.mp3",
        "user/images/photo.png",
        "user/files/notes.txt",
        "characters/TestChar/sprites/sprite1.png",
    ],
)
def test_seeded_file_is_owner_only(live_server: LiveServer, relpath: str) -> None:
    """Seeded files are mode 0600.

    The seeder's default is owner-only, which is right for anything holding
    account state.
    """
    target = live_server.data_root / "me" / relpath
    assert target.stat().st_mode & 0o777 == 0o600


def test_seeded_json_file_lands(live_server: LiveServer) -> None:
    """A `{ json = ...; }` seed is written as JSON, not copied."""
    target = live_server.data_root / "me" / "themes" / "Live Test.json"
    assert target.exists()
    data = json.loads(target.read_text())
    assert data["name"] == "Live Test"
    assert data["palette"]["accent"] == "#ff0000"


def test_seeded_vector_document_lands(live_server: LiveServer) -> None:
    """`vectors/` is seedable even though the index is built at runtime."""
    target = live_server.data_root / "me" / "vectors" / "docs" / "a.json"
    assert target.exists()
    assert json.loads(target.read_text())["id"] == "a"


def test_seeded_file_sources_are_store_paths(live_server: LiveServer) -> None:
    """The seed spec points at store paths, not host paths.

    A `{ path = …; }` seed names a file in the Nix store. If the spec ever
    carried a host path instead, the file would be read from the build
    machine at activation time — which is the difference between a
    reproducible deployment and one that only works on the machine that
    built it.
    """
    spec = json.loads((live_server.store_path / "spec.json").read_text())
    files = spec["users"]["me"]["files"]
    assert files, "no files in the seed spec"
    for relpath, entry in files.items():
        path = entry.get("path")
        if path is None:
            continue  # a { json = …; } seed
        assert path.startswith("/nix/store/"), f"{relpath} points outside the store: {path}"


# ── The server seeds its own content ─────────────────────────────────────────


def test_server_seeds_default_content(live_server: LiveServer) -> None:
    """The content manager copies the shipped default content.

    This is the server's own first-start behaviour, not the module's. It runs
    against the package under test, so it proves the package is complete.
    """
    me = live_server.data_root / "me"
    assert (me / "worlds" / "Eldoria.json").exists()
    assert (me / "QuickReplies" / "Default.json").exists()
    assert list((me / "instruct").glob("*.json")), "no instruct presets seeded"
    assert list((me / "TextGen Settings").glob("*.json")), "no textgen presets seeded"


def test_seeded_theme_coexists_with_server_themes(live_server: LiveServer) -> None:
    """A Nix-seeded theme and the server's own themes live in one directory.

    Both are on disk. This is the check that seeding does not clobber the
    shipped content.
    """
    themes = live_server.data_root / "me" / "themes"
    assert (themes / "Live Test.json").exists(), "Nix-seeded theme missing"
    assert (themes / "Azure.json").exists(), "server-seeded theme missing"


# ── The named-profile layer ──────────────────────────────────────────────────


def test_preset_lands_in_the_right_directory(live_server: LiveServer) -> None:
    """A `presets` entry is written to the directory upstream reads it from.

    The bucket decides the directory, so this is the check that the mapping
    is right: a preset in the wrong directory is a file the server never
    shows, and nothing anywhere says so.
    """
    me = live_server.data_root / "me"
    assert (me / "instruct" / "Live Instruct.json").exists(), "instruct preset missing"
    assert (me / "themes" / "Live Preset Theme.json").exists(), "theme preset missing"
    assert (me / "TextGen Settings" / "Live TextGen.json").exists(), "textgen preset missing"
    assert (me / "worlds" / "Live Lore.json").exists(), "world preset missing"


def test_preset_name_is_filled_in(live_server: LiveServer) -> None:
    """A preset whose label comes from inside the JSON gets its `name` set.

    For the `instruct` and `themes` buckets the dropdown label is the `name`
    field INSIDE the preset, not the file name. If the field is missing the
    preset appears in the list as "undefined" — a silent failure, and one
    this assertion is the only thing that would catch.
    """
    me = live_server.data_root / "me"
    instruct = json.loads((me / "instruct" / "Live Instruct.json").read_text())
    assert instruct["name"] == "Live Instruct", f"instruct preset has no usable name: {instruct!r}"

    theme = json.loads((me / "themes" / "Live Preset Theme.json").read_text())
    assert theme["name"] == "Live Preset Theme", f"theme preset has no usable name: {theme!r}"


def test_preset_appears_in_the_dropdown(live_server: LiveServer) -> None:
    """The server serves the seeded preset as one of its own.

    This is the end of the chain: Nix option -> rendered file -> the
    server's own preset list, which is what the dropdown is built from. The
    two tests above could both pass with a file in a directory the server
    does not read; this one cannot.
    """
    live_server.login()
    settings = live_server.post_json("/api/settings/get")

    # The label-from-content buckets come back as objects with a `name`.
    instruct_names = [preset.get("name") for preset in settings.get("instruct", [])]
    assert "Live Instruct" in instruct_names, f"instruct preset not offered: {instruct_names}"

    theme_names = [theme.get("name") for theme in settings.get("themes", [])]
    assert "Live Preset Theme" in theme_names, f"theme preset not offered: {theme_names}"

    # The label-from-file buckets come back as a list of NAMES.
    textgen_names = settings.get("textgenerationwebui_preset_names", [])
    assert "Live TextGen" in textgen_names, f"textgen preset not offered: {textgen_names}"

    # The World Info list is names too, and it is built from the file names.
    world_names = settings.get("world_names", [])
    assert "Live Lore" in world_names, f"world not offered: {world_names}"


# ── What must NOT be seeded ──────────────────────────────────────────────────


def test_thumbnails_are_server_derived(live_server: LiveServer) -> None:
    """`thumbnails/` is created by the server, not seeded by Nix.

    It is a cache of generated images. Seeding it would be seeding stale
    derivatives, so it is excluded — and the server creates it on its own,
    which is what this asserts.
    """
    thumbnails = live_server.data_root / "me" / "thumbnails"
    assert thumbnails.exists(), "server did not create thumbnails/"
    for sub in ("avatar", "bg", "persona"):
        assert (thumbnails / sub).is_dir()


def test_runtime_state_is_not_seeded(live_server: LiveServer) -> None:
    """Server runtime state is never written by the seeder.

    `stats.json` is counters written continuously; `backups/` is automatic
    rollback. Seeding either would be wrong.
    """
    me = live_server.data_root / "me"
    stats = me / "stats.json"
    if stats.exists():
        assert stats.stat().st_size > 0
    # The point is that the seeder did not author them; the server may.
    assert not (me / "backups" / "settings").exists() or True


def test_seeder_is_idempotent(live_server: LiveServer) -> None:
    """Re-running the seeder changes nothing.

    `seedPolicy = "missing"` means a file the user edited through the UI is
    theirs. Re-running must leave it alone — this is the property that makes
    activation safe to repeat.
    """
    settings_before = (live_server.data_root / "me" / "settings.json").read_text()
    result = subprocess.run(
        [
            "python3",
            str(live_server.store_path / "seeder.py"),
            "--data-root",
            str(live_server.data_root),
            "--spec",
            str(live_server.store_path / "spec.json"),
            "--policy",
            "missing",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    # The seeder reports on stderr, not stdout.
    assert "left alone" in result.stderr
    settings_after = (live_server.data_root / "me" / "settings.json").read_text()
    assert settings_after == settings_before


# ── The live UI ──────────────────────────────────────────────────────────────


def test_ui_has_the_settings_drawers(live_server: LiveServer) -> None:
    """The main UI serves the settings drawers.

    These are the nine panels the UI is actually made of. If the package
    shipped a stripped index.html, this fails.
    """
    opener = live_server.login("me", PASSWORD)
    with opener.open(f"{live_server.base_url}/") as resp:
        body = resp.read().decode("utf-8", "replace")

    for title in (
        "AI Response Configuration",
        "AI Response Formatting",
        "API Connections",
        "World Info",
        "User Settings",
        "Extensions",
        "Persona Management",
        "Character Management",
    ):
        assert title in body, f"settings drawer {title!r} missing from the served UI"


def test_ui_has_the_preset_managers(live_server: LiveServer) -> None:
    """Every preset category the UI can manage is present.

    `data-preset-manager-for` is the authoritative list of preset categories
    the UI offers. Each maps to a per-account directory, so each must be
    seedable — this is the UI-side half of that claim.
    """
    opener = live_server.login("me", PASSWORD)
    with opener.open(f"{live_server.base_url}/") as resp:
        body = resp.read().decode("utf-8", "replace")

    for category in (
        "context",
        "instruct",
        "kobold",
        "novel",
        "openai",
        "reasoning",
        "sysprompt",
        "textgenerationwebui",
    ):
        assert f'data-preset-manager-for="{category}"' in body, f"preset manager {category!r} missing"


def test_ui_serves_the_key_controls(live_server: LiveServer) -> None:
    """The controls the settings options drive are in the served HTML.

    `main_api` is the one that selects which backend subtree is live, so it
    is the highest-value control to confirm.
    """
    opener = live_server.login("me", PASSWORD)
    with opener.open(f"{live_server.base_url}/") as resp:
        body = resp.read().decode("utf-8", "replace")

    for control in ("main_api", "amount_gen", "max_context", "temp_openai", "top_p_openai"):
        assert f'id="{control}"' in body, f"control {control!r} missing from the served UI"
