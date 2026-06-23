{ lib, pkgs }:

let
  inherit (lib) types;
in
rec {

  # ---- Context Template ----

  contextSubmodule = { ... }: {
    options = {
      default = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Make this the active context template on startup.";
      };

      story_string = lib.mkOption {
        type = types.str;
        default = "";
        description = "Handlebars template for context assembly.";
      };

      example_separator = lib.mkOption {
        type = types.str;
        default = "";
        description = "Separator for example messages.";
      };

      chat_start = lib.mkOption {
        type = types.str;
        default = "";
        description = "Chat start message.";
      };

      use_stop_strings = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Use context separators as stop strings.";
      };

      names_as_stop_strings = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Use character/user names as stop strings.";
      };

      story_string_position = lib.mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "0=IN_PROMPT (top), 1=IN_CHAT (in-chat at depth).";
      };

      story_string_depth = lib.mkOption {
        type = types.ints.unsigned;
        default = 1;
        description = "Depth for in-chat story string injection.";
      };

      story_string_role = lib.mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "0=System, 1=User, 2=Assistant.";
      };

      always_force_name2 = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Always prefix character name in responses.";
      };

      trim_sentences = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Trim incomplete sentences from generation.";
      };

      single_line = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Generate only one line per request.";
      };
    };
  };

  # ---- Instruct Template ----

  instructSubmodule = { ... }: {
    options = {
      default = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Make this the active instruct template on startup.";
      };

      input_sequence = lib.mkOption {
        type = types.str;
        default = "";
        example = "### Instruction:";
        description = "Prefix before user messages.";
      };

      input_suffix = lib.mkOption {
        type = types.str;
        default = "";
        description = "Suffix after user messages.";
      };

      output_sequence = lib.mkOption {
        type = types.str;
        default = "";
        example = "### Response:";
        description = "Prefix before assistant messages.";
      };

      output_suffix = lib.mkOption {
        type = types.str;
        default = "";
        description = "Suffix after assistant messages.";
      };

      system_sequence = lib.mkOption {
        type = types.str;
        default = "";
        example = "<|im_start|>system";
        description = "Prefix for system messages.";
      };

      system_suffix = lib.mkOption {
        type = types.str;
        default = "";
        description = "Suffix after system messages.";
      };

      last_system_sequence = lib.mkOption {
        type = types.str;
        default = "";
        description = "Prefix for last system/neutral role generation.";
      };

      first_input_sequence = lib.mkOption {
        type = types.str;
        default = "";
        description = "Prefix before the first user message.";
      };

      first_output_sequence = lib.mkOption {
        type = types.str;
        default = "";
        description = "Prefix before the first assistant message.";
      };

      last_input_sequence = lib.mkOption {
        type = types.str;
        default = "";
        description = "Prefix before the last user message (impersonation).";
      };

      last_output_sequence = lib.mkOption {
        type = types.str;
        default = "";
        description = "Prefix before the last assistant message.";
      };

      story_string_prefix = lib.mkOption {
        type = types.str;
        default = "";
        description = "Prefix before story string (default position only).";
      };

      story_string_suffix = lib.mkOption {
        type = types.str;
        default = "";
        description = "Suffix after story string.";
      };

      stop_sequence = lib.mkOption {
        type = types.str;
        default = "";
        example = "<|im_end|>";
        description = "Sequence that terminates generation.";
      };

      wrap = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Wrap sequences with newlines.";
      };

      macro = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Replace macros in sequences.";
      };

      names_behavior = lib.mkOption {
        type = types.enum [ "none" "force" "always" ];
        default = "none";
        description = "How to handle character names in chat.";
      };

      activation_regex = lib.mkOption {
        type = types.str;
        default = "";
        description = "Regex pattern to auto-activate this template on model match.";
      };

      bind_to_context = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Auto-select context template matching this instruct name.";
      };

      user_alignment_message = lib.mkOption {
        type = types.str;
        default = "";
        description = "Filler message when chat doesn't start with a user message.";
      };

      system_same_as_user = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Use same sequences for system messages as user messages.";
      };

      skip_examples = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Skip example dialogue in formatting.";
      };

      sequences_as_stop_strings = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Use instruct sequences as stop strings.";
      };
    };
  };

  # ---- System Prompt ----

  syspromptSubmodule = { ... }: {
    options = {
      default = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Make this the active system prompt on startup.";
      };

      content = lib.mkOption {
        type = types.str;
        default = "";
        example = "You're {{char}} in this roleplay with {{user}}.";
        description = "System prompt text with macros.";
      };

      post_history = lib.mkOption {
        type = types.str;
        default = "";
        description = "Post-history instructions appended after the chat history.";
      };
    };
  };

  # ---- Reasoning Template ----

  reasoningSubmodule = { ... }: {
    options = {
      default = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Make this the active reasoning template on startup.";
      };

      prefix = lib.mkOption {
        type = types.str;
        default = "";
        example = "<think>\n";
        description = "Opening tag for reasoning block.";
      };

      suffix = lib.mkOption {
        type = types.str;
        default = "";
        example = "\n</think>";
        description = "Closing tag for reasoning block.";
      };

      separator = lib.mkOption {
        type = types.str;
        default = "";
        example = "\n\n";
        description = "Separator between reasoning and response.";
      };
    };
  };

  # ---- JSON generation helpers ----

  contextToJson = name: preset:
    { name = name; }
    // lib.optionalAttrs (preset.story_string != "") { story_string = preset.story_string; }
    // lib.optionalAttrs (preset.example_separator != "") { example_separator = preset.example_separator; }
    // lib.optionalAttrs (preset.chat_start != "") { chat_start = preset.chat_start; }
    // lib.optionalAttrs (preset.use_stop_strings != false) { use_stop_strings = preset.use_stop_strings; }
    // lib.optionalAttrs (preset.names_as_stop_strings != false) { names_as_stop_strings = preset.names_as_stop_strings; }
    // lib.optionalAttrs (preset.story_string_position != 0) { story_string_position = preset.story_string_position; }
    // lib.optionalAttrs (preset.story_string_depth != 1) { story_string_depth = preset.story_string_depth; }
    // lib.optionalAttrs (preset.story_string_role != 0) { story_string_role = preset.story_string_role; }
    // lib.optionalAttrs (preset.always_force_name2 != false) { always_force_name2 = preset.always_force_name2; }
    // lib.optionalAttrs (preset.trim_sentences != false) { trim_sentences = preset.trim_sentences; }
    // lib.optionalAttrs (preset.single_line != false) { single_line = preset.single_line; };

  instructToJson = name: preset:
    { name = name; }
    // lib.optionalAttrs (preset.input_sequence != "") { input_sequence = preset.input_sequence; }
    // lib.optionalAttrs (preset.input_suffix != "") { input_suffix = preset.input_suffix; }
    // lib.optionalAttrs (preset.output_sequence != "") { output_sequence = preset.output_sequence; }
    // lib.optionalAttrs (preset.output_suffix != "") { output_suffix = preset.output_suffix; }
    // lib.optionalAttrs (preset.system_sequence != "") { system_sequence = preset.system_sequence; }
    // lib.optionalAttrs (preset.system_suffix != "") { system_suffix = preset.system_suffix; }
    // lib.optionalAttrs (preset.last_system_sequence != "") { last_system_sequence = preset.last_system_sequence; }
    // lib.optionalAttrs (preset.first_input_sequence != "") { first_input_sequence = preset.first_input_sequence; }
    // lib.optionalAttrs (preset.first_output_sequence != "") { first_output_sequence = preset.first_output_sequence; }
    // lib.optionalAttrs (preset.last_input_sequence != "") { last_input_sequence = preset.last_input_sequence; }
    // lib.optionalAttrs (preset.last_output_sequence != "") { last_output_sequence = preset.last_output_sequence; }
    // lib.optionalAttrs (preset.story_string_prefix != "") { story_string_prefix = preset.story_string_prefix; }
    // lib.optionalAttrs (preset.story_string_suffix != "") { story_string_suffix = preset.story_string_suffix; }
    // lib.optionalAttrs (preset.stop_sequence != "") { stop_sequence = preset.stop_sequence; }
    // lib.optionalAttrs (preset.wrap != true) { wrap = preset.wrap; }
    // lib.optionalAttrs (preset.macro != true) { macro = preset.macro; }
    // lib.optionalAttrs (preset.names_behavior != "none") { names_behavior = preset.names_behavior; }
    // lib.optionalAttrs (preset.activation_regex != "") { activation_regex = preset.activation_regex; }
    // lib.optionalAttrs (preset.bind_to_context != false) { bind_to_context = preset.bind_to_context; }
    // lib.optionalAttrs (preset.user_alignment_message != "") { user_alignment_message = preset.user_alignment_message; }
    // lib.optionalAttrs (preset.system_same_as_user != false) { system_same_as_user = preset.system_same_as_user; }
    // lib.optionalAttrs (preset.skip_examples != false) { skip_examples = preset.skip_examples; }
    // lib.optionalAttrs (preset.sequences_as_stop_strings != false) { sequences_as_stop_strings = preset.sequences_as_stop_strings; };

  syspromptToJson = name: preset:
    { name = name; }
    // lib.optionalAttrs (preset.content != "") { content = preset.content; }
    // lib.optionalAttrs (preset.post_history != "") { post_history = preset.post_history; };

  reasoningToJson = name: preset:
    { name = name; }
    // lib.optionalAttrs (preset.prefix != "") { prefix = preset.prefix; }
    // lib.optionalAttrs (preset.suffix != "") { suffix = preset.suffix; }
    // lib.optionalAttrs (preset.separator != "") { separator = preset.separator; };

  # ---- Preset file generator ----

  mkPresetFiles =
    { context ? { }, instruct ? { }, sysprompt ? { }, reasoning ? { } }:
    let
      mkType = typeName: toJsonFn: presets:
        lib.optionalAttrs (presets != { }) {
          "${typeName}" = pkgs.runCommand "sillytavern-${typeName}-presets" { } (lib.concatStringsSep "\n" (lib.mapAttrsToList (name: preset: ''
            mkdir -p $out
            cat > "$out/${name}.json" << 'JSONEOF'
            ${builtins.toJSON (toJsonFn name (removeAttrs preset [ "default" ]))}
            JSONEOF
          '') presets));
        };
    in
    { }
    // mkType "context" contextToJson context
    // mkType "instruct" instructToJson instruct
    // mkType "sysprompt" syspromptToJson sysprompt
    // mkType "reasoning" reasoningToJson reasoning;

  # ---- Combined setup script generator ----

  mkAdvancedFormattingSetupScript =
    { dataDir, user, group, defaultNames, presetDirs }:
    let
      defaultContext = defaultNames.context or null;
      defaultInstruct = defaultNames.instruct or null;
      defaultSysprompt = defaultNames.sysprompt or null;
      defaultReasoning = defaultNames.reasoning or null;
      ctxDir = presetDirs.context or null;
      insDir = presetDirs.instruct or null;
      sysDir = presetDirs.sysprompt or null;
      reaDir = presetDirs.reasoning or null;
    in
    pkgs.writeShellScript "sillytavern-setup-advanced-formatting" ''
      set -e
      DATA_DIR="${dataDir}"

      copy_presets() {
        local src_dir="$1"
        local target_subdir="$2"
        [ -d "$src_dir" ] || return 0
        for userdir in "$DATA_DIR"/*/; do
          [ -d "$userdir" ] || continue
          target_dir="$userdir/$target_subdir"
          mkdir -p "$target_dir"
          for preset_file in "$src_dir"/*.json; do
            [ -f "$preset_file" ] || continue
            cp "$preset_file" "$target_dir/$(basename "$preset_file")"
          done
          chown -R "${user}:${group}" "$target_dir" 2>/dev/null || true
        done
      }

      set_default() {
        local settings_file="$1"
        local jq_filter="$2"
        [ -f "$settings_file" ] || return 0
        ${pkgs.jq}/bin/jq "$jq_filter" "$settings_file" > "$settings_file.tmp" && \
        mv "$settings_file.tmp" "$settings_file" && \
        chown "${user}:${group}" "$settings_file" 2>/dev/null || true
      }

      ${lib.optionalString (ctxDir != null) ''
        copy_presets "${ctxDir}" "context"
      ''}

      ${lib.optionalString (insDir != null) ''
        copy_presets "${insDir}" "instruct"
      ''}

      ${lib.optionalString (sysDir != null) ''
        copy_presets "${sysDir}" "sysprompt"
      ''}

      ${lib.optionalString (reaDir != null) ''
        copy_presets "${reaDir}" "reasoning"
      ''}

      for userdir in "$DATA_DIR"/*/; do
        settings_file="$userdir/settings.json"
        [ -f "$settings_file" ] || continue

        ${lib.optionalString (defaultContext != null) ''
          set_default "$settings_file" '.power_user.context.preset = "${defaultContext}"'
        ''}

        ${lib.optionalString (defaultInstruct != null) ''
          set_default "$settings_file" '.power_user.instruct.preset = "${defaultInstruct}"'
        ''}

        ${lib.optionalString (defaultSysprompt != null) ''
          set_default "$settings_file" '.power_user.sysprompt.name = "${defaultSysprompt}"'
        ''}

        ${lib.optionalString (defaultReasoning != null) ''
          set_default "$settings_file" '.power_user.reasoning.name = "${defaultReasoning}"'
        ''}
      done
    '';
}
