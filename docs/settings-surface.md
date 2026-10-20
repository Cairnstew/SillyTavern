# The runtime settings surface — what is Nix-drivable, and what is not

The question this document answers: **the UI has a lot of settings, in a lot of
tabs, with a lot of fields. Which of them can be set from Nix?**

The short answer, and the answer this document backs with evidence:

> **All of them are already reachable from Nix** — `settings.common` and
> `settings.byUser.<handle>` are deep-merged into every account's
> `settings.json`. What was missing was not *reachability* but **knowledge**:
> nothing in the repository enumerated the 410 real setting paths, so a typo was
> accepted silently and did nothing. That is now fixed mechanically
> (`lib/settings-inventory.json`, derived from upstream's own source) and
> enforced at evaluation time (`settingsKeysKnown`).

Everything below is derived, never hand-maintained. Regenerate with:

```bash
node scripts/extract_settings_inventory.mjs      # writes lib/settings-inventory.json
node scripts/extract_settings_inventory.mjs --check   # fails if it is stale
```

`nix flake check` runs the `--check` form, so the inventory cannot drift away
from the source it describes.

---

## 1. Two backends, and the rule that decides which one you are in

| Backend | Written by | Read by | Nix route |
|---|---|---|---|
| `config.yaml` | the operator | the **server** | `config.*`, `cli.*` — 100% covered (`COVERAGE.md`) |
| `settings.json` | the **browser** | the **browser** | `settings.common`, `settings.byUser` |

`settings.json` is per-account, and the client writes the *whole file* on
nearly every UI interaction (`public/script.js:8051`, `saveSettings()`). The
server never interprets it — it stores it and hands it back.

**The consequence that decides everything else.** The client's save payload is a
fixed object of **24 top-level keys** (`public/script.js:8068`). Anything
outside that set is *deleted* at the next save:

```js
const payload = {
    firstRun, accountStorage, currentVersion, username, active_character,
    active_group, user_avatar, amount_gen, max_context, main_api,
    world_info_settings, textgenerationwebui_settings, swipes, horde_settings,
    power_user, extension_settings, tags, tag_map, nai_settings, kai_settings,
    oai_settings, background, proxies, selected_proxy,
};
```

So a Nix key that is not one of those 24 does not merely fail to work — it
*looks* like it worked, until the user saves a setting in the UI. The guard in
§5 refuses those keys at evaluation time.

Inside a known subtree the behaviour is friendlier: the client merges the
saved object over its defaults and writes the whole object back
(`public/scripts/power-user.js:1566`, `Object.assign(power_user,
settings.power_user)`), so unknown *leaf* names survive but are never read.

## 2. The surface, by the tab it comes from

| UI surface | `settings.json` subtree | Leaf fields | Source |
|---|---|---|---|
| AI Response Configuration | `oai_settings` | 106 | `public/scripts/openai.js` |
| User Settings (Interface, Chat, Prompt, Persona …) | `power_user` | 182 | `public/scripts/power-user.js` |
| Text Completion | `textgenerationwebui_settings` | 61 | `default/content/presets/textgen/*.json` |
| NovelAI | `nai_settings` | 24 | `public/scripts/nai-settings.js` |
| KoboldAI Classic | `kai_settings` | 20 | `public/scripts/kai-settings.js` |
| World Info / Lorebook | `world_info_settings` | 13 | `public/scripts/world-info.js` |
| AI Horde | `horde_settings` | 4 | `public/scripts/horde.js` |
| **Total** | | **410** | |

Plus the 24 top-level keys above, of which the ones worth declaring are
`main_api`, `max_context`, `amount_gen`, `username` (already typed as
`settingsExtra.*`), and the free-form `extension_settings`, `tags`, `tag_map`.

The full list of every field, with its type and upstream's default value, is
in the appendix at the end of this document, and machine-readable in
`lib/settings-inventory.json`.

**Free-form maps.** Nine of the settings are objects whose *keys* are data, not
structure — `power_user.personas` is keyed by persona name,
`power_user.persona_descriptions` likewise, `power_user.movingUIState` holds
live drag positions, `power_user.model_templates_mappings` is keyed by model
hash, and `*.extensions` is keyed by extension name. They have no enumerable
leaf fields, so they are recorded separately in the inventory as *open paths*,
and the guard (§5) accepts any key below them.

## 3. What should be Nix-defined, and what should not

The dividing line is **intent**, not location: does the value answer "how
should this instance behave?" (configuration) or "what am I looking at right
now?" (session state)?

### 3.1 Promote to first-class options — instance-wide configuration

These are stable, uniform, and would be tedious to set by hand on every
account. They are the ones worth typed options:

| Group | Fields | Why |
|---|---|---|
| Sampling defaults | `oai_settings.temp_openai`, `.top_p_openai`, `.top_k_openai`, `.min_p_openai`, `.top_a_openai`, `.freq_pen_openai`, `.pres_pen_openai`, `.repetition_penalty_openai`, `.seed`, `.n` | identical for everyone; nobody wants to click through the UI per account |
| Generation caps | `oai_settings.openai_max_context`, `.openai_max_tokens`, `max_context`, `oai_settings.max_context_unlocked` | a policy, not a preference |
| Model selection | `oai_settings.openai_model`, `.claude_model`, `.google_model`, `.custom_url`, `.custom_model` | the same reason `config.openaiModel` exists server-side |
| Connection behaviour | `oai_settings.stream_openai`, `.reverse_proxy`, `.custom_include_body`, `.custom_exclude_body`, `.custom_include_headers`, `.bind_preset_to_connection`, `.show_external_models`, `.squash_system_messages`, `.use_sysprompt` | instance policy |
| Prompting behaviour | `power_user.prefer_character_prompt`, `.prefer_character_jailbreak`, `.user_prompt_bias`, `.always_force_name2`, `.allow_name1_display`, `.allow_name2_display`, `.experimental_macro_engine`, `.custom_stopping_strings` | changes every reply |
| Message handling | `power_user.chat_truncation`, `.auto_scroll_chat_to_bottom`, `.auto_fix_generated_markdown`, `.trim_spaces`, `.collapse_newlines`, `.token_padding`, `.strip_examples`, `.pin_examples`, `.trim_sentences`, `.send_on_enter`, `.continue_on_send`, `.auto_continue.*` | uniform behaviour |
| Appearance | `power_user.theme`, `.font_scale`, `.blur_strength`, `.shadow_width`, `.noShadows`, `.fast_ui_mode`, `.avatar_style`, `.chat_display`, `.chat_width`, `.toastr_position`, `.reduced_motion`, `.compact_input_area`, `.main_text_color`, `.quote_text_color`, `.border_color`, `.shadow_color`, `.chat_tint_color` | one look for the whole instance |
| World Info policy | all 13 of `world_info_settings` (`world_info_depth`, `world_info_budget`, `world_info_recursive`, `world_info_case_sensitive`, …) | a lorebook *policy*, not a lorebook |
| Preset *selection* | `power_user.instruct.preset`, `.context.preset`, `.sysprompt.*`, `.reasoning.*` | the preset content is a file (`files.byUser`); which one is active is a setting |

### 3.2 Leave alone — session state the UI owns

Declaring these in Nix means fighting the user on every activation. They are
in the inventory, and the guard accepts them, but they should not be pinned:

| Field | Why |
|---|---|
| `active_character`, `active_group`, `swipes`, `background`, `proxies`, `selected_proxy` | which chat / image / proxy is open |
| `firstRun`, `currentVersion`, `accountStorage` | onboarding and migration markers |
| `power_user.waifuMode`, `.movingUI`, `.movingUIState`, `.movingUIPreset`, `.personas`, `.persona_descriptions`, `.default_persona` | live UI state and user content |
| `power_user.servers`, `.bogus_folders`, `.charListGrid` | transient view state |
| `tags`, `tag_map` | the user's own tagging |
| `oai_settings.show_thoughts` | a per-session display toggle |

### 3.3 Not settings at all — content, and it goes through `files`

| Thing | Nix route |
|---|---|
| Instruct / context / sysprompt / reasoning presets | `files.byUser."instruct/<name>.json"` etc. |
| Text-generation presets (61 keys) | `files.byUser."TextGen Settings/<name>.json"` |
| Kobold / NovelAI presets | `files.byUser."KoboldAI Settings/…"`, `"NovelAI Settings/…"` |
| Bias presets | `files.byUser."OpenAI Settings/…"` |
| World books (lorebooks) | `files.byUser."worlds/<name>.json"` |
| Themes, backgrounds, quick replies, movingUI layouts | `files.byUser."themes/…"`, … |
| Character cards, chats | user's own content — deliberately not seedable |

## 4. What is *not* reachable from Nix, and why

| Thing | Status |
|---|---|
| UI language (`public/locales/`) | **upstream change required** — the locales are served straight out of the read-only package, with no data-root override. Drafted in `docs/ui-surface.md` §5.1, not filed. |
| Anything the client does not write | now refused at evaluation time (§5) |
| `stats.json`, `_storage/`, `_cache/`, `backups/` | server bookkeeping — correctly not seedable |

## 5. The guard: `settingsKeysKnown`

`modules/assertions.nix` refuses two classes of silently-wrong settings:

1. **A key that is not one of the 24 the client writes.** The browser
   discards it at the next save. The message lists the 24 real keys.
2. **A path inside a known subtree that upstream does not have.** It is
   written to disk and then ignored, because the client reads settings by
   direct property access.

The guard reasons about `lib/settings-inventory.json`, which is derived from
upstream's source by `scripts/extract_settings_inventory.mjs` — no key is
hardcoded in the module. Free-form maps (`power_user.personas`, keyed by
persona name; `oai_settings.extensions`, by extension name) are exempt, and
so are the upstream *object* paths, so that a whole subtree can be set at once.

`lib/tests.nix` asserts **both** directions, because a guard that refuses
everything is as useless as no guard:

* a rich, real configuration produces **no** failure;
* a typo produces exactly one failure, naming the path;
* a key outside the client's payload produces exactly one failure.

## 6. The typed tree — done

Every one of the 410 settings is now a **typed option** as well as reachable
through the free-form blob:

| Option | `settings.json` key | Fields |
|---|---|---|
| `settingsExtra.powerUser` | `power_user` | 182 |
| `settingsExtra.oaiSettings` | `oai_settings` | 106 |
| `settingsExtra.textGenerationSettings` | `textgenerationwebui_settings` | 61 |
| `settingsExtra.naiSettings` | `nai_settings` | 24 |
| `settingsExtra.kaiSettings` | `kai_settings` | 20 |
| `settingsExtra.hordeSettings` | `horde_settings` | 4 |
| `settingsExtra.worldInfoSettings` | `world_info_settings` | 13 |

The tree is **generated** from the same inventory the guard uses
(`lib/settings-tree.nix`), so the two cannot disagree about what a real
setting is, and neither can drift from upstream: a setting added upstream
becomes an option, and one removed upstream stops being accepted.

Two properties worth knowing:

* **Names are upstream's own**, verbatim (`font_scale`, not `fontScale`).
  These options mirror a JSON document; renaming things in the mirror would
  mean translating in your head every time.
* **`null` means "not declared"**, and an undeclared setting is *absent* from
  the file rather than written as `null`. Upstream computes some defaults at
  runtime (a theme colour is read out of the CSS), and a `null` would
  override that default with null — the opposite of "not declared".

A typo is now an evaluation error with the right spelling suggested:

```
error: The option `services.sillytavern-nixos.settingsExtra.powerUser.font_scal'
       does not exist. … Did you mean `…powerUser.font_scale'?
```

`settings.common` remains, and remains free-form: it is the escape hatch, and
it is what per-account overrides use. The precedence is unchanged —
`settingsExtra` is the base layer, `settings.common` overrides it,
`settings.byUser` overrides both — so the same leaf can be set in more than
one place and the more specific one wins.

## 7. What is still open

| # | Item | Status |
|---|---|---|
| 1 | **Promote the *session-state* fields out of the typed tree.** `power_user.active_character`-style fields are in the tree because upstream has them, but pinning them is a mistake waiting to happen. They are documented in §3.2, and the tree does not yet warn about them. | open |
| 2 | **The UI language** (`public/locales/`) | upstream change required — see `docs/ui-surface.md` §5.1 |
| 3 | **Typed options for the eight top-level keys** (`main_api`, `max_context`, …) | they exist as `settingsExtra.mainApi` and friends, with camelCase names that predate the tree's convention. Renaming them is a breaking change. | open, deliberately |
| 4 | **`extension_settings`** | left free-form on purpose: it belongs to extensions, not to this module | correct as is |

---

## Appendix — every setting, with type and upstream default

Generated from `lib/settings-inventory.json`. Regenerate with
`node scripts/extract_settings_inventory.mjs`; the table below is the same
data, rendered.

### `power_user` — 182 leaf fields

Source: `public/scripts/power-user.js`

| Setting | Type | Upstream default |
|---|---|---|
| `charListGrid` | bool | `false` |
| `tokenizer` | unknown | `—` |
| `token_padding` | int | `64` |
| `collapse_newlines` | bool | `false` |
| `pin_examples` | bool | `false` |
| `strip_examples` | bool | `false` |
| `trim_sentences` | bool | `false` |
| `always_force_name2` | bool | `false` |
| `user_prompt_bias` | str | `""` |
| `show_user_prompt_bias` | bool | `true` |
| `auto_continue.enabled` | bool | `false` |
| `auto_continue.allow_chat_completions` | bool | `false` |
| `auto_continue.target_length` | int | `400` |
| `markdown_escape_strings` | str | `""` |
| `chat_truncation` | int | `100` |
| `streaming_fps` | int | `30` |
| `smooth_streaming` | bool | `false` |
| `smooth_streaming_no_think` | bool | `false` |
| `smooth_streaming_speed` | int | `50` |
| `stream_fade_in` | bool | `false` |
| `fast_ui_mode` | bool | `true` |
| `avatar_style` | int | `0` |
| `chat_display` | int | `0` |
| `toastr_position` | unknown | `—` |
| `chat_width` | int | `50` |
| `never_resize_avatars` | bool | `false` |
| `show_card_avatar_urls` | bool | `false` |
| `play_message_sound` | bool | `false` |
| `play_sound_unfocused` | bool | `true` |
| `auto_save_msg_edits` | bool | `false` |
| `confirm_message_delete` | bool | `true` |
| `sort_field` | str | `"name"` |
| `sort_order` | str | `"asc"` |
| `sort_rule` | null | `null` |
| `font_scale` | int | `1` |
| `blur_strength` | int | `10` |
| `shadow_width` | int | `2` |
| `main_text_color` | str | `"unknown"` |
| `italics_text_color` | str | `"unknown"` |
| `underline_text_color` | str | `"unknown"` |
| `quote_text_color` | str | `"unknown"` |
| `blur_tint_color` | str | `"unknown"` |
| `chat_tint_color` | str | `"unknown"` |
| `user_mes_blur_tint_color` | str | `"unknown"` |
| `bot_mes_blur_tint_color` | str | `"unknown"` |
| `shadow_color` | str | `"unknown"` |
| `border_color` | str | `"unknown"` |
| `custom_css` | str | `""` |
| `waifuMode` | bool | `false` |
| `movingUI` | bool | `false` |
| `movingUIPreset` | str | `""` |
| `noShadows` | bool | `false` |
| `theme` | str | `"Default (Dark) 1.7.1"` |
| `gestures` | bool | `true` |
| `auto_swipe` | bool | `false` |
| `auto_swipe_minimum_length` | int | `0` |
| `auto_swipe_blacklist` | array | `[]` |
| `auto_swipe_blacklist_threshold` | int | `2` |
| `auto_scroll_chat_to_bottom` | bool | `true` |
| `auto_fix_generated_markdown` | bool | `true` |
| `send_on_enter` | int | `0` |
| `console_log_prompts` | bool | `false` |
| `request_token_probabilities` | bool | `false` |
| `show_group_chat_queue` | bool | `false` |
| `allow_name1_display` | bool | `false` |
| `allow_name2_display` | bool | `false` |
| `hotswap_enabled` | bool | `true` |
| `timer_enabled` | bool | `true` |
| `timestamps_enabled` | bool | `true` |
| `timestamp_model_icon` | bool | `false` |
| `mesIDDisplay_enabled` | bool | `false` |
| `hideChatAvatars_enabled` | bool | `false` |
| `max_context_unlocked` | bool | `false` |
| `message_token_count_enabled` | bool | `false` |
| `expand_message_actions` | bool | `false` |
| `enableZenSliders` | bool | `false` |
| `enableLabMode` | bool | `false` |
| `prefer_character_prompt` | bool | `true` |
| `prefer_character_jailbreak` | bool | `true` |
| `quick_continue` | bool | `false` |
| `quick_impersonate` | bool | `false` |
| `continue_on_send` | bool | `false` |
| `trim_spaces` | bool | `true` |
| `relaxed_api_urls` | bool | `false` |
| `world_import_dialog` | bool | `true` |
| `enable_auto_select_input` | bool | `false` |
| `enable_md_hotkeys` | bool | `false` |
| `tag_import_setting` | unknown | `—` |
| `tag_sort_mode` | unknown | `—` |
| `disable_group_trimming` | bool | `false` |
| `single_line` | bool | `false` |
| `instruct.enabled` | bool | `false` |
| `instruct.preset` | str | `"Alpaca"` |
| `instruct.input_sequence` | str | `"### Instruction:"` |
| `instruct.input_suffix` | str | `""` |
| `instruct.output_sequence` | str | `"### Response:"` |
| `instruct.output_suffix` | str | `""` |
| `instruct.system_sequence` | str | `""` |
| `instruct.system_suffix` | str | `""` |
| `instruct.last_system_sequence` | str | `""` |
| `instruct.first_input_sequence` | str | `""` |
| `instruct.first_output_sequence` | str | `""` |
| `instruct.last_input_sequence` | str | `""` |
| `instruct.last_output_sequence` | str | `""` |
| `instruct.story_string_prefix` | str | `""` |
| `instruct.story_string_suffix` | str | `""` |
| `instruct.stop_sequence` | str | `""` |
| `instruct.wrap` | bool | `true` |
| `instruct.macro` | bool | `true` |
| `instruct.names_behavior` | unknown | `—` |
| `instruct.activation_regex` | str | `""` |
| `instruct.bind_to_context` | bool | `false` |
| `instruct.user_alignment_message` | str | `""` |
| `instruct.system_same_as_user` | bool | `false` |
| `instruct.separator_sequence` | str | `""` |
| `instruct.sequences_as_stop_strings` | bool | `true` |
| `context.preset` | str | `"Default"` |
| `context.story_string` | unknown | `—` |
| `context.chat_start` | unknown | `—` |
| `context.example_separator` | unknown | `—` |
| `context.use_stop_strings` | bool | `true` |
| `context.names_as_stop_strings` | bool | `true` |
| `context.story_string_position` | unknown | `—` |
| `context.story_string_role` | unknown | `—` |
| `context.story_string_depth` | int | `1` |
| `instruct_derived` | bool | `false` |
| `context_derived` | bool | `false` |
| `context_size_derived` | bool | `false` |
| `chat_template_hash` | str | `""` |
| `sysprompt.enabled` | bool | `true` |
| `sysprompt.name` | str | `"Neutral - Chat"` |
| `sysprompt.content` | str | `"Write {{char}}'s next reply in a fictional chat between {{char}} and {{user}}."` |
| `sysprompt.post_history` | str | `""` |
| `reasoning.name` | unknown | `—` |
| `reasoning.auto_parse` | bool | `false` |
| `reasoning.add_to_prompts` | bool | `false` |
| `reasoning.auto_expand` | bool | `false` |
| `reasoning.show_hidden` | bool | `false` |
| `reasoning.prefix` | str | `"<think>"` |
| `reasoning.suffix` | str | `"</think>"` |
| `reasoning.separator` | str | `"
"` |
| `reasoning.max_additions` | int | `1` |
| `default_persona` | null | `null` |
| `persona_description` | str | `""` |
| `persona_description_position` | unknown | `—` |
| `persona_description_role` | int | `0` |
| `persona_description_depth` | int | `2` |
| `persona_description_lorebook` | str | `""` |
| `persona_show_notifications` | bool | `true` |
| `persona_sort_order` | str | `"asc"` |
| `custom_stopping_strings` | str | `""` |
| `custom_stopping_strings_macro` | bool | `true` |
| `fuzzy_search` | bool | `false` |
| `encode_tags` | bool | `false` |
| `experimental_macro_engine` | bool | `true` |
| `servers` | array | `[]` |
| `bogus_folders` | bool | `false` |
| `zoomed_avatar_magnification` | bool | `false` |
| `show_tag_filters` | bool | `false` |
| `aux_field` | str | `"character_version"` |
| `stscript.matching` | str | `"fuzzy"` |
| `stscript.autocomplete.state` | unknown | `—` |
| `stscript.autocomplete.autoHide` | bool | `false` |
| `stscript.autocomplete.style` | str | `"theme"` |
| `stscript.autocomplete.font.scale` | float | `0.8` |
| `stscript.autocomplete.width.left` | unknown | `—` |
| `stscript.autocomplete.width.right` | unknown | `—` |
| `stscript.autocomplete.select` | str | `"unknownunknown"` |
| `stscript.autocomplete.showInAllMacroFields` | bool | `false` |
| `restore_user_input` | bool | `true` |
| `reduced_motion` | bool | `false` |
| `compact_input_area` | bool | `true` |
| `show_swipe_num_all_messages` | bool | `false` |
| `auto_connect` | bool | `false` |
| `auto_load_chat` | bool | `false` |
| `forbid_external_media` | bool | `true` |
| `external_media_allowed_overrides` | array | `[]` |
| `external_media_forbidden_overrides` | array | `[]` |
| `pin_styles` | bool | `true` |
| `click_to_edit` | bool | `false` |
| `media_display` | str | `"list"` |
| `image_overswipe` | str | `"generate"` |

### `oai_settings` — 106 leaf fields

Source: `public/scripts/openai.js`

| Setting | Type | Upstream default |
|---|---|---|
| `preset_settings_openai` | str | `"Default"` |
| `temp_openai` | int | `1` |
| `freq_pen_openai` | int | `0` |
| `pres_pen_openai` | int | `0` |
| `top_p_openai` | int | `1` |
| `top_k_openai` | int | `0` |
| `min_p_openai` | int | `0` |
| `top_a_openai` | int | `0` |
| `repetition_penalty_openai` | int | `1` |
| `stream_openai` | bool | `false` |
| `openai_max_context` | int | `4095` |
| `openai_max_tokens` | int | `300` |
| `prompts` | array | `[—, —, —, —, —, —, —, —, —, —, —, —]` |
| `prompt_order` | array | `[]` |
| `send_if_empty` | str | `""` |
| `impersonation_prompt` | unknown | `—` |
| `new_chat_prompt` | unknown | `—` |
| `new_group_chat_prompt` | unknown | `—` |
| `new_example_chat_prompt` | unknown | `—` |
| `continue_nudge_prompt` | unknown | `—` |
| `bias_preset_selected` | unknown | `—` |
| `bias_presets.unknown` | array | `[]` |
| `bias_presets.Anti-bond` | array | `[—, —, —, —]` |
| `wi_format` | unknown | `—` |
| `group_nudge_prompt` | unknown | `—` |
| `scenario_format` | unknown | `—` |
| `personality_format` | unknown | `—` |
| `sort_models` | str | `"alphabetically"` |
| `group_models` | bool | `false` |
| `openai_model` | str | `"gpt-5.6-terra"` |
| `claude_model` | str | `"claude-sonnet-5"` |
| `google_model` | str | `"gemini-3.7-flash"` |
| `vertexai_model` | str | `"gemini-3.7-flash"` |
| `ai21_model` | str | `"jamba-large"` |
| `mistralai_model` | str | `"mistral-large-latest"` |
| `cohere_model` | str | `"command-r-plus"` |
| `perplexity_model` | str | `"sonar-pro"` |
| `groq_model` | str | `"llama-3.3-70b-versatile"` |
| `chutes_model` | str | `"deepseek-ai/DeepSeek-V3-0324"` |
| `siliconflow_model` | str | `"deepseek-ai/DeepSeek-V3"` |
| `siliconflow_endpoint` | str | `"global"` |
| `minimax_model` | str | `"MiniMax-M2.7"` |
| `minimax_endpoint` | str | `"global"` |
| `electronhub_model` | str | `"gpt-4o-mini"` |
| `nanogpt_model` | str | `"gpt-4o-mini"` |
| `nanogpt_provider` | str | `""` |
| `nanogpt_payg_override` | bool | `false` |
| `deepseek_model` | str | `"deepseek-v4-flash"` |
| `aimlapi_model` | str | `"chatgpt-4o-latest"` |
| `xai_model` | str | `"grok-3-beta"` |
| `pollinations_model` | str | `"openai"` |
| `pollinations_endpoint` | str | `"authenticated"` |
| `cometapi_model` | str | `"gpt-4o"` |
| `moonshot_model` | str | `"kimi-latest"` |
| `fireworks_model` | str | `"accounts/fireworks/models/kimi-k2-instruct"` |
| `zai_model` | str | `"glm-4.6"` |
| `zai_endpoint` | str | `"common"` |
| `workers_ai_model` | str | `"@cf/meta/llama-3.3-70b-instruct-fp8-fast"` |
| `workers_ai_account_id` | str | `""` |
| `azure_base_url` | str | `""` |
| `azure_deployment_name` | str | `""` |
| `azure_api_version` | str | `"2024-02-15-preview"` |
| `azure_openai_model` | str | `""` |
| `custom_model` | str | `""` |
| `custom_url` | str | `""` |
| `custom_include_body` | str | `""` |
| `custom_exclude_body` | str | `""` |
| `custom_include_headers` | str | `""` |
| `openrouter_model` | unknown | `—` |
| `openrouter_use_fallback` | bool | `false` |
| `openrouter_providers` | array | `[]` |
| `openrouter_quantizations` | array | `[]` |
| `openrouter_allow_fallbacks` | bool | `true` |
| `openrouter_middleout` | str | `"on"` |
| `tool_reasoning_mode` | str | `"disabled"` |
| `reverse_proxy` | str | `""` |
| `chat_completion_source` | str | `"openai"` |
| `max_context_unlocked` | bool | `false` |
| `show_external_models` | bool | `false` |
| `proxy_password` | str | `""` |
| `assistant_prefill` | str | `""` |
| `assistant_impersonation` | str | `""` |
| `use_sysprompt` | bool | `false` |
| `vertexai_auth_mode` | str | `"express"` |
| `vertexai_region` | str | `"us-central1"` |
| `vertexai_express_project_id` | str | `""` |
| `squash_system_messages` | bool | `false` |
| `media_inlining` | bool | `true` |
| `inline_image_quality` | str | `"auto"` |
| `bypass_status_check` | bool | `false` |
| `continue_prefill` | bool | `false` |
| `function_calling` | bool | `false` |
| `tool_call_recurse_limit` | int | `5` |
| `names_behavior` | int | `0` |
| `continue_postfix` | str | `" "` |
| `custom_prompt_post_processing` | str | `""` |
| `show_thoughts` | bool | `true` |
| `reasoning_effort` | str | `"auto"` |
| `verbosity` | str | `"auto"` |
| `enable_web_search` | bool | `false` |
| `request_images` | bool | `false` |
| `request_image_aspect_ratio` | str | `""` |
| `request_image_resolution` | str | `""` |
| `seed` | int | `-1` |
| `n` | int | `1` |
| `bind_preset_to_connection` | bool | `true` |

### `kai_settings` — 20 leaf fields

Source: `public/scripts/kai-settings.js`

| Setting | Type | Upstream default |
|---|---|---|
| `temp` | int | `1` |
| `rep_pen` | int | `1` |
| `rep_pen_range` | int | `0` |
| `top_p` | int | `1` |
| `min_p` | int | `0` |
| `top_a` | int | `1` |
| `top_k` | int | `0` |
| `typical` | int | `1` |
| `tfs` | int | `1` |
| `rep_pen_slope` | float | `0.9` |
| `streaming_kobold` | bool | `false` |
| `sampler_order` | array | `[—, —, —, —, —, —, —]` |
| `mirostat` | int | `0` |
| `mirostat_tau` | int | `5` |
| `mirostat_eta` | float | `0.1` |
| `use_default_badwordsids` | bool | `false` |
| `grammar` | str | `""` |
| `seed` | int | `-1` |
| `api_server` | str | `""` |
| `preset_settings` | str | `"gui"` |

### `nai_settings` — 24 leaf fields

Source: `public/scripts/nai-settings.js`

| Setting | Type | Upstream default |
|---|---|---|
| `temperature` | float | `1.5` |
| `repetition_penalty` | float | `2.25` |
| `repetition_penalty_range` | int | `2048` |
| `repetition_penalty_slope` | float | `0.09` |
| `repetition_penalty_frequency` | int | `0` |
| `repetition_penalty_presence` | float | `0.005` |
| `tail_free_sampling` | float | `0.975` |
| `top_k` | int | `10` |
| `top_p` | float | `0.75` |
| `top_a` | float | `0.08` |
| `typical_p` | float | `0.975` |
| `min_p` | int | `0` |
| `math1_temp` | int | `1` |
| `math1_quad` | int | `0` |
| `math1_quad_entropy_scale` | int | `0` |
| `min_length` | int | `1` |
| `model_novel` | str | `"clio-v1"` |
| `preset_settings_novel` | str | `"Talker-Chat-Clio"` |
| `streaming_novel` | bool | `false` |
| `preamble` | unknown | `—` |
| `prefix` | str | `""` |
| `banned_tokens` | str | `""` |
| `order` | array | `[—, —, —, —, —, —]` |
| `logit_bias` | array | `[]` |

### `horde_settings` — 4 leaf fields

Source: `public/scripts/horde.js`

| Setting | Type | Upstream default |
|---|---|---|
| `models` | array | `[]` |
| `auto_adjust_response_length` | bool | `true` |
| `auto_adjust_context_length` | bool | `false` |
| `trusted_workers_only` | bool | `false` |

### `world_info_settings` — 13 leaf fields

Source: `public/scripts/world-info.js`

| Setting | Type | Upstream default |
|---|---|---|
| `world_info_depth` | int | `2` |
| `world_info_min_activations` | int | `0` |
| `world_info_min_activations_depth_max` | int | `0` |
| `world_info_budget` | int | `25` |
| `world_info_include_names` | bool | `true` |
| `world_info_recursive` | bool | `false` |
| `world_info_overflow_alert` | bool | `false` |
| `world_info_case_sensitive` | bool | `false` |
| `world_info_match_whole_words` | bool | `false` |
| `world_info_character_strategy` | int | `1` |
| `world_info_budget_cap` | int | `0` |
| `world_info_use_group_scoring` | bool | `false` |
| `world_info_max_recursion_steps` | int | `0` |

### `textgenerationwebui_settings` — 61 leaf fields

Source: `default/content/presets/textgen/*.json`

| Setting | Type | Upstream default |
|---|---|---|
| `temp` | int | `1` |
| `temperature_last` | bool | `true` |
| `top_p` | float | `0.95` |
| `top_k` | int | `0` |
| `top_a` | int | `0` |
| `tfs` | int | `1` |
| `epsilon_cutoff` | int | `0` |
| `eta_cutoff` | int | `0` |
| `typical_p` | int | `1` |
| `min_p` | float | `0.01` |
| `rep_pen` | float | `1.1` |
| `rep_pen_range` | int | `0` |
| `rep_pen_decay` | int | `0` |
| `rep_pen_slope` | int | `1` |
| `no_repeat_ngram_size` | int | `0` |
| `penalty_alpha` | int | `0` |
| `num_beams` | int | `1` |
| `length_penalty` | int | `1` |
| `min_length` | int | `0` |
| `encoder_rep_pen` | int | `1` |
| `freq_pen` | int | `0` |
| `presence_pen` | int | `0` |
| `skew` | int | `0` |
| `do_sample` | bool | `true` |
| `early_stopping` | bool | `false` |
| `dynatemp` | bool | `false` |
| `min_temp` | int | `0` |
| `max_temp` | int | `2` |
| `dynatemp_exponent` | int | `1` |
| `smoothing_factor` | int | `0` |
| `smoothing_curve` | int | `1` |
| `dry_allowed_length` | int | `2` |
| `dry_multiplier` | int | `0` |
| `dry_base` | float | `1.75` |
| `dry_sequence_breakers` | str | `"[\"\n\", \":\", \"\\"\", \"*\"]"` |
| `dry_penalty_last_n` | int | `0` |
| `add_bos_token` | bool | `true` |
| `ban_eos_token` | bool | `false` |
| `skip_special_tokens` | bool | `true` |
| `mirostat_mode` | int | `0` |
| `mirostat_tau` | int | `5` |
| `mirostat_eta` | float | `0.1` |
| `guidance_scale` | int | `1` |
| `negative_prompt` | str | `""` |
| `grammar_string` | str | `""` |
| `json_schema` | null | `null` |
| `json_schema_allow_empty` | bool | `false` |
| `banned_tokens` | str | `""` |
| `sampler_priority` | array | `[—, —, —, —, —, —, —, —, —, —, —, —, —, —, —, —, —, —, —, —]` |
| `samplers` | array | `[—, —, —, —, —, —, —, —, —, —, —]` |
| `samplers_priorities` | array | `[—, —, —, —, —, —, —, —, —, —, —, —, —, —]` |
| `ignore_eos_token` | bool | `false` |
| `spaces_between_special_tokens` | bool | `true` |
| `speculative_ngram` | bool | `false` |
| `sampler_order` | array | `[—, —, —, —, —, —, —]` |
| `logit_bias` | array | `[]` |
| `xtc_threshold` | float | `0.1` |
| `xtc_probability` | int | `0` |
| `nsigma` | int | `0` |
| `min_keep` | int | `0` |
| `rep_pen_size` | int | `0` |