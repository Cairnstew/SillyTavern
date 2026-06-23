{ lib }:

let
  inherit (lib) types;
in
rec {

  userSettingsSubmodule = { ... }: {
    options = {
      # Meta: enable declarative management
      enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable declarative user settings. When enabled, power_user settings are overwritten on every service start.";
      };

      # --- Theme / Appearance ---
      theme = lib.mkOption {
        type = types.str;
        default = "Default (Dark) 1.7.1";
        description = "UI theme name.";
      };

      charListGrid = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Display character list as grid.";
      };

      noShadows = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Disable UI shadows.";
      };

      movingUI = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable movable UI panels.";
      };

      movingUIPreset = lib.mkOption {
        type = types.str;
        default = "";
        description = "Name of the moving UI layout preset.";
      };

      chat_display = lib.mkOption {
        type = types.ints.between 0 2;
        default = 0;
        description = "Chat display style: 0=Flat, 1=Bubbles, 2=Document.";
      };

      avatar_style = lib.mkOption {
        type = types.ints.between 0 3;
        default = 0;
        description = "Avatar style: 0=Circle, 1=Rectangle, 2=Square, 3=Rounded.";
      };

      chat_width = lib.mkOption {
        type = types.ints.between 1 100;
        default = 50;
        description = "Chat width as percentage of screen.";
      };

      font_scale = lib.mkOption {
        type = types.float;
        default = 1.0;
        description = "Font scale factor.";
      };

      blur_strength = lib.mkOption {
        type = types.ints.unsigned;
        default = 10;
        description = "Blur effect strength for UI backgrounds.";
      };

      shadow_width = lib.mkOption {
        type = types.ints.unsigned;
        default = 2;
        description = "Shadow width for UI elements.";
      };

      toastr_position = lib.mkOption {
        type = types.str;
        default = "toast-top-center";
        description = "Toast notification position.";
      };

      custom_css = lib.mkOption {
        type = types.str;
        default = "";
        description = "Custom CSS injected into the page.";
      };

      # --- UI Mode Toggles ---
      fast_ui_mode = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Enable fast UI mode (disables some animations).";
      };

      waifuMode = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable waifu/card-only display mode.";
      };

      gestures = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Enable touch gestures.";
      };

      enableZenSliders = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable zen sliders (numeric input only).";
      };

      enableLabMode = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable lab mode (advanced settings).";
      };

      hotswap_enabled = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Enable hotswap for character cards.";
      };

      reduced_motion = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable reduced motion.";
      };

      pin_styles = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Pin style panels open.";
      };

      click_to_edit = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Click message to edit.";
      };

      # --- Chat / Message Display ---
      play_message_sound = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Play sound on new messages.";
      };

      play_sound_unfocused = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Play sound only when tab is unfocused.";
      };

      timestamps_enabled = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Show timestamps on messages.";
      };

      timestamp_model_icon = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show model icon next to timestamps.";
      };

      timer_enabled = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Show response timer.";
      };

      mesIDDisplay_enabled = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show message IDs.";
      };

      hideChatAvatars_enabled = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Hide avatars in chat.";
      };

      message_token_count_enabled = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show token count per message.";
      };

      expand_message_actions = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Always expand message action buttons.";
      };

      show_swipe_num_all_messages = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show swipe counter on all messages.";
      };

      # --- Text / Input ---
      send_on_enter = lib.mkOption {
        type = types.ints.between (-1) 1;
        default = 0;
        description = "Send on Enter behavior: -1=Disabled, 0=Auto, 1=Enabled.";
      };

      auto_fix_generated_markdown = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Auto-fix markdown in AI responses.";
      };

      auto_scroll_chat_to_bottom = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Auto-scroll to bottom on new messages.";
      };

      encode_tags = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Escape HTML tags in responses.";
      };

      experimental_macro_engine = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Enable the experimental macro engine.";
      };

      collapse_newlines = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Collapse multiple newlines into one.";
      };

      trim_spaces = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Trim leading/trailing spaces from messages.";
      };

      compact_input_area = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Compact input area style.";
      };

      markdown_escape_strings = lib.mkOption {
        type = types.str;
        default = "";
        description = "Additional strings to escape in markdown.";
      };

      user_prompt_bias = lib.mkOption {
        type = types.str;
        default = "";
        description = "Bias string prepended to user prompts.";
      };

      show_user_prompt_bias = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Show user prompt bias in UI.";
      };

      auto_save_msg_edits = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Auto-save message edits.";
      };

      confirm_message_delete = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Show confirmation dialog before deleting messages.";
      };

      restore_user_input = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Restore user input after sending.";
      };

      console_log_prompts = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Log prompts to browser console.";
      };

      request_token_probabilities = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Request token probabilities from API.";
      };

      show_group_chat_queue = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show group chat queue.";
      };

      # --- Streaming ---
      streaming_fps = lib.mkOption {
        type = types.ints.unsigned;
        default = 30;
        description = "Streaming display FPS.";
      };

      smooth_streaming = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable smooth token streaming.";
      };

      smooth_streaming_speed = lib.mkOption {
        type = types.ints.between 1 100;
        default = 50;
        description = "Smooth streaming speed.";
      };

      stream_fade_in = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable fade-in effect for streamed tokens.";
      };

      chat_truncation = lib.mkOption {
        type = types.ints.unsigned;
        default = 100;
        description = "Chat truncation limit (number of messages).";
      };

      # --- Character List ---
      sort_field = lib.mkOption {
        type = types.str;
        default = "name";
        description = "Character list sort field.";
      };

      sort_order = lib.mkOption {
        type = types.str;
        default = "asc";
        description = "Character list sort order.";
      };

      bogus_folders = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show tags as folders in character list.";
      };

      show_tag_filters = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show tag filter bar.";
      };

      fuzzy_search = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable fuzzy search in character list.";
      };

      tag_import_setting = lib.mkOption {
        type = types.ints.between 1 4;
        default = 1;
        description = "Tag import behavior: 1=Ask, 2=None, 3=All, 4=Existing.";
      };

      tag_sort_mode = lib.mkOption {
        type = types.ints.between 0 1;
        default = 0;
        description = "Tag sort mode: 0=Manual, 1=Alphabetical.";
      };

      never_resize_avatars = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Never resize character avatars.";
      };

      show_card_avatar_urls = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Show card avatar URLs.";
      };

      allow_name1_display = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Allow display of user name in placeholders.";
      };

      allow_name2_display = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Allow display of character name in placeholders.";
      };

      prefer_character_prompt = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Prefer character-defined prompt override.";
      };

      prefer_character_jailbreak = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Prefer character-defined jailbreak.";
      };

      world_import_dialog = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Show world import dialog.";
      };

      forbid_external_media = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Block external media loading.";
      };

      disable_group_trimming = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Disable automatic group message trimming.";
      };

      # --- Auto-Continue ---
      auto_continue = lib.mkOption {
        type = types.submodule {
          options = {
            enabled = lib.mkOption {
              type = types.bool;
              default = false;
              description = "Enable auto-continue when response is cut off.";
            };
            allow_chat_completions = lib.mkOption {
              type = types.bool;
              default = false;
              description = "Allow auto-continue for chat completion APIs.";
            };
            target_length = lib.mkOption {
              type = types.ints.unsigned;
              default = 400;
              description = "Target response length for auto-continue.";
            };
          };
        };
        default = { };
        description = "Auto-continue configuration.";
      };

      # --- Auto-Swipe ---
      auto_swipe = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Auto-swipe until message meets minimum length.";
      };

      auto_swipe_minimum_length = lib.mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Minimum message length for auto-swipe.";
      };

      auto_swipe_blacklist = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Blacklisted strings that trigger auto-swipe.";
      };

      auto_swipe_blacklist_threshold = lib.mkOption {
        type = types.ints.unsigned;
        default = 2;
        description = "Number of blacklist matches to trigger swipe.";
      };

      # --- Persona ---
      persona_description_position = lib.mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Persona description injection position.";
      };

      persona_description_role = lib.mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Persona description role: 0=System, 1=User, 2=Assistant.";
      };

      persona_description_depth = lib.mkOption {
        type = types.ints.unsigned;
        default = 2;
        description = "Persona description injection depth.";
      };

      persona_show_notifications = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Show persona notifications.";
      };

      # --- Tokenizer ---
      tokenizer = lib.mkOption {
        type = types.ints.signed;
        default = 99;
        description = "Tokenizer: 99=BEST_MATCH, or a specific tokenizer ID.";
      };

      token_padding = lib.mkOption {
        type = types.ints.unsigned;
        default = 64;
        description = "Token padding for context limit.";
      };

      # --- Custom Stopping Strings ---
      custom_stopping_strings = lib.mkOption {
        type = types.str;
        default = "";
        description = "Custom stopping strings (JSON array).";
      };

      custom_stopping_strings_macro = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Enable macro replacement in stopping strings.";
      };

      # --- Misc ---
      relaxed_api_urls = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Relax API URL validation.";
      };

      enable_auto_select_input = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Auto-focus input on page load.";
      };

      enable_md_hotkeys = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable markdown editor hotkeys.";
      };

      quick_continue = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable quick continue (continue without editing).";
      };

      quick_impersonate = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable quick impersonation.";
      };

      continue_on_send = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Auto-continue when sending a message.";
      };

      spoiler_free_mode = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Remove spoiler formatting from responses.";
      };

      auto_connect = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Auto-connect to API on startup.";
      };

      auto_load_chat = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Auto-load last chat on startup.";
      };

      # --- Extra ---
      extraSettings = lib.mkOption {
        type = types.attrs;
        default = { };
        description = "Extra power_user fields not covered by the dedicated options.";
      };
    };
  };

  mkUserSettingsJson = settings:
    let
      stripped = removeAttrs settings [ "extraSettings" "auto_continue" "enable" ];

      autoContinue = if settings.auto_continue.enabled
        || settings.auto_continue.allow_chat_completions
        || settings.auto_continue.target_length != 400
      then {
        auto_continue = {
          enabled = settings.auto_continue.enabled;
          allow_chat_completions = settings.auto_continue.allow_chat_completions;
          target_length = settings.auto_continue.target_length;
        };
      } else { };

      base = lib.filterAttrs (_: v: v != null) stripped;
    in
    builtins.toJSON (base // autoContinue // settings.extraSettings);
}
