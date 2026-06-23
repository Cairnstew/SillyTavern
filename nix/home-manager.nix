{ lib, pkgs, config, ... }:

let
  cfg = config.services.sillytavern;
  configYaml = import ./config-yaml.nix { inherit lib pkgs; };
  presetsModule = import ./presets.nix { inherit lib pkgs; };

  mkPresetJson = preset:
    (lib.filterAttrs (n: v: v != null)
      (removeAttrs preset [ "default" "extraSettings" ]))
    // preset.extraSettings;

  defaultPresetName = lib.head (
    lib.filter (n: cfg.textCompletionPresets.${n}.default)
      (lib.attrNames cfg.textCompletionPresets)
  );

  presetFiles = pkgs.runCommand "sillytavern-textgen-presets" {
    nativeBuildInputs = [ pkgs.jq ];
  } (lib.concatStringsSep "\n" (lib.mapAttrsToList (name: preset: ''
    mkdir -p $out
    jq -n '${builtins.toJSON (mkPresetJson preset)}' > "$out/${name}.json"
  '') cfg.textCompletionPresets));

  setupPresetsScript = pkgs.writeShellScript "sillytavern-setup-presets" ''
    set -e
    PRESET_SRC="${presetFiles}"
    DATA_DIR="${cfg.dataDir}"

    if [ -d "$DATA_DIR" ]; then
      for userdir in "$DATA_DIR"/data/*/; do
        [ -d "$userdir" ] || continue
        preset_dir="$userdir/TextGen Settings"
        mkdir -p "$preset_dir"
        for preset_file in "$PRESET_SRC"/*.json; do
          [ -f "$preset_file" ] || continue
          cp "$preset_file" "$preset_dir/$(basename "$preset_file")"
        done
        ${lib.optionalString (defaultPresetName != null) ''
          settings_file="$userdir/settings.json"
          if [ -f "$settings_file" ]; then
            ${pkgs.jq}/bin/jq --arg preset "${defaultPresetName}" \
              '.textgenerationwebui_settings.preset = $preset' \
              "$settings_file" > "$settings_file.tmp" && \
            mv "$settings_file.tmp" "$settings_file"
          fi
        ''}
      done
    fi
  '';

  # ---- Connection profiles ----
  connectionProfilesModule = import ./connection-profiles.nix { inherit lib pkgs; };

  allProfilesArray = connectionProfilesModule.mkProfilesArray cfg.connectionProfiles;
  allProfilesJson = builtins.toJSON allProfilesArray;

  defaultProfileIds = lib.filter (
    id: cfg.connectionProfiles.${id}.default
  ) (lib.attrNames cfg.connectionProfiles);
  defaultProfileId = lib.head (defaultProfileIds ++ [ null ]);

  defaultProfileUuid = lib.optionalString (defaultProfileId != null)
    (connectionProfilesModule.mkProfileId defaultProfileId);

  setupConnectionProfilesScript = pkgs.writeShellScript "sillytavern-setup-connection-profiles" ''
    set -e
    PROFILES='${allProfilesJson}'
    DATA_DIR="${cfg.dataDir}"

    if [ -d "$DATA_DIR" ]; then
      for userdir in "$DATA_DIR"/data/*/; do
        settings_file="$userdir/settings.json"
        [ -f "$settings_file" ] || continue
        ${lib.optionalString (defaultProfileUuid != "") ''
          ${pkgs.jq}/bin/jq \
            --argjson profiles "$PROFILES" \
            --arg selected "${defaultProfileUuid}" \
            '.extension_settings.connectionManager.profiles = $profiles
             | .extension_settings.connectionManager.selectedProfile = $selected' \
            "$settings_file" > "$settings_file.tmp" && \
          mv "$settings_file.tmp" "$settings_file"
        ''}
        ${lib.optionalString (defaultProfileUuid == "" && allProfilesArray != []) ''
          ${pkgs.jq}/bin/jq \
            --argjson profiles "$PROFILES" \
            '.extension_settings.connectionManager.profiles = $profiles' \
            "$settings_file" > "$settings_file.tmp" && \
          mv "$settings_file.tmp" "$settings_file"
        ''}
      done
    fi
  '';

  # ---- Advanced Formatting ----
  advFmtModule = import ./advanced-formatting.nix { inherit lib pkgs; };

  advFmtPresetDirs = advFmtModule.mkPresetFiles {
    context = cfg.advancedFormatting.context;
    instruct = cfg.advancedFormatting.instruct;
    sysprompt = cfg.advancedFormatting.sysprompt;
    reasoning = cfg.advancedFormatting.reasoning;
  };

  advFmtDefaultNames = {
    context = lib.head (lib.filter (n: cfg.advancedFormatting.context.${n}.default) (lib.attrNames cfg.advancedFormatting.context) ++ [ null ]);
    instruct = lib.head (lib.filter (n: cfg.advancedFormatting.instruct.${n}.default) (lib.attrNames cfg.advancedFormatting.instruct) ++ [ null ]);
    sysprompt = lib.head (lib.filter (n: cfg.advancedFormatting.sysprompt.${n}.default) (lib.attrNames cfg.advancedFormatting.sysprompt) ++ [ null ]);
    reasoning = lib.head (lib.filter (n: cfg.advancedFormatting.reasoning.${n}.default) (lib.attrNames cfg.advancedFormatting.reasoning) ++ [ null ]);
  };

  setupAdvFmtScript = lib.optionalString (cfg.advancedFormatting != { }) (advFmtModule.mkAdvancedFormattingSetupScript {
    dataDir = cfg.dataDir;
    user = config.home.username;
    group = "users";
    defaultNames = advFmtDefaultNames;
    presetDirs = advFmtPresetDirs;
  });

  advancedFormattingEnabled = cfg.advancedFormatting.context != { }
    || cfg.advancedFormatting.instruct != { }
    || cfg.advancedFormatting.sysprompt != { }
    || cfg.advancedFormatting.reasoning != { };

  # ---- User Settings ----
  userSettingsModule = import ./user-settings.nix { inherit lib; };

  userSettingsJson = userSettingsModule.mkUserSettingsJson cfg.userSettings;

  setupUserSettingsScript = pkgs.writeShellScript "sillytavern-setup-user-settings" ''
    set -e
    USER_SETTINGS='${userSettingsJson}'
    DATA_DIR="${cfg.dataDir}"

    if [ -d "$DATA_DIR" ]; then
      for userdir in "$DATA_DIR"/data/*/; do
        settings_file="$userdir/settings.json"
        [ -f "$settings_file" ] || continue
        ${pkgs.jq}/bin/jq \
          --argjson pu "$USER_SETTINGS" \
          '.power_user = (.power_user // {}) * $pu' \
          "$settings_file" > "$settings_file.tmp" && \
        mv "$settings_file.tmp" "$settings_file"
      done
    fi
  '';

  # ---- Extensions ----
  extensionsModule = import ./extensions.nix { inherit lib pkgs; };

  extSourceDir = extensionsModule.mkExtensionsDir cfg.declaredExtensions;

  setupExtensionsScript = extensionsModule.mkExtensionsSetupScript {
    dataDir = cfg.dataDir;
    user = config.home.username;
    group = "users";
    extensions = cfg.declaredExtensions;
    extSourceDir = "${extSourceDir}";
    thirdPartyDir = "${cfg.package}/lib/node_modules/sillytavern/public/scripts/extensions/third-party";
  };

  extensionsConfigured = cfg.declaredExtensions != { };

  # ---- Content Sources ----
  contentSourcesModule = import ./content-sources.nix { inherit lib pkgs; };

  setupContentScript = contentSourcesModule.mkContentSetupScript {
    dataDir = cfg.dataDir;
    user = config.home.username;
    group = "users";
    characters = cfg.declaredCharacters;
    lorebooks = cfg.declaredLorebooks;
  };

  contentConfigured = cfg.declaredCharacters != { } || cfg.declaredLorebooks != { };

  extraExtSettingsConfigured = cfg.extraExtensionSettings != { };

  setupExtraExtSettingsScript = pkgs.writeShellScript "sillytavern-setup-extra-ext-settings" ''
    set -e
    DATA_DIR="${cfg.dataDir}"
    if [ -d "$DATA_DIR" ]; then
      for userdir in "$DATA_DIR"/data/*/; do
        settings_file="$userdir/settings.json"
        [ -f "$settings_file" ] || continue
        SETTINGS='${builtins.toJSON cfg.extraExtensionSettings}'
        ${pkgs.jq}/bin/jq \
          --argjson s "$SETTINGS" \
          '.extension_settings = (.extension_settings // {}) * $s' \
          "$settings_file" > "$settings_file.tmp" && \
        mv "$settings_file.tmp" "$settings_file"
      done
    fi
  '';
in
{
  meta.maintainers = with lib.maintainers; [ ];

  options.services.sillytavern = {
    enable = lib.mkEnableOption "SillyTavern LLM frontend";

    package = lib.mkPackageOption pkgs "sillytavern" { };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "${config.home.homeDirectory}/.local/share/sillytavern";
      defaultText = lib.literalExpression "$HOME/.local/share/sillytavern";
      description = "Root directory for SillyTavern user data.";
    };

    # --- Server ---

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      example = 8000;
      description = "Server listening port.";
    };

    listen = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = "Whether to listen on all network interfaces.";
    };

    listenAddressIPv4 = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      example = "127.0.0.1";
      description = "Specific IPv4 address to listen to.";
    };

    listenAddressIPv6 = lib.mkOption {
      type = lib.types.str;
      default = "[::]";
      example = "::1";
      description = "Specific IPv6 address to listen to.";
    };

    protocolIPv4 = lib.mkOption {
      type = lib.types.either lib.types.bool (lib.types.enum [ "auto" ]);
      default = true;
      description = "Enable or disable IPv4 protocol. Use \"auto\" to auto-detect.";
    };

    protocolIPv6 = lib.mkOption {
      type = lib.types.either lib.types.bool (lib.types.enum [ "auto" ]);
      default = false;
      description = "Enable or disable IPv6 protocol. Use \"auto\" to auto-detect.";
    };

    dnsPreferIPv6 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Prefer IPv6 for DNS.";
    };

    enableKeepAlive = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable HTTP/HTTPS keep-alive globally.";
    };

    heartbeatInterval = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      example = 30;
      description = "Interval in seconds to write a heartbeat file. Set to 0 to disable.";
    };

    # --- SSL ---

    ssl = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable SSL/TLS encryption.";
          };

          certPath = lib.mkOption {
            type = lib.types.str;
            default = "./certs/cert.pem";
            description = "Path to SSL certificate file.";
          };

          keyPath = lib.mkOption {
            type = lib.types.str;
            default = "./certs/privkey.pem";
            description = "Path to SSL private key file.";
          };

          keyPassphrase = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Passphrase for the SSL private key.";
          };
        };
      };
      default = { };
      description = "SSL/TLS configuration.";
    };

    # --- Security ---

    whitelistMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "Toggle whitelist mode.";
    };

    whitelist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "::1" "127.0.0.1" ];
      example = [ "::1" "127.0.0.1" "192.168.1.0/24" ];
      description = "Whitelist of allowed IP addresses.";
    };

    whitelistDockerHosts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically whitelist Docker host and gateway IPs.";
    };

    basicAuthMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable basic authentication.";
    };

    basicAuthUser = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Basic authentication username.";
    };

    basicAuthPassword = lib.mkOption {
      type = lib.types.str;
      default = "password";
      description = "Basic authentication password.";
    };

    enableCorsProxy = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable CORS proxy middleware.";
    };

    disableCsrf = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable CSRF protection. NOT RECOMMENDED.";
    };

    securityOverride = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable startup security checks. NOT RECOMMENDED.";
    };

    # --- CORS ---

    cors = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable or disable CORS middleware.";
          };

          origin = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "null" ];
            example = [ "https://example.com" ];
            description = "Allowed origins.";
          };

          methods = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "OPTIONS" ];
            description = "Allowed HTTP methods.";
          };

          allowedHeaders = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Allowed request headers.";
          };

          exposedHeaders = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Exposed response headers.";
          };

          credentials = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Allow credentials (cookies, authorization headers).";
          };

          maxAge = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            default = null;
            description = "Preflight cache max age in seconds.";
          };
        };
      };
      default = { };
      description = "CORS configuration.";
    };

    # --- User Accounts ---

    enableUserAccounts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable multi-user mode.";
    };

    enableDiscreetLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable discreet login mode.";
    };

    sessionTimeout = lib.mkOption {
      type = lib.types.int;
      default = -1;
      example = 86400;
      description = "User session timeout in seconds.";
    };

    # --- Browser Launch ---

    browserLaunch = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Open the browser automatically on server startup.";
          };

          browser = lib.mkOption {
            type = lib.types.str;
            default = "default";
            example = "firefox";
            description = "Browser to use.";
          };

          hostname = lib.mkOption {
            type = lib.types.str;
            default = "auto";
            example = "localhost";
            description = "Override the browser launch hostname.";
          };

          port = lib.mkOption {
            type = lib.types.int;
            default = -1;
            example = 8000;
            description = "Override the browser launch port. -1 uses server port.";
          };

          avoidLocalhost = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Avoid using \"localhost\" in auto mode.";
          };
        };
      };
      default = { };
      description = "Browser launch configuration.";
    };

    # --- Request Proxy ---

    requestProxy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable outgoing request proxy.";
          };

          url = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "socks5://username:password@example.com:1080";
            description = "Proxy URL.";
          };

          bypass = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "localhost" "127.0.0.1" ];
            description = "Proxy bypass list.";
          };
        };
      };
      default = { };
      description = "Request proxy configuration.";
    };

    # --- Logging ---

    logging = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enableAccessLog = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable access logging.";
          };

          minLogLevel = lib.mkOption {
            type = lib.types.ints.between 0 3;
            default = 0;
            description = "Minimum log level (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR).";
          };
        };
      };
      default = { };
      description = "Logging configuration.";
    };

    # --- Rate Limiting ---

    rateLimiting = lib.mkOption {
      type = lib.types.submodule {
        options = {
          basicAuthMaxAttempts = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 5;
            description = "Max failed basic auth attempts.";
          };

          accountsLoginMaxAttempts = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 5;
            description = "Max failed login attempts.";
          };

          accountsRecoverMaxAttempts = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 5;
            description = "Max failed recovery attempts.";
          };
        };
      };
      default = { };
      description = "Rate limiting configuration.";
    };

    # --- Extensions ---

    extensions = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable UI extensions.";
          };

          autoUpdate = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Automatically update extensions.";
          };
        };
      };
      default = { };
      description = "Extensions configuration.";
    };

    enableServerPlugins = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable server plugin support.";
    };

    enableServerPluginsAutoUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically update server plugins.";
    };

    # --- Misc ---

    allowKeysExposure = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow secret keys exposure via API.";
    };

    skipContentCheck = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Skip new default content checks.";
    };

    gitBackend = lib.mkOption {
      type = lib.types.enum [ "auto" "system" "builtin" ];
      default = "auto";
      description = "Git backend for plugin/extension operations.";
    };

    enableDownloadableTokenizers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable downloadable tokenizers.";
    };

    promptPlaceholder = lib.mkOption {
      type = lib.types.str;
      default = "[Start a new chat]";
      description = "Placeholder for strict prompt post-processing.";
    };

    # --- Text Completion Presets ---

    textCompletionPresets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule presetsModule.presetSubmodule);
      default = { };
      example = {
        MyPreset = {
          temp = 0.8;
          top_p = 0.9;
          rep_pen = 1.0;
          max_length = 4096;
          genamt = 512;
          default = true;
        };
      };
      description = ''
        Text generation completion presets.
        Each key is a preset name. The preset with `default = true` is loaded on startup.
        Use `extraSettings` for any fields not covered by the dedicated options.
      '';
    };

    # --- Connection Profiles ---

    connectionProfiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule connectionProfilesModule.connectionProfileSubmodule);
      default = { };
      example = {
        OpenAI = {
          mode = "cc";
          api = "openai";
          preset = "Default";
          model = "gpt-4";
          apiUrl = "https://api.openai.com/v1";
          default = true;
        };
        LocalLLaMA = {
          mode = "tc";
          api = "koboldcpp";
          preset = "Default";
          apiUrl = "http://localhost:5001";
          instruct = "ChatML";
          context = "Default";
          instructState = true;
        };
      };
      description = ''
        Connection profiles for API backends.
        Each key is a profile identifier. The profile marked `default = true`
        is selected on startup. Profiles are injected into settings.json
        on every service start (declarative).
      '';
    };

    # --- Advanced Formatting ---

    advancedFormatting = lib.mkOption {
      type = lib.types.submodule {
        options = {
          context = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule advFmtModule.contextSubmodule);
            default = { };
            example = {
              Default = {
                story_string = "{{#if system}}{{system}}\n{{/if}}{{trim}}";
                example_separator = "***";
                chat_start = "***";
                names_as_stop_strings = true;
                default = true;
              };
            };
            description = "Context template presets.";
          };

          instruct = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule advFmtModule.instructSubmodule);
            default = { };
            example = {
              ChatML = {
                input_sequence = "<|im_start|>user";
                output_sequence = "<|im_start|>assistant";
                system_sequence = "<|im_start|>system";
                stop_sequence = "<|im_end|>";
                wrap = true;
                names_behavior = "force";
                default = true;
              };
            };
            description = "Instruct template presets.";
          };

          sysprompt = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule advFmtModule.syspromptSubmodule);
            default = { };
            example = {
              "Roleplay - Simple" = {
                content = "You're {{char}} in this roleplay with {{user}}.";
                default = true;
              };
            };
            description = "System prompt presets.";
          };

          reasoning = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule advFmtModule.reasoningSubmodule);
            default = { };
            example = {
              DeepSeek = {
                prefix = "<think>\n";
                suffix = "\n</think>";
                separator = "\n\n";
                default = true;
              };
            };
            description = "Reasoning template presets.";
          };
        };
      };
      default = { };
      description = ''
        Advanced formatting presets including context templates, instruct templates,
        system prompts, and reasoning templates. Each type supports multiple named
        presets. The preset with `default = true` is loaded on startup.
      '';
    };

    # --- User Settings ---

    userSettings = lib.mkOption {
      type = lib.types.submodule userSettingsModule.userSettingsSubmodule;
      default = { };
      example = {
        enable = true;
        theme = "Dark";
        chat_display = 1;
        send_on_enter = 1;
        smooth_streaming = true;
        fuzzy_search = true;
      };
      description = ''
        Declarative user settings (power_user). When `enable = true`,
        configured settings are applied to settings.json on every service
        start. Settings not set here are preserved.
      '';
    };

    # --- Declared Extensions ---

    declaredExtensions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule extensionsModule.extensionSubmodule);
      default = { };
      example = {
        regex = {
          enable = true;
          settings.regex_presets = [
            { name = "Cleanup"; findRegex = "_{2,}"; replacement = ""; }
          ];
        };
      };
      description = ''
        Extension configuration. Each key is an extension name.
        - `enable`: toggle extension on/off
        - `source`: optional Nix path/derivation to install the extension from
        - `settings`: extension-specific settings merged into
          extension_settings.<name> in settings.json
        - `extraManifest`: override manifest.json fields
      '';
    };

    # --- Extra Extension Settings ---

    extraExtensionSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        openai.prompts = [ "Hello" "World" ];
        regex.extraPatterns = [ ];
      };
      description = ''
        Arbitrary extension_settings paths to inject into settings.json.
        Unlike `declaredExtensions.<name>.settings`, this option allows
        setting any nested path under extension_settings without requiring
        a matching declared extension entry.
        These are deep-merged on each service start.
      '';
    };

    # --- Declared Characters ---

    declaredCharacters = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule contentSourcesModule.characterSubmodule);
      default = { };
      example = {
        "My Character" = {
          url = "https://files.catbox.moe/abc123.png";
          rewriteExisting = false;
        };
      };
      description = ''
        Characters to download on service start.
        Each key is a display name. The file is downloaded from the
        given URL and placed in each user's characters/ directory
        if it doesn't already exist.
      '';
    };

    # --- Declared Lorebooks ---

    declaredLorebooks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule contentSourcesModule.lorebookSubmodule);
      default = { };
      example = {
        "Fantasy World" = {
          url = "https://files.catbox.moe/def456.json";
        };
      };
      description = ''
        Lorebooks (world info) to download on service start.
        Each key is a display name. The file is downloaded from the
        given URL and placed in each user's worlds/ directory
        if it doesn't already exist.
      '';
    };

    # --- Extra ---

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        forwardedHeaders.xRealIp = true;
      };
      description = "Extra configuration merged into config.yaml.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Config file
    xdg.configFile."sillytavern/config.yaml".source = configYaml.generateConfigYaml cfg;

    # Systemd user service
    systemd.user.services.sillytavern = {
      description = "SillyTavern LLM Frontend";
      after = [ "network.target" ];
      wantedBy = [ "graphical-session.target" ];
      path = [ pkgs.gitMinimal pkgs.jq pkgs.curl ];

      serviceConfig = {
        Type = "simple";
        ExecStartPre =
          [
            "${lib.getBin pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}"
            "${setupPresetsScript}"
          ]
          ++ lib.optionals (cfg.connectionProfiles != { }) [
            "${setupConnectionProfilesScript}"
          ]
          ++ lib.optionals advancedFormattingEnabled [
            "${setupAdvFmtScript}"
          ]
          ++ lib.optionals cfg.userSettings.enable [
            "${setupUserSettingsScript}"
          ]
          ++ lib.optionals extensionsConfigured [
            "${setupExtensionsScript}"
          ]
          ++ lib.optionals extraExtSettingsConfigured [
            "${setupExtraExtSettingsScript}"
          ]
          ++ lib.optionals contentConfigured [
            "${setupContentScript}"
          ];
        ExecStart = ''
          ${lib.getExe cfg.package} --configPath ${config.xdg.configHome}/sillytavern/config.yaml
        '';
        Restart = "always";
        WorkingDirectory = cfg.dataDir;
      };
    };
  };
}
