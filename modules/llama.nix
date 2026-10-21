# modules/llama.nix
#
# llama.cpp's OpenAI-compatible server, as a systemd service, in ROUTER mode.
#
# This is a SEPARATE module from `services.sillytavern-nixos` on purpose. The
# two services have different lifetimes, different failure modes and different
# resource profiles, and neither should force the other on. Import it where you
# want it:
#
#   imports = [ inputs.sillytavern.nixosModules.llama-cpp ];
#
# ── Why router mode ──────────────────────────────────────────────────────────
#
# Launched without a model, `llama serve` is a router: it loads models on
# demand, unloads them under pressure, and forwards each request to the
# instance that owns the requested `"model"`. One port serves every model, and
# a model that is not being used costs no RAM. That is the right shape for a
# SillyTavern host, where the active model changes per profile rather than per
# process.
#
# The model catalogue is rendered to the `.ini` format `--models-preset`
# reads. A section name IS the model id:
#
#   [gemma-4-e4b]
#   model = /nix/store/…-gemma-4-e4b-Q4_0.gguf
#   c = 16384
#   ngl = all
#
# so the string SillyTavern puts in `oai_settings.custom_model` is exactly the
# section name. `modules/options.nix`'s `modelLayers.catalog.<id>.connection.model`
# must therefore be the SAME string; the two modules deliberately do not read
# each other (see docs/options.md).
#
# ── Why the key is `c`, not `ctx-size` ───────────────────────────────────────
#
# Both spellings are accepted by llama.cpp, and the long one is clearer in the
# INI. The short one is used here because it is the spelling in upstream's own
# preset example, and because a test asserts `c = <n>` in the rendered file:
# one spelling, one place to check.
#
# ── Why `load-on-startup` is not an ordinary `args` key ──────────────────────
#
# It is a PRESET-ONLY key (it is not a CLI flag), and the primary model should
# load eagerly while every other model stays lazy. Exposing it twice — once as
# a first-class `primary`/`loadOnStartup` pair and once as `args.load-on-startup`
# — would give one value two sources. `args` refuses it, and the module
# asserts that refusal rather than silently dropping the key.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.llama-cpp-nixos;
  llama = import ../lib/llama.nix { inherit lib; };

  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  # All six hardware caps share the shape `services.sillytavern-nixos` uses.
  # Declared locally rather than imported: a module must not read another
  # module's option tree, and this is a type, not a value.
  int32 = types.ints.between (-2147483648) 2147483647;

  hardware = types.submodule {
    options = {
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "24G";
        description = "systemd MemoryMax. null = unlimited.";
      };
      memoryHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "20G";
        description = "systemd MemoryHigh. null = unlimited.";
      };
      memorySwapMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "0";
        description = "systemd MemorySwapMax. null = unlimited.";
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "400%";
        description = "systemd CPUQuota. null = unlimited.";
      };
      nice = mkOption {
        type = types.nullOr int32;
        default = null;
        description = "systemd Nice. null = leave the default.";
      };
      ioWeight = mkOption {
        type = types.nullOr int32;
        default = null;
        description = "systemd IOWeight (1-10000). null = leave the default.";
      };
    };
  };

  # A value that can be rendered by lib/llama.nix. Lists are the
  # comma-separated form (`tensor-split = [ 3 1 ]`).
  scalar =
    types.oneOf [
      types.bool
      types.int
      types.float
      types.str
      (types.listOf (types.oneOf [
        types.bool
        types.int
        types.float
        types.str
      ]))
    ];

  # Where a model's bytes come from. Exactly one of:
  #
  #   { path = "/var/lib/llama/model.gguf"; }             operator-managed
  #   { url = "https://…"; hash = "sha256-…"; }           pinned, in the store
  #
  # The default is deliberately the operator-managed form: a GGUF is often tens
  # of gigabytes, and putting it in the store makes every consumer pay for it in
  # closure size and keeps it alive against GC. A pinned URL is available when
  # reproducibility matters more than store size.
  weightsType = types.submodule {
    options = {
      path = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/llama/gemma-4-e4b-Q4_0.gguf";
        description = ''
          An absolute path to a `.gguf` file the operator manages. The file
          must exist when the service starts; the module does not create it.
        '';
      };
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://huggingface.co/…/model-Q4_0.gguf";
        description = ''
          A URL to fetch at BUILD time with `pkgs.fetchurl`. Requires `hash`,
          and is mutually exclusive with `path`.
        '';
      };
      hash = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "sha256-…";
        description = "The fixed-output hash for `url`.";
      };
    };
  };

  model = types.submodule {
    options = {
      weights = mkOption {
        type = weightsType;
        default = { };
        description = "Where this model's GGUF lives. Set `path` or `url`+`hash`.";
      };
      ctxSize = mkOption {
        type = types.ints.positive;
        default = 4096;
        example = 16384;
        description = ''
          Context size in tokens, rendered as `c` in the model's section.

          When this model is also declared under
          `services.sillytavern-nixos.modelLayers.catalog.<id>.contextSize`, the
          two values must agree. They are separate options because the modules
          do not read each other; the SillyTavern side generates
          `openai_max_context` from its own value, and a test pins the generated
          pairing.
        '';
      };
      primary = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Load this model when the service starts. Exactly one model must be
          primary. It is equivalent to `loadOnStartup = true` unless that is set
          explicitly.
        '';
      };
      loadOnStartup = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Override `primary` for this model. `load-on-startup` is a preset-only
          key in llama.cpp, not a CLI flag; it is emitted here rather than
          accepted in `args`.
        '';
      };
      args = mkOption {
        type = types.attrsOf scalar;
        default = { };
        example = literalExpression ''
          {
            ngl = "all";
            np = 2;
            "chat-template" = "gemma";
            "cache-type-k" = "q8_0";
            jinja = true;
          }
        '';
        description = ''
          Extra llama.cpp flags for this model, written as INI keys (the CLI
          spelling without the leading dashes). `model`, `c`/`ctx-size` and
          `load-on-startup` are reserved: they come from `weights`, `ctxSize`
          and `primary`/`loadOnStartup` respectively, and declaring them here is
          an evaluation error rather than a silent drop.
        '';
      };
    };
  };

  # `weights` → the path llama.cpp receives as `model`.
  #
  # Total on purpose: a malformed `weights` is caught by an assertion with a
  # message, and this function still evaluates so the rest of the unit can be
  # inspected. Rendering an empty model path is invalid, but it is never
  # activated with one.
  resolvedWeights = w:
    if w.path != null then
      toString w.path
    else if w.url != null && w.hash != null then
      toString (pkgs.fetchurl { url = w.url; hash = w.hash; })
    else
      "";

  reservedArgs = [
    "model"
    "c"
    "ctx-size"
    "load-on-startup"
  ];

  effectiveLoadOnStartup = m: if m.loadOnStartup != null then m.loadOnStartup else m.primary;

  modelSections = lib.mapAttrs (
    _id: m:
    {
      args =
        {
          model = resolvedWeights m.weights;
          c = m.ctxSize;
          load-on-startup = effectiveLoadOnStartup m;
        }
        // lib.removeAttrs m.args reservedArgs;
    }
  ) cfg.models;

  modelsPreset = llama.renderModelsPreset {
    globalArgs = cfg.globalArgs;
    models = modelSections;
  };

  presetFile = pkgs.writeText "llama-models.ini" modelsPreset;

  cacheDir = "/var/lib/${cfg.stateDirectory}/cache";

  # The API key is a credential: it must not appear in the unit file or in the
  # Nix store. `LoadCredential` puts it in a 0700 directory for this unit only,
  # and the wrapper copies it into the environment form llama.cpp reads.
  launcher = pkgs.writeShellApplication {
    name = "llama-cpp-service";
    runtimeInputs = [ pkgs.coreutils ];
    # Split assignment from `export`: `export FOO="$(cmd)"` masks the command's
    # exit status and shellcheck flags it (SC2155); `set -a` / `set +a` is worse,
    # because shellcheck does not model it at all and reads the bare assignment
    # as an unused variable (SC2034). nixpkgs' `writeShellApplication` runs
    # shellcheck at default severity, where either warning is fatal.
    text = ''
      if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -f "''${CREDENTIALS_DIRECTORY}/api-key" ]; then
        LLAMA_ARG_API_KEY="$(cat "''${CREDENTIALS_DIRECTORY}/api-key")"
        export LLAMA_ARG_API_KEY
      fi
      exec ${lib.getExe' cfg.package "llama"} serve
    '';
  };

  systemdHardwareName = {
    memoryMax = "MemoryMax";
    memoryHigh = "MemoryHigh";
    memorySwapMax = "MemorySwapMax";
    cpuQuota = "CPUQuota";
    nice = "Nice";
    ioWeight = "IOWeight";
  };

  hardwareConfig = lib.filterAttrs (_: value: value != null) (
    lib.mapAttrs' (name: value: lib.nameValuePair systemdHardwareName.${name} value) cfg.hardware
  );

  modelIds = builtins.attrNames cfg.models;
  primaryModels = builtins.filter (m: m.primary) (lib.attrValues cfg.models);

  weightOk = w:
    (w.path != null && w.url == null && w.hash == null)
    || (w.path == null && w.url != null && w.hash != null);

  badWeights = builtins.filter (id: !(weightOk cfg.models.${id}.weights)) modelIds;

  reservedInArgs = builtins.filter (
    id: lib.any (key: builtins.hasAttr key cfg.models.${id}.args) reservedArgs
  ) modelIds;

  badSections = builtins.filter (id: !(llama.validSection id)) modelIds;
in
{
  options.services.llama-cpp-nixos = {
    enable = mkEnableOption "the llama.cpp OpenAI-compatible server in router mode";

    package = mkOption {
      type = types.package;
      default = pkgs.llama-cpp;
      defaultText = literalExpression "pkgs.llama-cpp";
      description = ''
        The llama.cpp build to run. Use `pkgs.llama-cpp-cuda`,
        `pkgs.llama-cpp-rocm` or `pkgs.llama-cpp-vulkan` for acceleration;
        the plain package has runtime CPU dispatch.
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Bind address. The default keeps the server on loopback; put SillyTavern
        on the same host, or expose it deliberately with `openFirewall` and an
        API key.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 9931;
      description = "Port the router listens on (llama.cpp's own default).";
    };

    user = mkOption {
      type = types.str;
      default = "llama-cpp";
      description = ''
        Service account. The default account is created by this module; set it
        to an existing account to reuse one.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "llama-cpp";
      description = "Service group, created when it is the default.";
    };

    stateDirectory = mkOption {
      type = types.str;
      default = "llama-cpp";
      description = ''
        systemd `StateDirectory`, i.e. `/var/lib/<name>`. The model cache lives
        at `<name>/cache`, and it is the only writable path the unit gets.
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression ''"/run/agenix/llama-api-key"'';
      description = ''
        File holding the API key. Delivered with `LoadCredential`, never through
        the unit file or the store, and exported as `LLAMA_ARG_API_KEY` by the
        service wrapper. `null` disables authentication — only safe on a
        trusted loopback.
      '';
    };

    router = {
      maxModels = mkOption {
        type = types.ints.between 0 1024;
        default = 4;
        description = "Maximum number of models loaded at once. `0` = unlimited.";
      };
      autoload = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Let the router load a requested model automatically. With `false`,
          only the primary model is available until something else asks for a
          load.
        '';
      };
    };

    models = mkOption {
      type = types.attrsOf model;
      default = { };
      example = literalExpression ''
        {
          "gemma-4-e4b" = {
            weights.path = "/var/lib/llama/gemma-4-e4b-Q4_0.gguf";
            ctxSize = 16384;
            primary = true;
            args = { ngl = "all"; np = 2; "chat-template" = "gemma"; };
          };
        }
      '';
      description = ''
        The model catalogue. The attribute NAME is the model id the router
        routes on, and it must equal
        `services.sillytavern-nixos.modelLayers.catalog.<id>.connection.model`
        when both modules are used. The two modules deliberately do not read
        each other.
      '';
    };

    globalArgs = mkOption {
      type = types.attrsOf scalar;
      default = { };
      example = literalExpression ''{ c = 8192; }'';
      description = ''
        Keys for the `[*]` section: defaults every model inherits. A model's own
        `args`/`ctxSize` overrides them. `model` is refused here because it is
        per-model by definition.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Extra `LLAMA_ARG_*` variables (or anything else the process needs).
        Values are rendered into the unit environment; they are not secrets.
      '';
    };

    startupTimeout = mkOption {
      type = types.ints.positive;
      default = 600;
      description = ''
        `TimeoutStartSec`. Loading a large GGUF from disk can take minutes; too
        short a value reports a failure while the load is still succeeding.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open `port` in the host firewall. Only meaningful with a non-loopback `host`.";
    };

    hardware = mkOption {
      type = hardware;
      default = { };
      description = "Resource limits for the unit. All null = no limit.";
    };

    internal = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = ''
        Derived values for tests and diagnostics: the rendered `.ini` text, its
        store path, and the model ids. Not a public interface.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.models != { };
        message = ''
          services.llama-cpp-nixos: `models` is empty.

          Router mode without a catalogue serves nothing: `llama serve` starts,
          listens, and answers every request with "model not found". Declare at
          least one model under `services.llama-cpp-nixos.models.<id>`.
        '';
      }
      {
        assertion = builtins.length primaryModels == 1;
        message = ''
          services.llama-cpp-nixos: exactly one model must set `primary = true`.

          Found ${toString (builtins.length primaryModels)}. The primary model is
          the one llama.cpp loads at startup (`load-on-startup = true`); every
          other model stays lazy. Name exactly one.
        '';
      }
      {
        assertion = lib.all (m: !(m.primary && m.loadOnStartup == false)) (
          lib.attrValues cfg.models
        );
        message = ''
          services.llama-cpp-nixos: a model is `primary = true` and
          `loadOnStartup = false`.

          Those say opposite things. Remove one: `primary` is shorthand for
          "load at startup", and `loadOnStartup` is the explicit override.
        '';
      }
      {
        assertion = badWeights == [ ];
        message = ''
          services.llama-cpp-nixos: each model needs exactly one weights source.

          Set `weights.path` for an operator-managed `.gguf`, or `weights.url`
          AND `weights.hash` for a pinned store copy. Not both, not neither.

          Offending models: ${lib.concatStringsSep ", " badWeights}
        '';
      }
      {
        assertion = reservedInArgs == [ ];
        message = ''
          services.llama-cpp-nixos: a model's `args` sets a reserved key.

          `model`, `c`/`ctx-size` and `load-on-startup` are derived from
          `weights`, `ctxSize` and `primary`/`loadOnStartup`. Declaring them in
          `args` would give one value two sources, so they are refused rather
          than silently dropped.

          Offending models: ${lib.concatStringsSep ", " reservedInArgs}
        '';
      }
      {
        assertion = !(builtins.hasAttr "model" cfg.globalArgs);
        message = ''
          services.llama-cpp-nixos: `globalArgs.model` is not allowed.

          A model path is per model. Put it in each model's `weights`.
        '';
      }
      {
        assertion = badSections == [ ];
        message = ''
          services.llama-cpp-nixos: a model id cannot be used as an INI section name.

          An id containing a newline, `[`, `]`, `#` or `;` would change the
          parsed structure of the preset file instead of naming a model.

          Offending ids: ${lib.concatStringsSep ", " badSections}
        '';
      }
      {
        assertion = cfg.user != "" && cfg.group != "";
        message = "services.llama-cpp-nixos: `user` and `group` must not be empty.";
      }
    ];

    users.users = mkIf (cfg.user == "llama-cpp") {
      llama-cpp = {
        isSystemUser = true;
        group = cfg.group;
      };
    };

    users.groups = mkIf (cfg.group == "llama-cpp") {
      llama-cpp = { };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.llama-cpp-nixos = {
      description = "llama.cpp inference server (router mode)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        LLAMA_ARG_HOST = cfg.host;
        LLAMA_ARG_PORT = toString cfg.port;
        LLAMA_ARG_MODELS_PRESET = toString presetFile;
        LLAMA_ARG_MODELS_MAX = toString cfg.router.maxModels;
        LLAMA_ARG_MODELS_AUTOLOAD = lib.boolToString cfg.router.autoload;
        LLAMA_CACHE = cacheDir;
      } // cfg.extraEnvironment;

      # StateDirectory creates /var/lib/<name> and exempts it from
      # ProtectSystem=strict; the cache is one level down, so the service user
      # creates it (it owns the parent).
      preStart = ''
        ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg cacheDir}
      '';

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe launcher;
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = cfg.stateDirectory;
        StateDirectoryMode = "0750";
        WorkingDirectory = "/var/lib/${cfg.stateDirectory}";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = cfg.startupTimeout;
        TimeoutStopSec = 30;
        # llama.cpp handles SIGINT as the graceful "finish the request and
        # unload" signal; systemd's default SIGTERM is not it.
        KillSignal = "SIGINT";
        LimitNOFILE = 65536;

        # GPU access means no PrivateDevices and no seccomp/memory-exec
        # restrictions: the CUDA/Vulkan runtimes load device nodes and JIT.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      } // hardwareConfig // lib.optionalAttrs (cfg.apiKeyFile != null) {
        LoadCredential = "api-key:${toString cfg.apiKeyFile}";
      };
    };

    services.llama-cpp-nixos.internal = {
      modelsPreset = modelsPreset;
      presetFile = toString presetFile;
      modelIds = modelIds;
      cacheDir = cacheDir;
    };
  };
}
