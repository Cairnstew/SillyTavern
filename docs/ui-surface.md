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
| UI language | — | **gap**, see §5.1 |
| `DATA_ROOT/_css/user.css` | — | **gap**, see §5.2 |
| Data-root-level files | — | **gap**, see §5.3 |
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
> Verified live: the single-account default case now seeds.

---

## 5. Gaps found

### 5.1 UI language is not configurable, at all

This is harder than it looks. `public/scripts/i18n.js:124` fetches
`./locales/${language}.json` relative to the page, and
`src/server-main.js:242` serves `/` from
`express.static(path.join(serverDirectory, 'public'))`.

So the locale files live in the **Nix store, read-only**, and there is no
writable copy in the data root to override them. 19 languages ship; the only way
to change the language is to edit the language selector in the browser, which
persists in localStorage — per browser, not per account, and not in Nix.

Fixing this properly means the package needs a writable locale directory, or an
override. Until then the most user-visible part of "the UI is not Nix-driven"
is unfixable at the module level, and a Nix option would be misleading. Worth
filing upstream.

### 5.2 `_css/user.css` cannot be reached at all

There are two custom-CSS mechanisms and only one of them is Nix-driven:

- `power_user.custom_css` lives in `settings.json`, is applied by
  `applyCustomCSS()` (`public/scripts/power-user.js:1147`), and **is** seedable
  via `settings.common`. This is the textarea in the UI Theme panel.
- `DATA_ROOT/_css/user.css` is a **file**, and is the other mechanism.
  `public/css/!USER-CSS-README.md` says so explicitly:

  ```
  user.css is now located under your data root directory in the "_css" folder.
  ```

  It is the migration destination for the old `public/css/user.css`
  (`src/users.js:511`) and is served from the data root
  (`src/endpoints/content-manager.js:379`).

That second one is unreachable from the module: `files.common` is documented as
relative to each *account's* directory, and `dataRootFiles` in the seeder spec
is hard-coded to `{}` (`modules/config.nix`, with a comment explaining why).

A user who edits CSS through the UI's file editor rather than the textarea
gets a file the module cannot manage, so it will not survive a data-root reset
and cannot be declared in Nix.

Two options:
- Add a `files.dataRoot` option (at least `css/user.css`), or
- Add a dedicated `customCssFile` option taking a path.

Both are small. The second is cleaner and matches how `secrets.byUser` now works.

### 5.3 `dataRootFiles` is hard-coded empty

`modules/config.nix` deliberately sets `dataRootFiles = { }`, because listing
`files.common` there was a real bug that seeded everything twice and created
stray directories SillyTavern never reads. That reasoning is still correct — but
it means a whole category (data-root-level files: `_css`, `_cache`, the
top-level `content` index) is unreachable by design, and `_css` is a legitimate
member of that category.

Worth an explicit option rather than repurposing `files.common`, so the bug
cannot recur.

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