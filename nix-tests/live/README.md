# Live Nix → server → UI tests

These are the tests that evaluation cannot do.

`nix flake check` proves an option **exists** and **renders**. It does not
prove the server **starts**, that it **honours** the value, or that the **UI**
reflects it. Most of the failures this module has actually had were invisible
to evaluation — a unit that renders perfectly and will not start evaluates
perfectly too.

This suite builds the real package from the current flake, seeds a real data
root, boots the real server, and asserts against real HTTP responses and real
files on disk.

```
Nix option → rendered config.yaml / seed spec → seeder → data root
           → server → UI
```

## Running it

```bash
./nix-tests/live/run.sh              # everything
./nix-tests/live/run.sh -k settings  # a subset
./nix-tests/live/run.sh -x -q        # stop at first failure, quiet
```

Requires nix with flakes enabled, and network access on the first run (the
nixpkgs fetch). Does **not** need root, a NixOS VM, or a writable `$HOME`.

`run.sh` uses `nix shell` to provide pytest and node, so it works on a clean
checkout with no venv and no `pip install`.

## What it covers

| Area | Tests | What is pinned |
|---|---|---|
| Boot | `test_server_boots` | The rendered unit actually starts |
| Boot | `test_unauthenticated_root_redirects_to_login` | Accounts enabled ⇒ anonymous visitors get the login page |
| Boot | `test_login_page_is_served` | The login page renders |
| Auth | `test_login_succeeds` | The account `st_seed_users.py` created can log in |
| Auth | `test_wrong_password_is_rejected` | …and a wrong password does not |
| Config | `test_rendered_config_carries_nix_values` | A Nix value survives the render |
| Config | `test_rendered_config_is_read_only` | The config is a store path, by design |
| Settings | `test_settings_common_is_seeded` | `settings.common` lands in `settings.json` |
| Settings | `test_settings_byuser_overrides_common` | `settings.byUser` wins on a shared leaf |
| Settings | `test_settings_extra_defaults_present` | `settingsExtra` seeds its keys without displacing `common` |
| Files | `test_seeded_file_lands` | Every seedable per-account directory accepts a file |
| Files | `test_seeded_file_is_owner_only` | Seeded files are mode 0600 |
| Files | `test_seeded_json_file_lands` | A `{ json = …; }` seed is written as JSON |
| Files | `test_seeded_vector_document_lands` | `vectors/` is seedable |
| Files | `test_seeded_file_sources_are_store_paths` | Seed sources are store paths, not host paths |
| Content | `test_server_seeds_default_content` | The shipped default content is present |
| Content | `test_seeded_theme_coexists_with_server_themes` | Seeding does not clobber what the server ships |
| Negative | `test_thumbnails_are_server_derived` | `thumbnails/` is a cache, not seedable |
| Negative | `test_runtime_state_is_not_seeded` | `stats.json` / `backups/` are runtime state |
| Negative | `test_seeder_is_idempotent` | Re-running the seeder changes nothing |
| UI | `test_ui_has_the_settings_drawers` | All nine settings panels are served |
| UI | `test_ui_has_the_preset_managers` | Every preset category the UI offers is present |
| UI | `test_ui_serves_the_key_controls` | The controls the settings options drive are present |

## The per-account directory list

`test_seeded_file_lands` is parameterised over the directories that have **no
preset-manager button**, so they are the ones a user would not know exist:

`User Avatars/`, `backgrounds/`, `assets/`, `user/images/`, `user/files/`,
`characters/<name>/sprites/`

plus `user/workflows/`, `vectors/`, and `themes/` as JSON seeds.

The authoritative list is `USER_DIRECTORY_TEMPLATE` in `src/constants.js`.

## It has been mutation-tested

A suite that cannot fail is worse than none. Three deliberate breakages were
introduced into `modules/config.nix`, and each was caught by exactly the
tests that should catch it:

| Mutation | Caught by |
|---|---|
| `settings.byUser` no longer overrides `settings.common` | 1 test — `test_settings_byuser_overrides_common` |
| `files.byUser` dropped from the seed spec | 15 tests — every file-seeding assertion |
| Rendered config forces `enableUserAccounts = false` | 3 tests — the config check, the login redirect, and the login |

The first is the important one: it is a **silent** failure. Nothing errors,
the server starts, the UI loads — the value is just wrong. Only a test that
reads the file back can see it.

## Traps this suite encodes

Each of these cost real time during development.

**The login route is `/api/users/login`.** The router is mounted at
`/api/users`; the route inside it is `/login`. Posting to `/login` returns a
plain-text `403 Forbidden` — which is Express's *404* handler, not an auth
failure. It looks exactly like a credentials problem.

**A Nix list's final element may not be followed by `;`.** `[ a b; ]` is a
syntax error; `[ a b ]` is fine. The generated module list hit this and the
error pointed at a `};` that looked perfectly correct.

**A plain string path in a derivation is not copied into the store.** The
build sandbox cannot see it, so `cp` fails with "cannot stat". Reference the
flake's own source (`${f.outPath}/scripts/…`) instead — that *is* a store
path.

**Node's ESM resolver walks up from the importing module**, and `node -e` has
none, so the *working directory* decides where `node_modules` is found. To
use the `yaml` package that ships inside the package under test, run node
with the package directory as its cwd.

**The seeder reports on stderr, not stdout.**

**`process.stdout.write` needs a string.** `YAML.parse` returns an object.

**Use the `pytest` entry point, not `python3 -m pytest`.** `nix shell` puts
pytest's bin on `PATH`, but `python3` still resolves to the *host* python,
which has no pytest. The `pytest` wrapper is a shell script that sets up
`PYTHONPATH` for the nix python itself.

## The test config uses store-backed files

The seeded files are declared with `pkgs.writeText`, not host paths:

```nix
files.byUser.me."backgrounds/nature.png".path = pkgs.writeText "bg" "…";
```

so the seed spec carries `/nix/store/…-bg`, exactly as a real deployment
does. `test_seeded_file_sources_are_store_paths` pins that.

This matters: a host path would be read from the *build machine* at
activation time, which is the difference between a reproducible deployment
and one that only works where it was built. The test also asserts the
seeder and the module agree on the account password, by having the build
export the password file's store path and checking its contents — if they
disagreed, the account would get a password nobody knows and the failure
would look like a server bug.

## Adding a test

The server fixture is session-scoped: it builds, seeds, and boots **once**,
and every test shares it. A test that mutates the data root affects the
others, so prefer assertions that only read. If you need a mutation, copy the
tree into `tmp_path` first.

To test a different Nix configuration, add a scenario to
`_default_config()` in `conftest.py`, or add a second fixture that builds its
own server. Building is the expensive part — a second scenario roughly doubles
the runtime unless you share the build.
