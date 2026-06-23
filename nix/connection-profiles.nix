{ lib, pkgs }:

let
  inherit (lib) types;
in
rec {

  mkProfileId = name: builtins.hashString "sha256" name;

  connectionProfileSubmodule = { ... }: {
    options = {
      default = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether to make this the active profile on startup.";
      };

      displayName = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "My OpenAI config";
        description = "Display name. Defaults to the attribute name if unset.";
      };

      mode = lib.mkOption {
        type = types.enum [ "cc" "tc" ];
        description = "Chat Completion (cc) or Text Completion (tc) mode.";
      };

      api = lib.mkOption {
        type = types.str;
        default = "";
        example = "openai";
        description = "API identifier (openai, kobold, koboldcpp, openrouter, etc.).";
      };

      model = lib.mkOption {
        type = types.str;
        default = "";
        example = "gpt-4";
        description = "Model name.";
      };

      preset = lib.mkOption {
        type = types.str;
        default = "";
        example = "Default";
        description = "Settings preset name.";
      };

      apiUrl = lib.mkOption {
        type = types.str;
        default = "";
        example = "https://api.openai.com/v1";
        description = "Server API URL.";
      };

      secretId = lib.mkOption {
        type = types.str;
        default = "";
        description = "Secret ID for API key (references the secret manager).";
      };

      stopStrings = lib.mkOption {
        type = types.str;
        default = "";
        example = "\\n\\n";
        description = "Custom stopping strings.";
      };

      startReplyWith = lib.mkOption {
        type = types.str;
        default = "";
        description = "Start reply with prefix.";
      };

      reasoningTemplate = lib.mkOption {
        type = types.str;
        default = "";
        description = "Reasoning template name.";
      };

      regexPreset = lib.mkOption {
        type = types.str;
        default = "";
        description = "Regex preset ID.";
      };

      exclude = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "api" "model" ];
        description = "Slash commands to exclude from this profile.";
      };

      proxy = lib.mkOption {
        type = types.str;
        default = "";
        description = "Proxy preset name (CC mode only).";
      };

      promptPostProcessing = lib.mkOption {
        type = types.str;
        default = "";
        example = "instruct";
        description = "Prompt post-processing mode (CC mode only).";
      };

      instruct = lib.mkOption {
        type = types.str;
        default = "";
        example = "ChatML";
        description = "Instruct template name (TC mode only).";
      };

      context = lib.mkOption {
        type = types.str;
        default = "";
        example = "Default";
        description = "Context template name (TC mode only).";
      };

      instructState = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Enable instruct mode (TC mode only).";
      };

      tokenizer = lib.mkOption {
        type = types.str;
        default = "";
        example = "Llama 3";
        description = "Tokenizer name (TC mode only).";
      };

      sysprompt = lib.mkOption {
        type = types.str;
        default = "";
        example = "Neutral - Chat";
        description = "System prompt name (TC mode only).";
      };

      syspromptState = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Use system prompt (TC mode only).";
      };
    };
  };

  profileToJson = name: profile:
    let
      id = mkProfileId name;
    in
    {
      inherit id;
      name = if profile.displayName != null then profile.displayName else name;
      mode = profile.mode;
    }
    // lib.optionalAttrs (profile.api != "") { api = profile.api; }
    // lib.optionalAttrs (profile.model != "") { model = profile.model; }
    // lib.optionalAttrs (profile.preset != "") { preset = profile.preset; }
    // lib.optionalAttrs (profile.apiUrl != "") { "api-url" = profile.apiUrl; }
    // lib.optionalAttrs (profile.secretId != "") { "secret-id" = profile.secretId; }
    // lib.optionalAttrs (profile.stopStrings != "") { "stop-strings" = profile.stopStrings; }
    // lib.optionalAttrs (profile.startReplyWith != "") { "start-reply-with" = profile.startReplyWith; }
    // lib.optionalAttrs (profile.reasoningTemplate != "") { "reasoning-template" = profile.reasoningTemplate; }
    // lib.optionalAttrs (profile.regexPreset != "") { "regex-preset" = profile.regexPreset; }
    // lib.optionalAttrs (profile.exclude != [ ]) { exclude = profile.exclude; }
    // lib.optionalAttrs (profile.proxy != "") { proxy = profile.proxy; }
    // lib.optionalAttrs (profile.promptPostProcessing != "") { "prompt-post-processing" = profile.promptPostProcessing; }
    // lib.optionalAttrs (profile.instruct != "") { instruct = profile.instruct; }
    // lib.optionalAttrs (profile.context != "") { context = profile.context; }
    // lib.optionalAttrs profile.instructState { "instruct-state" = "true"; }
    // lib.optionalAttrs (profile.tokenizer != "") { tokenizer = profile.tokenizer; }
    // lib.optionalAttrs (profile.sysprompt != "") { sysprompt = profile.sysprompt; }
    // lib.optionalAttrs profile.syspromptState { "sysprompt-state" = "true"; };

  mkProfilesArray = profiles:
    lib.mapAttrsToList profileToJson profiles;

  mkProfilesJson = profiles:
    builtins.toJSON (mkProfilesArray profiles);
}
