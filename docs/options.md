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
- [Named profiles: `presets.*`](#named-profiles-presets)
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

The module's default, the overlay's `pkgs.sillytavern` and the flake's
`packages.<system>.sillytavern` are the **same derivation** — one build, not
three. The `packageIdentity` check in `nix flake check` fails the build if
they ever drift apart again, because the drift is invisible from the outside
until the store fills with two copies of the same software.

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

## Named profiles: `presets.*`

SillyTavern's UI is full of dropdowns of **saved, named, importable and
exportable items**: the Text Completion presets, the AI Response Configuration
presets, the Instruct / Context / Sysprompt / Reasoning templates, the themes,
the lorebooks, the quick-reply sets, the Moving UI layouts, the ComfyUI
workflows.

`presets` gives each of those a bucket, and each item a **name**:

```nix
services.sillytavern-nixos.presets = {
  common = {
    # a bucket, then a NAME
    instruct."Alpaca".json = {
      identifier = "alpaca";
      input_sequence = "<|user|>";
      output_sequence = "<|assistant|>";
    };

    themes."Azure".json = {
      blur_strength = 11;
      main_text_color = "rgba(171, 198, 223, 1)";
    };

    textGeneration."My Preset".json = { temperature = 0.9; };
    worlds."Lore".json = { entries = { }; };
  };

  byUser.seanc.sysprompt."Roleplay".json = {
    content = "Write {{char}} as {{user}} would.";
  };
};
```

The **directory is derived from the bucket**, so nobody has to know that the
Text Completion presets live in a directory called `TextGen Settings`.

### The buckets

| Bucket | What it is | Where it goes |
|---|---|---|
| `textGeneration` | Text Completion presets | `TextGen Settings/` |
| `openai` | AI Response Configuration presets | `OpenAI Settings/` |
| `novel` | NovelAI presets | `NovelAI Settings/` |
| `kobold` | KoboldAI Classic presets | `KoboldAI Settings/` |
| `instruct` | Instruct templates | `instruct/` |
| `context` | Context templates | `context/` |
| `sysprompt` | System-prompt templates | `sysprompt/` |
| `reasoning` | Reasoning templates | `reasoning/` |
| `themes` | UI themes | `themes/` |
| `movingUi` | Moving UI layouts | `movingUI/` |
| `quickReplies` | Quick-reply sets | `QuickReplies/` |
| `worlds` | World Info books | `worlds/` |
| `workflows` | Saved ComfyUI workflows | `user/workflows/` |

### Two things about names

**Where the dropdown's label comes from is not uniform**, and getting it wrong
is silent. For most buckets the label is the **file name**, so the key you
write is what the user sees. For `instruct`, `context`, `sysprompt`,
`reasoning`, `themes`, `movingUi` and `quickReplies` the label is a `name`
field **inside** the JSON.

So for those seven, the module **fills the `name` field in from the key** when
it is missing — a preset can never appear in the dropdown as `undefined` — and
**refuses** a `name` that disagrees with the key, because a preset whose label
and file name differ is a preset nobody can find.

**The name becomes a file name**, so it must not contain a path separator. The
module refuses one that does.

### `presets` and `files` are two views of the same files

`files` states a path; `presets` derives one from a bucket and a name. They
seed the same files, and declaring one file in **both** is an error rather
than a merge — otherwise the `presets` declaration would quietly do nothing.

`{ json = …; }` and `{ path = …; }` work exactly as they do in `files`, and so
do the per-entry `policy` and `mode` knobs.

### The buckets are checked against upstream's source

The directory names and the label sources are **claims about upstream**, and a
wrong one produces a file the server never reads — no error, no warning, an
empty dropdown. So they are checked rather than trusted:

- `presetsMatchUpstream` reads `USER_DIRECTORY_TEMPLATE` out of
  `src/constants.js` and the API-id switch out of `src/endpoints/presets.js`,
  and compares them with the module's own table.
- The same check reads the client (`public/scripts/preset-manager.js`,
  `power-user.js`, `QuickReplySet.js`) to confirm which buckets take their
  label from inside the JSON.

An upstream rename fails `nix flake check` rather than silently emptying a
dropdown.

### The settings are checked, not just accepted

`settings.common` is a free-form blob, so a typo in it would be accepted
silently and then ignored — the browser reads `settings.json` by direct
property access, with no schema and no dotted-path resolver. The module
therefore refuses three things at evaluation time:

| Refused | Why |
|---|---|
| a path upstream does not have (`power_user.font_scal`) | written to disk, never read — it does nothing at all |
| a key outside the 24 the browser writes (`my_own_key`) | the browser **deletes** it at the next save, so it looks applied until it is not |
| a value of the wrong kind (`power_user.waifuMode = "false"`) | in JavaScript every non-empty string is TRUE, so the setting would be ON while the configuration says OFF |

The list of real settings is **derived from upstream's own source**, not
written out by hand: `lib/settings-inventory.json`, produced by
`node scripts/extract_settings_inventory.mjs`. It holds all 410 leaf fields
across the seven UI subtrees, with their types and upstream's defaults.
`docs/settings-surface.md` is the human-readable map, with a classification of
what should be Nix-defined and what is session state the UI owns.

### The typed tree: `settingsExtra.*`

`settings.common` is free-form, and it stays that way — it is the escape
hatch, and it is what per-account overrides use. But every one of the 410
settings is *also* a typed option, so the good path is the obvious one:

```nix
services.sillytavern-nixos = {
  settingsExtra = {
    powerUser = {
      font_scale = 1.2;
      chat_width = 60;
      instruct.preset = "Alpaca";
    };
    oaiSettings = {
      openai_max_context = 32768;
      temp_openai = 0.7;
      custom_url = "https://llm.example.com/v1";
    };
    worldInfoSettings.world_info_depth = 4;
  };
};
```

| Option | `settings.json` key | Fields |
|---|---|---|
| `settingsExtra.powerUser` | `power_user` | 182 |
| `settingsExtra.oaiSettings` | `oai_settings` | 106 |
| `settingsExtra.textGenerationSettings` | `textgenerationwebui_settings` | 61 |
| `settingsExtra.naiSettings` | `nai_settings` | 24 |
| `settingsExtra.kaiSettings` | `kai_settings` | 20 |
| `settingsExtra.hordeSettings` | `horde_settings` | 4 |
| `settingsExtra.worldInfoSettings` | `world_info_settings` | 13 |

Three things to know about them:

- **The names are upstream's own**, verbatim — `font_scale`, not
  `fontScale`. These options mirror a JSON document, and a mirror that
  renames things is a mirror you have to translate in your head.
- **`null` means "not declared".** Every leaf is `nullOr <type>` with
  `default = null`, and an undeclared setting is simply absent from the
  file, so the account keeps upstream's own default. Upstream computes some
  defaults at runtime — a theme colour is read out of the CSS — and pinning
  them here would freeze them.
- **A typo is an error, not a shrug.** `font_scal` is refused at
  evaluation time, with the right spelling suggested:

  ```
  error: The option `services.sillytavern-nixos.settingsExtra.powerUser.font_scal'
         does not exist. Definition values: …
         Did you mean `services.sillytavern-nixos.settingsExtra.powerUser.font_scale'?
  ```

The tree is *generated* from the same inventory the guard uses, so it cannot
drift from upstream: a setting added upstream becomes an option, and one
removed upstream stops being accepted. `nix flake check` proves it both ways
(`settingsTypedTree`, `settingsTypedTreeRefusesTypos`).

**Precedence** is unchanged: `settingsExtra` is the base layer,
`settings.common` overrides it, and `settings.byUser` overrides both. So the
same leaf can be set in more than one place, and the more specific one wins.

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
| **The shipped `default/content` set** | Presets, backgrounds and characters baked into the package and copied into the data root on first start. Reachable per account through `files` or `presets`, but you cannot *remove* or *replace* the shipped set short of overriding `package`. |
| **`cookie-secret.txt`** | Generated on first start and written 0600. Unlike the other three secrets it has no `…File` option. |
| **Chats** | Deliberately not seeded. They are the user's own writing, and `chats/` is created at runtime. |
| **Vector-store documents** | The index is built at runtime from an embeddings API, so documents cannot be seeded offline. |
