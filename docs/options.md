# Options

A map of the `services.sillytavern-nixos` surface: what each group is for, and
which escape hatch to reach for when the option you want does not exist.

For the per-account JSON surface — `settings.json`, presets, themes, world books
— see [`ui-surface.md`](ui-surface.md). For accounts, see
[`users.md`](users.md).

- [The three option groups](#the-three-option-groups)
- [package](#package)
- [config — every key in config.yaml](#config--every-key-in-configyaml)
- [cli — every flag the server accepts](#cli--every-flag-the-server-accepts)
- [The module's deliberate overrides](#the-modules-deliberate-overrides)
- [Escape hatches](#escape-hatches)
- [Environment variables](#environment-variables)
- [Files, per account](#files-per-account)
- [Not Nix-configurable](#not-nix-configurable)

---

## The three option groups

There are exactly three, and the split is deliberate:

| Group | What it is | Cardinality |
|---|---|---|
| `package` | which build of the server to run | one |
| `config` | **every** key in SillyTavern's `config.yaml`, one Nix option each | one tree |
| `cli` | **every** flag the server's yargs parser accepts | one tree |

`config` is complete, not a curated subset. Leaving a key out would mean a user
who needs it has to abandon Nix for one file, which is the failure mode this
module exists to avoid. `lib/tests.nix`'s `configYamlRoundTrip` check renders the
default tree back to YAML, parses it with the `yaml` package SillyTavern itself
uses, and diffs it against upstream's `default/config.yaml` — so a key added
upstream without being added here fails the build rather than silently doing
nothing.

## package

```nix
services.sillytavern-nixos.package =
  inputs.sillytavern.packages.${pkgs.system}.sillytavern;
```

Usually unnecessary: the module sets it with `mkDefault`, so an explicit value
still wins and `pkgs.sillytavern` from the overlay is used when you set that.
See [`installing.md`](installing.md) for why a bare nixpkgs `pkgs.sillytavern` is
not a substitute.

## config — every key in config.yaml

One option per upstream key, in upstream's order, with upstream's default.
Nested keys use attribute paths:

```nix
services.sillytavern-nixos.config = {
  port = 8000;
  listen = false;
  whitelist = [ "::1" "127.0.0.1" "192.168.1.0/24" ];
  hostWhitelist = {
    enabled = true;
    hosts = [ "st.example.com" ];
  };
  extensions.models.autoDownload = false;   # for an air-gapped host
};
```

A few keys are typed more strictly than upstream, deliberately:

- `protocol.ipv4` / `.ipv6` are an enum of **strings** (`"true"`, `"false"`,
  `"auto"`, …), because upstream accepts a string-or-bool hybrid and `"auto"` has
  no boolean equivalent. The rendered YAML therefore contains `ipv4: "true"`
  where upstream writes `ipv4: true`. The server reads both through
  `stringToBool` (`src/command-line.js:307`), so they are equivalent.
- `thumbnails.dimensions.<kind>` is a **two-element list** — `[ 160 90 ]`, not a
  `{ width, height; }` record. The server destructures it
  (`src/endpoints/thumbnails.js:215`), so a record renders a config it rejects
  and breaks thumbnail generation.
- `whitelistImportDomains`, `cors.origin` and friends are lists, matching
  upstream. Entries upstream cannot parse are logged and ignored at runtime, so
  a typo is a silent hole — there is no way to validate a hostname or CIDR
  at eval time that is worth the false confidence.

Credentials are the exception. Three config keys hold secrets, and none of them
should ever be set literally, because a store file is world-readable and kept
forever by the garbage collector:

| Never set | Use instead |
|---|---|
| `config.ssl.keyPassphrase` | `ssl.keyPassphraseFile` |
| `config.basicAuthUser.password` | `basicAuthUser.passwordFile` |
| `config.requestProxy.url` | `requestProxy.urlFile` |

Each file-backed option is read at service start and delivered as the
`SILLYTAVERN_*` environment variable upstream reads it from — which is what
`getConfigValue` checks *before* the file, for every key. The three secret
paths are additionally stripped from the rendered YAML as defence in depth.

## cli — every flag the server accepts

Every flag `src/command-line.js` declares, including the four deprecated ones.
Each defaults to `null`, meaning *do not pass it*, which leaves the `config`
value in charge. Only `configPath` and `dataRoot` are always passed.

```nix
services.sillytavern-nixos = {
  config.port = 8000;
  cli.port = 9000;                  # the flag wins: it outranks config.yaml
};
```

That duplication is not a wart — it is how the server resolves its settings
(`cliArgument ?? getConfigValue(...)`), and collapsing the two surfaces would
make it impossible to express "config.yaml says X but the flag says Y", which
operators do.

Two options cannot be expressed on a command line, and say so:

- `cli.requestProxyBypass = [ ]` means "do not pass the flag", because yargs has
  no way to take a zero-length array and emitting it bare would swallow the next
  flag. Use `config.requestProxy.bypass` for an empty list.
- `cli.global` must be `false`. In that mode the server ignores `--configPath`
  and `--dataRoot` and resolves both through XDG, so the data root could not be
  a `StateDirectory`. The packaged launcher refuses the flag outright.

## The module's deliberate overrides

A handful of upstream defaults are wrong under systemd or under Nix. They are
overridden in `modules/config.nix`, not in `options.nix`, so the option defaults
stay equal to upstream's values and the round-trip check keeps proving that.
Every one is reversible by setting the `config` option explicitly.

| Key | Upstream | Module | Why |
|---|---|---|---|
| `browserLaunch.enabled` | `true` | `false` | no DISPLAY or session bus; with `browser: "firefox"` it logs a spawn error every start |
| `whitelistDockerHosts` | `true` | `false` | there is no Docker bridge on NixOS, and its presence makes an audit of `whitelist` confusing |
| `dataRoot` | `./data` | the `StateDirectory` | upstream resolves it against its own directory, which is the read-only store |
| `extensions.autoUpdate` | `true` | `false` **only when `extensions` is non-empty** | declared extensions are read-only store paths; `git pull` into one fails with EROFS |
| `enableServerPluginsAutoUpdate` | `true` | `false` **only when `plugins` is non-empty** | same, for the other directory |

The last two are deliberately *not* unconditional: a bare
`services.sillytavern-nixos.enable` renders a config indistinguishable from a
hand-written one. Each is gated on its own list, so declaring a server plugin
does not disable the UI extensions' auto-update.

## Escape hatches

Two, for when the modelled surface is not enough:

```nix
# config.yaml keys this module does not know about yet
extraConfig = {
  someKeyAddedUpstreamAfterThisPin = true;
};

# Any systemd unit option, merged last
systemdOverrides = {
  Restart = "always";
  LimitNOFILE = 65536;
};
```

Both are deliberately **not validated**. A typo in either produces a key the
server or systemd ignores, with no error — that is the price of the escape
hatch being an escape hatch.

For a genuinely new upstream config key, prefer `extraConfig` over a
`cli` flag: the config tree is rendered in the same readable block-style YAML
that mirrors upstream, so a rendered config still diffs cleanly against
`default/config.yaml`.

## Environment variables

`extraConfigEnv` sets arbitrary `SILLYTAVERN_*` variables, and `environment`
sets anything else (`NODE_EXTRA_CA_CERTS`, proxy variables, `TZ`).

```nix
services.sillytavern-nixos.extraConfigEnv.SILLYTAVERN_THUMBNAILS_QUALITY = "80";
```

The mapping from a dotted config path to its variable is
`SILLYTAVERN_` + the path uppercased with `.` → `_`. Two things to know:

- **It does not split camelCase.** `browserLaunch.enabled` becomes
  `SILLYTAVERN_BROWSERLAUNCH_ENABLED`, and `enableCorsProxy` becomes
  `SILLYTAVERN_ENABLECORSPROXY` — note the missing underscore before `CORSPROXY`.
- **The environment outranks `config.yaml`.** `getConfigValue` checks the
  environment first for every key, so anything here silently wins over `config`.

Prefer `config`. The environment is the wrong place for list and object values:
the type coercion in `getConfigValue` is inconsistent there — `cors.origin` is
read with a *string* default, so a JSON array supplied through the environment
arrives as a string — which makes it a convenient way to ship something broken.

## Files, per account

`settings` seeds `settings.json` (deep-merged, never replaced). `files` seeds
any other JSON file under an account's directory, and `secrets` seeds
`secrets.json`.

```nix
services.sillytavern-nixos = {
  settings.common.oai_settings.stream_openai = true;   # every account

  files.common = {
    "sysprompt/Roleplay.json".json = { name = "Roleplay"; content = "…"; };
    "themes/Azure.json".json = { palette.accent = "#f00"; };
    "TextGen Settings/Default.json".path = ./presets/textgen-default.json;
    "characters/Seraphina.png".path = ./cards/seraphina.png;
  };

  files.byUser.seanc.themes."Red.json".json = { palette.accent = "#f00"; };
};
```

- **The attribute name is the path**, spaces included, exactly as the directory
  is named in the data root.
- **`{ json = …; }`** writes a value inline; **`{ path = …; }`** copies a file
  from the store verbatim. Set exactly one — the module asserts it.
- **Character cards are reachable.** They are PNGs with embedded JSON, but
  `{ path = …; }` copies bytes, so a card needs no special support.
- **`stats.json`, `backups/`, `_storage/`, `_webpack/` and `_cache`
  are refused**, and so is `secrets.json` through `files` (it has its own
  mechanism). See `RESERVED_TOP_LEVEL` in `scripts/st_seed_files.py`.
- **`seedPolicy`** defaults to `"missing"`: write only what is absent, so an
  edit made in the UI survives the next rebuild. `"overwrite"` restores the
  declared value every activation — note that it is *not* constant, since
  SillyTavern rewrites `settings.json` at runtime regardless.

## What this module writes at the data root

Exactly two destinations, and both are Nix-authoritative — overwritten on every
activation, ignoring `seedPolicy`. The reason is the same in both cases: nothing
ever *updates* these files, so create-only would freeze whatever landed first
and make later edits to the option silently do nothing.

| Option | Writes | Notes |
|---|---|---|
| `customCss` | `<dataRoot>/_css/user.css` | Served to every visitor by `userCssMiddleware`. Mode `0644`, not the `0600` every other seeded file gets. |
| `errorPages.*` | `<dataRoot>/_errors/*.html` | Served to **unauthenticated** visitors on the four paths you most want branded. Mode `0644` for the same reason. |

`errorPages` has four members, keyed by option name but written under upstream's
own filenames:

```nix
errorPages = {
  unauthorized          = ./pages/unauthorized.html;         # _errors/unauthorized.html
  forbiddenByWhitelist  = ./pages/blocked.html;              # _errors/forbidden-by-whitelist.html
  hostNotAllowed        = ./pages/bad-host.html;             # _errors/host-not-allowed.html
  urlNotFound           = ./pages/gone.html;                 # _errors/url-not-found.html
};
```

Watch the hyphen: upstream's file is `forbidden-by-whitelist.html`, so a key of
`forbiddenByWhitelist.html` would produce a page the server never serves — and
branding would appear to do nothing. The check `errorPagesIsolated` asserts the
exact key set.

Only the pages you declare are seeded; the rest keep the copies the server makes
from `default/content/` on first start. Leaving all four `null` means the module
never touches `_errors/` at all.

`st_seed_files.py` refuses any *other* path under `_errors/` — a nested
`_errors/sub/x.html` or an unrecognised name would create a file nothing reads.
The allowlist is `ALLOWED_ERROR_PAGES`, and `test_error_page_allowlist_matches_upstream`
fails if it drifts from `src/`.

## Not Nix-configurable

Known limits, so you do not lose time looking for an option that is not there.

| Thing | Why |
|---|---|
| **The UI language** | The locale is fetched relative to the page (`public/scripts/i18n.js`) and served straight out of the read-only package. There is no data-root override route upstream. The in-browser selector persists per *browser*, not per account. This needs a change to SillyTavern; see the draft issue in `ui-surface.md` §5.1. |
| **More than one instance per host** | One option namespace, one `systemd.services.sillytavern` unit, one service account. `proxyUpstreams` is a list and `mkProxyUpstream` takes a `configName`, so the *API* is shaped for several; the module is not. |
| **The shipped `default/content` set** | Presets, backgrounds and characters baked into the package and copied into the data root on first start. Reachable per account through `files`, but you cannot *remove* or *replace* the shipped set short of overriding `package`. |
| **`cookie-secret.txt`** | Generated on first start and written 0600. Unlike the other three secrets it has no `…File` option. |
| **Chats** | Deliberately not seeded. They are the user's own writing, and `chats/` is created at runtime. |
| **Vector-store documents** | The index is built at runtime from an embeddings API, so documents cannot be seeded offline. |
