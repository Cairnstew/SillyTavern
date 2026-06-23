{ lib, pkgs }:

let
  inherit (lib) types;
in
rec {

  # Submodule options for a single text completion preset
  presetSubmodule = { config, ... }: {
    options = {
      default = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether to make this the default preset loaded on startup.";
      };

      # Generation params (read by setGenerationParamsFromPreset)
      genamt = lib.mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        example = 512;
        description = "Response length (amount to generate). Null = use existing UI value.";
      };
      max_length = lib.mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        example = 4096;
        description = "Context length (max context). Null = use existing UI value.";
      };

      # --- Core sampling ---
      temp = lib.mkOption { type = types.float; default = 1.0; };
      temperature_last = lib.mkOption { type = types.bool; default = true; };
      top_p = lib.mkOption { type = types.float; default = 0.95; };
      top_k = lib.mkOption { type = types.ints.unsigned; default = 0; };
      top_a = lib.mkOption { type = types.float; default = 0; };
      tfs = lib.mkOption { type = types.float; default = 1; };
      epsilon_cutoff = lib.mkOption { type = types.float; default = 0; };
      eta_cutoff = lib.mkOption { type = types.float; default = 0; };
      typical_p = lib.mkOption { type = types.float; default = 1; };
      min_p = lib.mkOption { type = types.float; default = 0.01; };
      rep_pen = lib.mkOption { type = types.float; default = 1.1; };
      rep_pen_range = lib.mkOption { type = types.ints.unsigned; default = 0; };
      rep_pen_decay = lib.mkOption { type = types.ints.unsigned; default = 0; };
      rep_pen_slope = lib.mkOption { type = types.float; default = 1; };
      no_repeat_ngram_size = lib.mkOption { type = types.ints.unsigned; default = 0; };
      penalty_alpha = lib.mkOption { type = types.float; default = 0; };
      num_beams = lib.mkOption { type = types.ints.unsigned; default = 1; };
      length_penalty = lib.mkOption { type = types.float; default = 1; };
      min_length = lib.mkOption { type = types.ints.unsigned; default = 0; };
      encoder_rep_pen = lib.mkOption { type = types.float; default = 1; };
      freq_pen = lib.mkOption { type = types.float; default = 0; };
      presence_pen = lib.mkOption { type = types.float; default = 0; };
      skew = lib.mkOption { type = types.float; default = 0; };
      do_sample = lib.mkOption { type = types.bool; default = true; };
      early_stopping = lib.mkOption { type = types.bool; default = false; };
      seed = lib.mkOption { type = types.int; default = -1; };
      max_tokens_second = lib.mkOption { type = types.ints.unsigned; default = 0; };

      # --- Dynamic temperature ---
      dynatemp = lib.mkOption { type = types.bool; default = false; };
      min_temp = lib.mkOption { type = types.float; default = 0; };
      max_temp = lib.mkOption { type = types.float; default = 2; };
      dynatemp_exponent = lib.mkOption { type = types.float; default = 1; };

      # --- Smoothing ---
      smoothing_factor = lib.mkOption { type = types.float; default = 0; };
      smoothing_curve = lib.mkOption { type = types.float; default = 1; };

      # --- DRY penalty ---
      dry_allowed_length = lib.mkOption { type = types.ints.unsigned; default = 2; };
      dry_multiplier = lib.mkOption { type = types.float; default = 0; };
      dry_base = lib.mkOption { type = types.float; default = 1.75; };
      dry_sequence_breakers = lib.mkOption { type = types.str; default = ''["\n", ":", "\"", "*"]''; };
      dry_penalty_last_n = lib.mkOption { type = types.ints.unsigned; default = 0; };

      # --- BOS/EOS / special tokens ---
      add_bos_token = lib.mkOption { type = types.bool; default = true; };
      ban_eos_token = lib.mkOption { type = types.bool; default = false; };
      skip_special_tokens = lib.mkOption { type = types.bool; default = true; };
      ignore_eos_token = lib.mkOption { type = types.bool; default = false; };
      spaces_between_special_tokens = lib.mkOption { type = types.bool; default = true; };

      # --- Mirostat ---
      mirostat_mode = lib.mkOption { type = types.ints.unsigned; default = 0; };
      mirostat_tau = lib.mkOption { type = types.float; default = 5; };
      mirostat_eta = lib.mkOption { type = types.float; default = 0.1; };

      # --- CFG ---
      guidance_scale = lib.mkOption { type = types.float; default = 1; };
      negative_prompt = lib.mkOption { type = types.str; default = ""; };

      # --- Grammar / JSON schema ---
      grammar_string = lib.mkOption { type = types.str; default = ""; };
      json_schema = lib.mkOption { type = types.nullOr types.str; default = null; };
      json_schema_allow_empty = lib.mkOption { type = types.bool; default = false; };

      # --- Token bans ---
      banned_tokens = lib.mkOption { type = types.str; default = ""; };
      global_banned_tokens = lib.mkOption { type = types.str; default = ""; };
      send_banned_tokens = lib.mkOption { type = types.bool; default = false; };

      # --- Sampler ordering (backend-specific) ---
      sampler_priority = lib.mkOption {
        type = types.listOf types.str;
        default = [
          "repetition_penalty" "presence_penalty" "frequency_penalty"
          "dry" "temperature" "dynamic_temperature" "quadratic_sampling"
          "top_n_sigma" "top_k" "top_p" "typical_p" "epsilon_cutoff"
          "eta_cutoff" "tfs" "top_a" "min_p" "mirostat" "xtc"
          "encoder_repetition_penalty" "no_repeat_ngram"
        ];
      };
      samplers = lib.mkOption {
        type = types.listOf types.str;
        default = [
          "penalties" "dry" "top_n_sigma" "top_k" "typ_p"
          "tfs_z" "typical_p" "xtc" "top_p" "min_p" "temperature"
        ];
      };
      samplers_priorities = lib.mkOption {
        type = types.listOf types.str;
        default = [
          "dry" "penalties" "no_repeat_ngram" "temperature"
          "top_nsigma" "top_p_top_k" "top_a" "min_p" "tfs"
          "eta_cutoff" "epsilon_cutoff" "typical_p" "quadratic" "xtc"
        ];
      };
      sampler_order = lib.mkOption {
        type = types.listOf types.ints.unsigned;
        default = [ 6 0 1 3 4 2 5 ];
      };

      # --- XTC sampler ---
      xtc_threshold = lib.mkOption { type = types.float; default = 0.1; };
      xtc_probability = lib.mkOption { type = types.float; default = 0; };

      # --- Other ---
      nsigma = lib.mkOption { type = types.ints.unsigned; default = 0; };
      min_keep = lib.mkOption { type = types.ints.unsigned; default = 0; };
      rep_pen_size = lib.mkOption { type = types.ints.unsigned; default = 0; };
      logit_bias = lib.mkOption { type = types.listOf types.attrs; default = [ ]; };
      speculative_ngram = lib.mkOption { type = types.bool; default = false; };
      include_reasoning = lib.mkOption { type = types.bool; default = false; };
      streaming = lib.mkOption { type = types.bool; default = false; };
      n = lib.mkOption { type = types.ints.unsigned; default = 1; };
      custom_model = lib.mkOption { type = types.str; default = ""; };
      bypass_status_check = lib.mkOption { type = types.bool; default = false; };
      openrouter_allow_fallbacks = lib.mkOption { type = types.bool; default = false; };
      generic_model = lib.mkOption { type = types.str; default = ""; };
      adaptive_target = lib.mkOption { type = types.float; default = 0; };
      adaptive_decay = lib.mkOption { type = types.float; default = 0; };
      extensions = lib.mkOption {
        type = types.attrs;
        default = { };
        description = "Extension-specific arbitrary data (map of extension name to data).";
      };

      # --- Extra ---
      extraSettings = lib.mkOption {
        type = types.attrs;
        default = { };
        description = "Extra fields merged into the preset JSON. Takes precedence over typed options.";
      };
    };
  };
}
