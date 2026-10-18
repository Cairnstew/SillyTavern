# The UI surface, and what of it should be Nix-defined

A reference map of where SillyTavern's user interface is defined, which parts of
it are real configuration, and which are runtime state that must NOT be seeded.

Everything here was derived from the source at the pinned version (1.19.0). The
line numbers are the evidence for each claim; regenerate them with the
commands in each section if the source moves.

This is a *mapping* document. It exists to answer "if I wanted this in Nix, what
would it take?" — it is not a promise that every row is implemented. The
**Status** column is the honest current state, and the gaps are the point.

---

## 1. Where the UI is defined

The UI is not in one place. There are five layers, and they have different
Nix answers.

| Layer | Where | Size | Nix answer |
|---|---|---|---|
| Page structure | `public/index.html` | 8 231 lines, 706 controls with an `id` | **No.** Fixed markup. |
| Behaviour | `public/scripts/*.js` | 76 files, ~80 000 lines | **No.** |
| Appearance | `public/style.css` + `public/css/` (32 files) | 6 464 lines + | **Partly** — see §5. |
| Translations | `public/locales/*.json` (19 languages) | | **Yes**, via `files`. |
| Themes | `default/content/themes/`, per-account `themes/` | 5 shipped | **Yes**, via `files`. |

Supporting entries: `public/login.html` (23 controls) is the separate login page,
and `public/lib/` is vendored third-party JS that must never be edited.

### 1.1 There is no declarative binding layer

This is the single most important thing to know before trying to map controls to
settings.

SillyTavern has a `data-setting="…"` attribute on 5 elements in `index.html`,
which looks like a declarative binding system. **It is not one.** Nothing reads
it — `grep -rn "data-setting" public/*.js public/scripts/*.js` returns nothing.
It is vestigial markup.

The real binding is hand-written, per control:

```js
$('#stream_openai').val(oai_settings.stream_openai)[0].checked = oai_settings.stream_openai;
$('#stream_openai').on('change', function () { oai_settings.stream_openai = this.checked; saveSettingsDebounced(); });
```

So there is no static manifest to read. A tool that wants control → setting
mapping has to correlate `$('#id')` accesses with `settings.*` assignments in
the surrounding code. §2 gives the resulting inventory by hand.

### 1.2 The two settings backends

`config.yaml` (51 keys, fully Nix-defined — see `modules/options.nix`) drives the
**server**. `settings.json` (per-account) drives the **UI**. They are different
systems and this document is about the second one.

`main_api` (`public/index.html:2290`) selects which backend subtree is live:

```html
<select id="main_api">
    <option value="textgenerationwebui">Text Completion</option>
    <option value="openai">Chat Completion</option>
    <option value="novel">NovelAI</option>
    <option value="koboldhorde">AI Horde</option>
    <option value="kobold">KoboldAI Classic</option>
</select>
```

Each option has its own settings subtree and its own presets. Only the selected
one's subtree matters at runtime; the rest are still written to disk.

---

## 2. What actually gets written to `settings.json`

The authoritative list is the payload of `saveSettings()`,
`public/script.js:8051` → `:8068`. This is the complete set — 24 keys, not the
~19 an inspection suggests:

```
accountStorage          firstRun                  swipes
active_character        horde_settings            tag_map
active_group            kai_settings               tags
amount_gen              main_api                   textgenerationwebui_settings
background              max_context                user_avatar
currentVersion          nai_settings               username
extension_settings      oai_settings               world_info_settings
power_user              proxies                    selected_proxy
```

### 2.1 Subtree sizes

Extracted from the default-value object literals:

| Key | Source | Top-level keys |
|---|---|---|
| `oai_settings` | `public/scripts/openai.js:520` (`default_settings`) | **104** |
| `power_user` | `public/scripts/power-user.js:116` | **147** |
| `kai_settings` | `public/scripts/kai-settings.js:28` | **21** |
| `nai_settings` | `public/scripts/nai-settings.js:36` | **25** |
| `horde_settings` | `public/scripts/horde.js:25` | **4** |
| `world_info_settings` | `public/scripts/world-info.js:795` (`getWorldInfoSettings`) | **13** |
| `textgenerationwebui_settings` | per-preset, not a literal — 61 keys in `textgen/Universal-Light.json` | **~61** |

`oai_settings` + `power_user` alone are 251 keys. That is the size of the
problem: this is not a config file, it is the application state.

---

## 3. Classification: what should be Nix-defined

The dividing line is **intent**, not location. A setting belongs in Nix when a
sysadmin would want to declare it for everyone and have it enforced. It does
not belong there when it is a per-user working state that the UI owns.

### 3.1 SHOULD be Nix-defined — durable, uniform, declarative

| Area | Keys | Route |
|---|---|---|
| **Prompt templates** | `power_user.instruct`, `.context`, `.sysprompt`, `.reasoning` | `files.byUser` (the `instruct/`, `context/`, `sysprompt/`, `reasoning/` dirs) |
| **Sampling defaults** | `oai_settings.temp_openai`, `.top_p_openai`, `.top_k_openai`, `.min_p_openai`, `.top_a_openai`, `.freq_pen_openai`, `.pres_pen_openai`, `.repetition_penalty_openai` | `settings.common` |
| **Sampling (textgen)** | the 61 keys of a textgen preset | `files.byUser."TextGen Settings/*.json"` |
| **Model choice** | `oai_settings.openai_model`, `.claude_model`, `.google_model`, `.custom_url`, `.custom_model` | `settings.common` |
| **Generation caps** | `oai_settings.openai_max_context`, `.openai_max_tokens`, `max_context` | `settings.common` |
| **Server-side mirror** | `config.customUrl`, `config.openaiModel`, … | `config.*` (already done) |
| **UI theme** | `power_user.theme`, `.movingUI`, `.movingUIPreset`, `.movingUIState` | `settings.common` + `files` for `movingUI/` |
| **Typography & colours** | `power_user.font_scale`, `.main_text_color`, `.quote_text_color`, `.bot_mes_blur_tint_color`, `.chat_tint_color`, `.shadow_color`, `.border_color` | `settings.common` |
| **Custom CSS** | `power_user.custom_css` — reachable via `settings.common` | `settings.common` ✅ |
| **Custom CSS file** | `DATA_ROOT/_css/user.css` — **not reachable** | see §5.2 |
| **World info policy** | `world_info_settings.world_info_depth`, `.world_info_budget`, `.world_info_recursive`, `.world_info_max_recursion_steps`, `.world_info_case_sensitive`, `.world_info_match_whole_words` (13 keys, `world-info.js:795`) | `settings.common` |
| **Format presets** | the world book files themselves, incl. per-entry `extensions.scan_depth` (`src/endpoints/characters.js:697`) | `files.byUser."worlds/*.json"` |
| **Bias presets** | `oai_settings.bias_preset_selected`, `.bias_presets` | `files.byUser."openai/settings.json"` |
| **Macros** | `power_user.custom_stopping_strings` | `settings.common` |
| **Model templates** | `power_user.model_templates_mappings` | `files.byUser."instruct/*.json"` |
| **Locales** | UI language | `files.byUser."…"` — see §3.4 |
| **Provider keys** | `api_key_*` | `secrets.byUser` (done) |

### 3.2 SHOULD be per-user, NOT declared in Nix — belongs to the session

These are written to `settings.json` but are the UI's working state. Declaring
them in Nix would fight the user on every activation.

| Key | Why |
|---|---|
| `active_character`, `active_group` | which chat is open |
| `swipes` | per-message swipe state of the current chat |
| `background` | current background image selection |
| `firstRun` | onboarding flag — setting it wrong skips or repeats onboarding |
| `currentVersion` | version marker used for migrations |
| `username` | set from the login, not configured |
| `accountStorage` | **not even in settings.json** — `public/scripts/util/AccountStorage.js`, localStorage |
| `proxies`, `selected_proxy` | which proxy this user picked |
| `power_user.waifuMode` | view mode |
| `power_user.movingUIState` | live drag positions |
| `oai_settings.show_thoughts` | per-session display toggle |

**Rule of thumb:** if the value answers "what am I looking at right now?", it is
session state. If it answers "how should this instance behave?", it is config.

### 3.3 MUST NOT be seeded at all

Refused by `st_seed_files.py`, and correctly so:

- `stats.json` — token/message counters, written continuously
- `backups/` — automatic rollback copies
- `_storage/` — the account database (node-persist). Written by `st_seed_users.py`,
  which understands the scrypt format; writing it as JSON would corrupt it.
- `_webpack/` — build cache
- `_errors/` — error logs
- `_cache/` — transformers.js ONNX model cache (`DATA_ROOT/_cache`,
  `src/transformers.js:134`), hundreds of MiB of downloaded weights
- `secrets.json` via `files` — must go through `secrets.byUser`

### 3.4 Preset categories

`data-preset-manager-file` in `index.html` is the authoritative list of
file-backed preset categories. Each maps to a per-account subdirectory:

| Category | Directory | Shipped |
|---|---|---|
| `context` | `context/` | 34 |
| `instruct` | `instruct/` | 38 |
| `sysprompt` | `sysprompt/` | 13 |
| `textgenerationwebui` | `TextGen Settings/` | 6 |
| `kobold` | `KoboldAI Settings/` | 6 |
| `novel` | `NovelAI Settings/` | 24 |
| `reasoning` | `reasoning/` | 5 |
| *(no manager button)* | `OpenAI Settings/`, `QuickReplies/`, `movingUI/` | 1, 1, 1 |

All of these are already reachable through `files.byUser.<handle>."<dir>/<name>.json"`.
**Status: done.**

---

## 4. Status against the module

| Group | Route | Status |
|---|---|---|
| `config.yaml`, 51 keys | `config.*`, `cli.*` | **done** |
| `settings.json` any path | `settings.common` / `settings.byUser` | **done** (deep-merged) |
| Any per-account file | `files.common` / `files.byUser` | **done** |
| Provider API keys | `secrets.byUser` | **done** |
| Accounts | `users.<handle>` | **done** |
| Instance-wide CSS | `customCss` | **done** (Nix-authoritative), see §5.2 |
| UI language | — | **UPSTREAM CHANGE REQUIRED**, see §5.1 |
| Other data-root-level files | — | **out of scope by design**, see §5.3 |
| Vector store documents | `config.extensions.vectors` (server side) | **partial** — the index is runtime-built and needs an embeddings API, so documents cannot be seeded offline |

Everything in §3.1 is reachable today through `settings.common` or `files`.
Verified by rendering a spec with one example from each row and reading back the
result: all three subtrees and all three file paths landed as documented.

> **Fixed while writing this document.** The reachability claim above was FALSE
> when it was first written. `seedHandles` was the union of the `byUser` maps
> only, so `settings.common` and `files.common` — documented as applying to
> *every* account — produced an **empty spec** unless a handle was also named in
> some `byUser` map. A config using nothing but `.common` silently seeded
> nothing. `seedHandles` now includes `attrNames cfg.users` and `default-user`.
> Verified live: the single-account default case now seeds. Regression check:
> `seedSpecCoversCommon`.

### 4.1 The shadowing trap: `services.sillytavern`

nixos-unstable ships **its own** `services.sillytavern` NixOS module. Ours is
`services.sillytavern-nixos`, and the two coexist — `config.services` contains
both names at once. That makes `osConfig.services.sillytavern` resolve to the
*other* module, silently, with no error at the point of the mistake.

This bit twice, and both instances are now fixed:

| Site | Symptom |
|---|---|
| `modules/home.nix` | read `osConfig.services.sillytavern`, got nixpkgs' module, which has no `config` sub-option → `error: attribute 'config' missing`, a **hard eval failure**. The module could not be built at all with an instance in scope. |
| `lib/default.nix` (`mkProxyUpstream`) | same mistake in an **exported** flake lib function, so the example documented on the `proxyUpstreams` option failed to evaluate for anyone following it. |

Two things made each hard to see:

1. **`or null` hid it.** The fallback meant the module only ever "worked" in the
   one case where it could not — no instance in scope, so the URL fell back to
   `http://localhost:8000`.
2. **Laziness hid it in tests.** Asserting with
   `builtins.attrNames cfg.home.packages` **passes** against a module that
   cannot evaluate, because the generated script's URL lives in the
   derivation's lazy `text` attribute and is only forced on build. The first
   version of the harness reported PASS this way. It must **build** the
   derivation and read the file. `nix-tests/home-eval.sh` does, and fails with
   5 of 8 assertions against the pre-fix module.

Rule of thumb for this repo: any option path read from *another* module's
namespace is `services.sillytavern-nixos`, full stop. A sweep of every `or null`
/ `or {}` in the module is recorded in the `21e84086b` commit message.

### 4.1.1 Collision inventory (verified against nixpkgs `fe132422`)

`nixos/modules/services/web-apps/sillytavern.nix`, registered in
`module-list.nix:1858`, so it is **always in scope** — every NixOS system
imports the whole module list whether or not anyone wants it.

| Surface | nixpkgs | this module | Collides? |
|---|---|---|---|
| Option namespace | `services.sillytavern` | `services.sillytavern-nixos` | No — distinct attrs |
| `systemd.services.sillytavern` | declared | declared (`modules/services.nix:234`) | **YES** |
| `users.users.sillytavern` | `isSystemUser` | same account | **YES** (description also differs) |
| `serviceConfig.StateDirectory` | `"SillyTavern"` | `"sillytavern"` | **YES** |
| `serviceConfig.Restart` | `"always"` | `"on-failure"` | **YES** — this is what surfaces first |
| `users.users.sillytavern.description` | `"sillytavern service user"` | `"SillyTavern LLM front-end server"` | **YES** |
| port | `null` (passed as a flag) | `config.port`, default `8000` | No |
| tmpfiles | `settings.sillytavern` → `/var/lib/SillyTavern/{data,extensions}` + config symlink | none | No, but stray dirs appear |
| extra units | none | `sillytavern-package`, `sillytavern-healthcheck` | No |

Verified that nixpkgs' `config` is a **single `lib.mkIf cfg.enable`** (line 93)
with all four declarations inside and nothing unconditional, so
`enable = false` genuinely contributes nothing.

### 4.1.2 What happens today, both enabled

Fails at **eval** time — loud, but naming the wrong cause:

```
error: The option `systemd.services.sillytavern.serviceConfig.Restart' has
conflicting definition values:
  - nixpkgs: "always"
  - ours:   "on-failure"
```

Forcing past it (`Restart` and `StateDirectory`) produces a merged unit whose
`ExecStart` is:

```
[ ".../sillytavern-1.19.0/bin/sillytavern",           <- nixpkgs' binary
  ".../sillytavern-service/bin/sillytavern-service",   <- OUR wrapper
  "--configPath=/nix/store/...-sillytavern-config.yaml",
  "--dataRoot=/var/lib/sillytavern" ]
```

⚠ **INFERRED, NOT OBSERVED.** The `ExecStart` list is what the module system
computes and was read back from an evaluated system. "This would not start"
is inference from that shape — no boot was attempted.

So the risk is not that it fails; it is that the error names `Restart` rather
than "two modules own one unit", and forcing past it *looks* reasonable.

### 4.1.3 Status

Done: an assertion rejects the combination, with a message that names the real
cause, the three contested surfaces, which namespace is ours, and what to do.
`!cfg.enable || !upstreamEnabled` — the `cfg.enable` arm matters because
`modules/sillytavern.nix` imports `assertions.nix` **unconditionally**, so
without it a user running nixpkgs' module alone would be blocked by a module
they never enabled.

Backed by `upstreamCollisionAsserted` (four cases against the real nixpkgs
module) and `noCrossModuleReads` (grep for the cross-namespace read).

### 4.1.4 Planned breaking change — renaming to `-nixos`, NOT implemented

Agreed direction, deliberately **not** done here because it is breaking.

Rename all three surfaces to `sillytavern-nixos`:

```
systemd.services.sillytavern-nixos
users.users.sillytavern-nixos
StateDirectory = "sillytavern-nixos"
```

For: structurally impossible to collide, and it matches the option namespace
already chosen. Against: existing deployments lose the `sillytavern.service`
name and `/var/lib/sillytavern`.

**Migration for existing users:**

1. `systemctl disable sillytavern.service` before the first switch — otherwise
   the old unit's state directory is orphaned, not migrated.
2. Move the data, OR keep the old location via
   `stateDirectory = "sillytavern";` (the option already exists and
   `dataRoot` derives from it, so a one-line override keeps the data). The
   override is the low-risk path and should be documented as the recommended
   first step.
3. Note that the *account* rename changes ownership of `/var/lib/sillytavern`;
   either chown it or set `user = "sillytavern"` to keep it.

Sequencing: the assertion ships first (this commit) so the failure mode is
actionable in the meantime; the rename goes in the next major.

Rejected: building *on* nixpkgs' module. It hardcodes
`${package}/lib/node_modules/sillytavern/config.yaml`, passes flags as one
quoted string (the exact bug this module exists to fix), and has no account
seeding, JSON state, or secrets. Adopting it would mean discarding
`modules/services.nix`, both seeders, and the entire JSON layer.

### 4.2 `configYamlRoundTrip` is UNVERIFIED on this host

> Do not read the green `nix flake check --no-build` as this check passing.
> **It evaluates; it does not build on this machine.**

- **Check:** `checks.<system>.configYamlRoundTrip`
- **Host:** the development host for this repo (NixOS, nixpkgs
  `fe13242281a67641c0102cdb1087f0ebe586c7df`, Nix 2.34.8, `x86_64-linux`).
- **Reason:** the check's fixed-output derivation runs `npm install yaml@2.8.3`
  from `registry.npmjs.org`. This host reaches the npm registry through a
  **TLS-intercepting proxy**, and Node rejects the substituted certificate:

  ```
  npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY
  npm error request to https://registry.npmjs.org/yaml failed,
            reason: unable to get local issuer certificate
  ```

  A `caCertFile` / `NODE_EXTRA_CA_CERTS` workaround was added to the derivation
  and did not help; the interception is not trusted by this Node.

**What IS verified:** the same round-trip was performed directly against the
real `yaml` package during development and every modelled key matched upstream.
**What is NOT verified:** that the check builds *as written* in `lib/tests.nix`.
If you run CI on an unproxied host, run it once before trusting it — the failure
mode if the check is broken is the same shape as the TLS failure, so a green
build there is the only real evidence.

The other six checks build and pass on this host.

---

## 5. Gaps found

### 5.1 UI language — UPSTREAM CHANGE REQUIRED

**This cannot be fixed in the module.** Marking it separately from the gaps
below because the remedy is not a Nix option; it is a change to SillyTavern.

The chain, verified at the pinned version:

```js
// public/scripts/i18n.js:124
const data = await fetch(`./locales/${language}.json`).then(...)
```
```js
// src/server-main.js:242
app.use(express.static(path.join(serverDirectory, 'public'), {}));
```

`serverDirectory` is the unpacked package — the **read-only Nix store**. The
locale files are served straight out of it, and there is no data-root copy and
no override route. 19 languages ship (`public/locales/`); the only way to change
language is the selector in the browser, which persists in localStorage — per
browser, not per account, and not in Nix.

Any Nix option for this would be a lie: it could not do anything.

> **Draft upstream issue — NOT FILED.** Hold this until you want it sent; the
> wording below is a proposal, not a submission.

**Title**
> Allow the UI locale to be overridden from the data directory

**Body**
> The UI language is currently fixed to whatever is served from the package.
> `public/scripts/i18n.js` fetches `./locales/${language}.json` relative to the
> page, and `src/server-main.js` serves `/` from `express.static()` rooted at
> `serverDirectory` — the package directory. On a read-only or immutable
> deployment (Nix store, container image, squashfs) there is therefore no way to
> change the UI language except the browser's own selector, which is per-browser
> and does not survive a new machine or a new profile.
>
> Other user-editable assets have already been given a data-root escape hatch —
> `user.css` is served from `DATA_ROOT/_css/user.css` by
> `src/middleware/userCss.js`. Locales were not.
>
> Proposal: make the locale lookup consult the data root first, in the same
> spirit as the existing `_`-prefixed migrations in `src/users.js`, e.g. try
> `DATA_ROOT/_locales/<language>.json` before falling back to the package. A
> configuration key (or an explicit `locales.dir`) would keep it discoverable.
>
> This matters for any deployment where a fleet of machines must present a
> consistent language to all users, which today is not expressible.

### 5.2 `_css/user.css` — RESOLVED (`customCss`)

> **Correction.** An earlier draft of this document cited `src/users.js:511` as
> where `_css/user.css` is *resolved*, and treated it as the thing to seed
> against. That was wrong, and it mattered: it implied the file was only ever
> written by a one-shot migration. Re-checked at the pinned version —
>
> - `src/users.js:510-511` is one row of a **migration table**, not a resolution
>   path. It copies a legacy `public/css/user.css` into the data root, and only
>   `if (fs.existsSync(oldPath))`, skipping when the target already exists. It
>   runs once and then never again.
> - The **real** resolution point is `src/middleware/userCss.js:10`:
>
>   ```js
>   const userCssPath = path.resolve(path.join(globalThis.DATA_ROOT, '_css', 'user.css'));
>   if (fs.existsSync(userCssPath)) { res.sendFile(userCssPath); return; }
>   next();
>   ```
>
>   That is what serves `public/index.html:46`'s `<link href="css/user.css">` —
>   unauthenticated, to every visitor. `src/endpoints/content-manager.js:379`
>   is only where `_css` is the *global target* for content-manager writes.

There are two custom-CSS mechanisms, and now both are Nix-driven:

| Mechanism | Where it lives | Option |
|---|---|---|
| In-browser editor (textarea) | `power_user.custom_css` in `settings.json`, applied by `applyCustomCSS()` (`public/scripts/power-user.js:1147`) | `settings.common` |
| Instance-wide stylesheet | `DATA_ROOT/_css/user.css`, served by `userCssMiddleware` | **`customCss`** |

```nix
services.sillytavern-nixos.customCss = ./ui-overrides.css;
```

**Nix-authoritative: overwritten on every activation, ignoring `seedPolicy`.**
That is deliberate and opposite to every other file in the module, because
create-only would protect nothing:

- Nothing in the server *writes* this file. `_css` is the global content-manager
  target for `CONTENT_TYPES.STYLESHEET`, but the only routes that write there are
  `importURL` and `importUUID`, and `grep -rn contentmanager public/` finds
  nothing — there is no UI for it.
- The editor people actually use is `power_user.custom_css`, which is a
  different file in `settings.json` and is seeded create-only like everything
  else.

Under the default `"missing"` policy the file would be written once and never
updated, so editing the option would silently do nothing — the exact failure
this option exists to fix. Verified live: a second activation logs `restored`
(not `skipped`) and a **running** server serves the new content with no restart,
because the middleware reads from disk on every request.

**Mode `0644`, not the seeder's `0600`.** `res.sendFile` hands this to every
visitor; owner-only would be wrong for it even though it is right for
`settings.json`.

**`unset` never touches the file**, and removing the option does not delete a
previously-seeded one — it stops managing it. A hand-written or migrated
`_css/user.css` survives an activation with `customCss` unset (verified live:
`0 written, 0 left alone`).

Isolation from the original double-seeding bug is structural: `dataRootFiles` is
fed from `customCss` alone with a literal key, so it and the per-user `files`
maps have disjoint sources. Two assertions enforce it at eval time rather than
trusting it.

### 5.3 Data-root-level files — narrowed, not opened

`dataRootFiles` in `modules/config.nix` is still empty of anything but
`customCss`. It was emptied deliberately: listing `cfg.files.common` there as
well was a real bug that seeded every file twice and created stray top-level
directories SillyTavern never reads. **That reasoning still holds**, so the fix
was not to repopulate the map from `files.common`.

What exists now:

```nix
dataRootFiles = lib.optionalAttrs (cfg.customCss != null) {
  "_css/user.css" = { path = toString cfg.customCss; policy = "overwrite"; mode = "0644"; };
};
```

One option, one literal key, disjoint from the per-user maps. The general
escape hatch — a `files.dataRoot` letting users name arbitrary data-root paths
— was considered and **rejected**: it rebuilds the exact footgun that emptied
this map, and the path-safety check is in Python, so a typo would surface at
activation rather than at evaluation.

Still unreachable by design: `_cache` (the transformers.js ONNX model cache,
`src/transformers.js:134`), `content.log` (the content-manager's own bookkeeping,
written by `seedContent`), and `_errors/`. None of them are configuration.

---

## 6. Reproducing this map

```bash
# The 24 settings.json keys
sed -n '8068,8093p' public/script.js | grep -oE '^        [a-zA-Z_]+' | tr -d ' ' | sort -u

# Controls with an id in the main page
grep -oE '<(input|select|textarea)[^>]*id="[^"]+"' public/index.html | grep -oE 'id="[^"]+"' | sort -u | wc -l

# Prove data-setting is not a binding layer
grep -rn "data-setting" public/*.js public/scripts/*.js    # no matches

# Preset categories
grep -oE 'data-preset-manager-file="[^"]+"' public/index.html | sed 's/.*="//;s/"//' | sort -u

# A subtree's keys
sed -n '116,300p' public/scripts/power-user.js
```

---

## 7. Open questions for later

- **Character cards** are `characters/*.png` — a PNG with embedded JSON, not a
  JSON file, so `files.byUser` with `{ path = …; }` works but there is no
  first-class option. Worth considering: cards are the core content of the app.
- **Chat transcripts** (`chats/`) are deliberately not seedable. Correct — they
  are the user's own writing — but worth stating explicitly in the README so it
  is not mistaken for a gap.
- **`movingUI/`** holds per-preset UI layouts. Reachable via `files`, but the
  preset *manager* has no button for it, so it is discoverable only by hand.