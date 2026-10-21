# Nix coverage map

**Generated from a real audit run, not written by hand.** Every number below
comes from:

```bash
python3 .opencode/skills/nix-coverage/scripts/audit.py
```

The audit derives the left-hand side from upstream's own sources at the pinned
version and gets the right-hand side from Nix. Regenerate this file's numbers
by re-running it; if a number here disagrees with it, the audit wins.

Last verified: `config.yaml` at the pinned 1.19.0. The four coverage numbers
below come from the audit; the check list comes from `lib/tests.nix`.

---

## Summary

| Surface | Covered | Of | Status |
|---|---|---|---|
| `config.yaml` keys | **109** | 109 | **100%** |
| CLI flags | **31** | 31 | **100%** |
| `settings.json` keys (the UI) | **439** | 439 | **100%** — via `settings.common` / `settings.byUser`, now *enforced*; and **all 439 also have a typed option** |
| `SILLYTAVERN_*` env overrides | all | all | **via `extraConfigEnv`** — see precedence |
| Per-account state (files/presets/themes) | all known | — | **via `files.byUser` / `files.<name>`** |
| Module options declared | 1059 | — | — |

The first three rows are **computed by the audit** and re-derived on every run.
The last two are **not** — they are maintained by hand, and a hand-maintained
number is a claim, not a measurement. The suite that should protect them is
listed in `lib/tests.nix`; run `nix flake check`.

There is no known gap in the four configurable surfaces. The remaining items
are listed honestly below, with the reason each is not a gap.

---

## 1. `config.yaml` — 100%

Every leaf key in `default/config.yaml` has an option under
`services.sillytavern-nixos.config.<key>`.

- **Source of truth:** `default/config.yaml` (upstream, pinned).
- **Nix side:** the module's option tree, read via
  `lib.optionAttrSetToDocList`.
- **Proof it stays true:** the `configYamlRoundTrip` check renders the module's
  defaults back to YAML, parses with the same `yaml` npm package the server
  uses, and byte-compares against upstream's document. A key added upstream
  without an option fails that build.

### Known exceptions inside config.yaml

| Key | Why it is not a gap |
|---|---|
| `browserLaunch` | Upstream exists; the module forces it **off** and asserts, because a Nix store path has no browser to launch. Covered by `browserLaunchDisabled`. |
| `basicAuthUser` | A credential. Set via `basicAuthUser.passwordFile`, not inline, so it never reaches the store. Covered by `secretsExcluded`. |
| `logging.accessLog` | Defaults on; rotation added via systemd tmpfiles. |
| `thumbnails.dimensions` | Upstream models a fixed-key inline map; the module exposes `bg`/`avatar`/`persona` explicitly. The audit parses the inline form so all three are seen. |

## 2. CLI flags — 100%

All 31 flags in `src/command-line.js` have an option under `cli.*`.

**Precedence:** argv outranks `config.yaml` (`src/util.js`). The module renders
`cli.*` into argv, so a `config` value and a `cli` value can disagree — the
`cli` one wins. This is upstream behaviour, not a wrapper bug, and it is the
reason both surfaces must be covered.

## 3. `SILLYTAVERN_*` environment — via escape hatch

Every `config.yaml` key is *also* reachable as
`SILLYTAVERN_<UPPERCASE_PATH_WITH_DOTS_AS_UNDERSCORES>`, because
`getConfigValue` (`src/util.js:88`) derives the variable name from the key.

> **Precedence hazard — the most surprising behaviour in the config system.**
> `getConfigValue` checks `process.env` **before** the config object. A
> `SILLYTAVERN_*` variable therefore **silently overrides** the rendered
> `config.yaml`. A Nix option can be perfectly correct and still lose.

Mitigations in place:

- `extraConfigEnv` — a documented escape hatch for arbitrary `SILLYTAVERN_*`
  vars.
- `lib.keyToEnv` — the Nix reimplementation of the name mapping, **pinned**
  against upstream's real function by the `libHelpers` check over every key
  path in `config.yaml` (134 cases). A "harmless" camelCase cleanup fails that
  build by name.

The audit re-checks this precedence hazard on every run and reports if
`getConfigValue` stops checking env first.

## 4. Per-account state

| State | Nix mechanism |
|---|---|
| settings (`settings.*`) | `settings.byUser.<handle>` |
| top-level settings.json keys (`main_api`, `max_context`, `background`, `proxies`, `swipes`, `username`, `extension_settings`) | `settingsExtra.*` |
| presets, themes, lorebooks, quick replies | `files.byUser.<handle>.<path>` |
| per-user extensions (a directory tree) | `files.byUser.<handle>.<path>.path` |
| API keys / secrets | `secrets.byUser.<handle>`, read from files at activation |
| error pages | `errorPages.*` |

Seeding is done by `scripts/st_seed_files.py` at activation, driven by a seed
spec rendered from the option tree. Policy is per-entry `policy`
(`missing`/`overwrite`) plus a global `seedPolicy`, and per-entry `mode`.

## 4a. `settings.json` — the UI's own settings (100%, and now checked)

`settings.json` is the *other* backend: not `config.yaml` (which drives the
server) but the per-account state the **browser** reads by direct property
access. It is 24 top-level keys over seven subtrees, and it holds **439 leaf
fields** across the UI's tabs:

| Subtree | Leaf fields | Source |
|---|---|---|
| `power_user` (User Settings) | 182 | `public/scripts/power-user.js` |
| `oai_settings` (AI Response Configuration) | 106 | `public/scripts/openai.js` |
| `textgenerationwebui_settings` (Text Completion) | 90 | `default/content/presets/textgen/*.json` + `public/scripts/textgen-settings.js` |
| `nai_settings` (NovelAI) | 24 | `public/scripts/nai-settings.js` |
| `kai_settings` (KoboldAI Classic) | 20 | `public/scripts/kai-settings.js` |
| `world_info_settings` (World Info) | 13 | `public/scripts/world-info.js` |
| `horde_settings` (AI Horde) | 4 | `public/scripts/horde.js` |

**Coverage was always 100% and never was, at the same time.** Every one of
those fields was reachable through `settings.common` / `settings.byUser` — but
nothing enumerated them, so a typo was accepted silently and did nothing at
all. "Reachable" and "discoverable" are different properties, and only the
first one was true.

Both are now true, and both are measured:

* `lib/settings-inventory.json` — the field list, **derived** from upstream's
  own sources by `scripts/extract_settings_inventory.mjs`. No key is
  hand-written; `settingsInventoryFresh` fails the build if the committed file
  no longer matches the source it came from.
* `settingsKeysKnown` — an assertion that refuses a path upstream does not
  have, and a key outside the 24 the client's save payload contains (the
  browser *deletes* those at the next save, so they look applied until they
  are not).
* `settingsExtra.*` — a **typed option tree** for the seven UI subtrees,
  generated from the same inventory (`lib/settings-tree.nix`), so all 439
  settings are typed options with upstream's own names, types and defaults.
  A typo is an evaluation error with the right spelling suggested, and
  `settingsTypedTree` / `settingsTypedTreeRefusesTypos` prove both
  directions.

The human-readable map, with a classification of what should be Nix-defined
and what is session state the UI owns, is `docs/settings-surface.md`.

## 4b. Locally-run models — `models.*`

SillyTavern runs SOME models itself, in-process: the transformers.js ONNX
pipelines behind the extensions (classification, captioning, embeddings,
speech-to-text, text-to-speech) and the tokenizers they pull in. Those are the
only models it runs.

Everything else — a GGUF file behind llama.cpp, an Ollama tag, a KoboldCpp
checkpoint — belongs to the **inference server**, not to SillyTavern, which has
no inference engine. From Nix you point SillyTavern *at* that server, and that
is covered by the typed settings tree:

| Backend | Option |
|---|---|
| any OpenAI-compatible server (llama.cpp's server, vLLM, LM Studio, Ollama's `/v1`) | `settingsExtra.oaiSettings.chat_completion_source` / `.custom_url` / `.custom_model` |
| Ollama, llama.cpp, KoboldCpp, vLLM natively (Text Completion panel) | `settingsExtra.textGenerationSettings.type` / `.server_urls` / `.ollama_model` … |
| KoboldAI Classic | `settingsExtra.kaiSettings.api_server` |

The weights the ONNX pipelines use were, until this session, **downloaded from
HuggingFace at runtime** into a directory upstream hardcodes
(`src/transformers.js:134`, `path.join(globalThis.DATA_ROOT, '_cache')`) with no
config key and no environment variable. There was no way to say "these weights
are here" from Nix, and no way to keep the server off the network.

There is now:

| Option | Where the weights live | What it is for |
|---|---|---|
| `models.byId` | **in the store**, inside the package, at `node_modules/sillytavern-transformers/models/<model id>/` — the `localModelPath` transformers.js searches | weights that should be pinned, content-addressed and garbage collected with the package |
| `models.directory` | **where you put them** — `<dataRoot>/_cache` becomes a symlink to it | weights managed outside Nix |

A read-only model directory (a store path) forces
`config.extensions.models.autoDownload` off, because transformers.js downloads
into the cache and a download into a read-only one fails with EROFS instead of
the clear "file not found locally".

## 5. Deliberately NOT Nix-drivable

These are correct exclusions, not gaps.

| Item | Reason |
|---|---|
| `chats/`, `group chats/`, `assets/` | The user's own writing. Seeding them would overwrite their work. |
| `user/`, `users/`, `_storage/` | Accounts are seeded by `st_seed_users.py`, not as files. |
| backups | Derived, and disabling/altering them mid-backup is destructive. |
| `public/locales/` (UI language) | Served read-only from the package. **Needs an upstream change** — drafted in `docs/ui-surface.md` §5.1, not filed. |
| `public/index.html` page structure | Fixed markup; 706 controls. Not configuration. |
| `public/scripts/*.js` behaviour | Application code, not configuration. |

---

## 6. Open items (not gaps in coverage)

Carried forward from `docs/ui-surface.md` §5a. None is a missing option.

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | `home-manager` flake input (would let `home.nix` join `nix flake check`) | owner | pending decision |
| 2 | Rename module to `-nixos` (breaking) | owner | not scheduled |
| 3 | ~~`configYamlRoundTrip` needs network / unproxied host~~ | — | **FIXED.** The failure was a real bug, not just environment: the check passed `caCertFile` as a host path (`/etc/ssl/certs/ca-bundle.crt`), which the build sandbox cannot see. Now uses `pkgs.cacert` (a store path). `nix flake check` passes fully. |
| 4 | `noCrossModuleReads` is a grep | — | permanent limitation |
| 5 | Upstream locale issue | owner | drafted, NOT filed |
| 6 | `home.nix` covered by `nix-tests/home-eval.sh`, not a flake check | — | depends on #1 |

---

## 7. Known improvements (easy, unblocked)

Things a future agent can pick up without a decision. These are quality gaps,
not coverage gaps.

Each entry says how to **reproduce** it, because a gap you cannot demonstrate
is a gap you will misdiagnose.

- **Character cards** (`characters/*.png`) — a PNG with embedded JSON, so
  `files.byUser` with `{ path = …; }` works, but there is no first-class option
  for generating a card PNG from Nix.
- **Default content bundle** — controlling/trimming the shipped
  `default/content` is not yet exposed.
- **Generated reverse-proxy vhost** — `proxyUpstreams` carries the settings a
  proxy gets wrong (hosts, maxBodySize, forwardedFor, readTimeout) but does not
  generate an nginx/Caddy vhost.

### Fixed this session

- ~~**`settings.json` keys were unchecked**~~ — **FIXED.**
  `lib/settings-inventory.json` is now derived from upstream's own sources
  (`scripts/extract_settings_inventory.mjs`) and lists all 439 leaf fields of
  the seven UI subtrees, plus the 24 top-level keys the client writes. The
  `settingsKeysKnown` assertion refuses a path upstream does not have, and a
  key outside the client's save payload — the browser deletes those at the
  next save, so they look applied until they are not.
  `settingsInventoryFresh` keeps the inventory from drifting. The repo's own
  examples named settings that do not exist upstream
  (`oai_settings.max_context`, `power_user.quick_ui`); they are fixed.
  See `docs/settings-surface.md`.
- ~~**The 439 settings were reachable but not *typeable***~~ — **FIXED.**
  `settingsExtra.powerUser` and its six siblings are a typed mirror of the
  `settings.json` subtrees, generated from the same inventory by
  `lib/settings-tree.nix`: one option per setting, `nullOr` with `null`
  meaning "not declared", and upstream's names verbatim. A typo is refused at
  evaluation time with the correct spelling suggested. The module went from
  279 declared options to 782, and 1059 now.

- ~~**`configYamlRoundTrip` could not build the `yaml` npm package**~~ — **FIXED.**
  The check passed `caCertFile` as a host path (`/etc/ssl/certs/ca-bundle.crt`),
  which the build sandbox cannot see, so `NODE_EXTRA_CA_CERTS` pointed at nothing
  and npm failed with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`. Now uses
  `pkgs.cacert` (a store path the sandbox can read). `nix flake check` passes
  fully — all 10 checks green.
- ~~**`settings` deep-merge is shallow**~~ — **FIXED.** `modules/config.nix:521`
  now uses `st.deepMerge` (a recursive merge in `lib/default.nix`). The
  `settingsDeepMerge` check in `lib/tests.nix` pins it: a per-account leaf
  override preserves `common` siblings. Mutation-tested.
- ~~**Flat dotted keys are silently inert**~~ — **FIXED.** An assertion in
  `modules/assertions.nix` rejects any attr name containing `.` under
  `settings.*`. The `settings.byUser` example in `modules/options.nix` was
  corrected to nested form.

### Already handled — do not "fix" these

- ~~`--requestProxyBypass` empty list~~ — **already covered**:
  `cli.requestProxyBypass` exists (`modules/options.nix:1744`), the empty list
  is deliberately dropped rather than rendered as a bare flag
  (`lib/default.nix:292`), and `config.requestProxy.bypass` also exists. It was
  listed here once and was wrong.

---

## How to update this file

Re-run the audit. If coverage changes, the numbers change and the "Known
exceptions" or "Deliberately NOT Nix-drivable" tables are where the new row
belongs — with a reason. Do not add a row to the exclusion list without a
reason; that is how a real gap becomes invisible.