# modules/breeze-tts.nix
#
# Breeze-TTS-2.cpp's streaming speech server, as a systemd service, with the
# resource guards a shared GPU needs.
#
# A SEPARATE module from `services.sillytavern-nixos` and
# `services.llama-cpp-nixos`: all three have different lifetimes and failure
# modes, and none forces another on.
#
#   imports = [ inputs.sillytavern.nixosModules.breeze-tts ];
#
# ── Why the guards exist ─────────────────────────────────────────────────────
#
# The upstream server has no authentication, no rate limiting and no VRAM
# ceiling. It loads one model and accepts one generation at a time (a second
# request gets 409), but the model's footprint is claimed at START and held for
# the process's lifetime. On a 12 GiB card shared with an 8B LLM, starting the
# wrong quantization is how the LLM gets OOM-killed later, during an unrelated
# request.
#
# Vulkan has no per-process VRAM limit and neither does systemd: `MemoryMax`
# caps RAM, not device memory. So the guard is a contract plus two checks:
#
#   1. `gpu.totalVramMiB`, when set, is checked at EVALUATION time against the
#      model's published footprint plus headroom and reserve. A config that
#      cannot fit fails `nixos-rebuild` with the arithmetic in the message.
#   2. `ExecStartPre` reads the driver's real free VRAM for the configured
#      device and refuses to start when free < required + headroom. The reserve
#      is deliberately NOT added here: an LLM already resident has already
#      reduced the free figure, so counting its footprint again would refuse a
#      start that fits. This is the check that sees the LLM already resident;
#      (1) is what makes room for one that has not started yet.
#
# Both are needed. (1) cannot know what else is running; (2) cannot know what
# will start later. Together they stop the common case — TTS and the LLM
# fighting over one card — without pretending to be a scheduler.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.breeze-tts-nixos;

  inherit
    (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    optional
    types
    ;

  # The shipped GGUF catalogue: file names, sha256 pins and footprint
  # estimates. Pure, so tests and docs read the same numbers.
  modelCatalog = import ../lib/tts-models.nix;

  int32 = types.ints.between (-2147483648) 2147483647;

  hardware = types.submodule {
    options = {
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default =
          if modelInfo != null
          then "${toString modelInfo.ramMiB}M"
          else null;
        defaultText = literalExpression "the selected catalogue model's ramMiB, as MiB";
        example = "6G";
        description = ''
          systemd `MemoryMax`. This is SYSTEM RAM, not VRAM: it bounds the
          process and its page cache, not the model's residency on the GPU.

          For a catalogue model the default is the file size plus 2 GiB. A
          custom GGUF must set this explicitly, because the module cannot stat
          an arbitrary path at evaluation time.
        '';
      };
      memoryHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "5G";
        description = "systemd MemoryHigh. null = unlimited below MemoryMax.";
      };
      memorySwapMax = mkOption {
        type = types.nullOr types.str;
        default = "0";
        description = ''
          systemd MemorySwapMax. The default pins the working set in RAM: a
          swapped-out vocoder turns a real-time failure into a machine-wide
          stall rather than a single slow request.
        '';
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = "400%";
        example = "200%";
        description = ''
          systemd CPUQuota. A safety net for the case where Vulkan init fails
          and ggml silently falls back to the CPU: without a quota a CPU
          fallback pins every core for the length of a generation.
        '';
      };
      nice = mkOption {
        type = types.nullOr int32;
        default = 5;
        description = "systemd Nice. null = leave the default.";
      };
      ioWeight = mkOption {
        type = types.nullOr int32;
        default = null;
        description = "systemd IOWeight (1-10000). null = leave the default.";
      };
    };
  };

  gpu = types.submodule {
    options = {
      requireGpu = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Refuse to start when no dedicated GPU can be read. Does nothing when
          `backend = "cpu"`.

          The server silently falls back to the CPU when Vulkan is unavailable,
          so without this a missing driver becomes a machine-wide CPU burn
          instead of a failed unit.
        '';
      };
      requiredVramMiB = mkOption {
        type = types.nullOr types.ints.positive;
        default =
          if modelInfo != null
          then modelInfo.vramMiB
          else null;
        defaultText = literalExpression "the selected catalogue model's vramMiB";
        description = ''
          The model's VRAM footprint, in MiB. Defaults from
          `lib/tts-models.nix` for a catalogue model. A custom GGUF MUST set it:
          the guard does not guess.
        '';
      };
      headroomMiB = mkOption {
        type = types.ints.unsigned;
        default = 768;
        description = ''
          Free VRAM that must remain after the model is loaded: driver
          allocations, the Vulkan swapchain and transient compute buffers. Too
          small a value passes the check and OOMs on the first long request.
        '';
      };
      reserveForOtherMiB = mkOption {
        type = types.ints.unsigned;
        default = 0;
        example = 7000;
        description = ''
          VRAM that must stay free for everything else — in practice, the
          llama.cpp model sharing the card. It is used by the STATIC check:
          `gpu.totalVramMiB` must be at least
          `requiredVramMiB + headroomMiB + reserveForOtherMiB`.

          It is deliberately NOT added to the start-time probe. If the LLM is
          already resident, its footprint has already reduced the driver's free
          figure, and adding it again would refuse a start that fits. If the
          LLM has not started yet, the static check is what guarantees it will
          still fit afterwards.
        '';
      };
      totalVramMiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 12288;
        description = ''
          The card's total VRAM, for the evaluation-time budget check. When set,
          a configuration whose model + headroom + reserve exceeds it fails
          `nixos-rebuild` with the numbers. null skips the static check and
          leaves only the runtime probe.
        '';
      };
      deviceIndex = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "The GPU index the start check reads. ggml's own device selection is separate.";
      };
      checkAtStart = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run the free-VRAM probe as `ExecStartPre`. Turning this off removes
          the only check that sees what is already resident; keep it on unless
          the driver exposes no readable memory figure.
        '';
      };
    };
  };

  weightsType = types.submodule {
    options = {
      path = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/breeze-tts/models/breeze-tts-2-q4_k.gguf";
        description = ''
          An absolute path to a `.gguf` the operator manages. The file must
          exist when the service starts; the module does not create it.

          A custom GGUF also requires `gpu.requiredVramMiB` and
          `hardware.memoryMax`, because it has no catalogue entry to derive
          them from.
        '';
      };
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://huggingface.co/…/breeze-tts-2-q4_k.gguf";
        description = ''
          A URL fetched at BUILD time with `pkgs.fetchurl`. Requires `hash`, is
          mutually exclusive with `path` and `model`, and puts the weights in
          the Nix store — a 2.4–6 GB closure addition. Use `model` +
          `downloadModel` for an operator-managed copy instead.
        '';
      };
      hash = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The SRI hash for `url` (for example `sha256-…`).";
      };
    };
  };

  modelIds = builtins.attrNames modelCatalog;

  # null when a custom GGUF is used. Defaults and assertions branch on this.
  modelInfo =
    if cfg.model != null
    then modelCatalog.${cfg.model}
    else null;

  cataloguePath =
    if modelInfo != null
    then "${cfg.modelDirectory}/${modelInfo.file}"
    else "";

  resolvedWeights =
    if cfg.weights.path != null
    then toString cfg.weights.path
    else if cfg.weights.url != null && cfg.weights.hash != null
    then
      toString (pkgs.fetchurl {
        url = cfg.weights.url;
        hash = cfg.weights.hash;
      })
    else cataloguePath;

  requiredVramMiB =
    if cfg.gpu.requiredVramMiB != null
    then cfg.gpu.requiredVramMiB
    else if modelInfo != null
    then modelInfo.vramMiB
    else 0;

  # Two different questions, deliberately two numbers.
  #
  # `needVramMiB` is the STATIC budget: does the whole plan fit the card,
  # including the room another consumer (the LLM) will need? It is checked at
  # evaluation time against `gpu.totalVramMiB`.
  #
  # `runtimeNeedVramMiB` is what must be free RIGHT NOW for this process. It
  # does NOT add `reserveForOtherMiB`: an already-resident LLM has already
  # reduced the free figure, and adding its footprint again would refuse a start
  # that plainly fits. The reserve protects the case where the LLM has not
  # started yet — the static check is what makes room for it.
  needVramMiB = requiredVramMiB + cfg.gpu.headroomMiB + cfg.gpu.reserveForOtherMiB;
  runtimeNeedVramMiB = requiredVramMiB + cfg.gpu.headroomMiB;

  # Exactly one weights source.
  weightsSources =
    (
      if cfg.model != null
      then 1
      else 0
    )
    + (
      if cfg.weights.path != null
      then 1
      else 0
    )
    + (
      if cfg.weights.url != null || cfg.weights.hash != null
      then 1
      else 0
    );

  reservedArgs = [
    "--host"
    "--port"
    "--ws-port"
    "--voices-dir"
    "--chunk-first"
    "--chunk-max"
    "--split-chars"
    "--cpu"
    "--webui"
    "--cors"
    "--no-warmup"
    "--verbose"
  ];

  # Both spellings: `--port 1234` and `--port=1234` reach the server the same
  # way, so a guard that only knew the first would be bypassable with the second.
  reservedInExtraArgs =
    builtins.filter (
      arg: lib.any (reserved: arg == reserved || lib.hasPrefix "${reserved}=" arg) reservedArgs
    )
    cfg.extraArgs;

  # systemd option names differ from the camelCase option names; map explicitly
  # rather than relying on a case conversion that would silently miss one.
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

  serverArgs =
    [
      resolvedWeights
      "--host"
      cfg.host
      "--port"
      (toString cfg.port)
      "--voices-dir"
      "/var/lib/${cfg.stateDirectory}/voices"
    ]
    ++ optional (cfg.wsPort != null) "--ws-port"
    ++ optional (cfg.wsPort != null) (toString cfg.wsPort)
    ++ optional cfg.webui "--webui"
    ++ optional (cfg.backend == "cpu") "--cpu"
    ++ optional cfg.verbose "--verbose"
    ++ optional cfg.noWarmup "--no-warmup"
    ++ [
      "--chunk-first"
      (toString cfg.chunkFirst)
      "--chunk-max"
      (toString cfg.chunkMax)
      "--split-chars"
      (toString cfg.splitChars)
    ]
    ++ optional (cfg.corsOrigins != []) "--cors"
    ++ optional (cfg.corsOrigins != []) (lib.concatStringsSep "," cfg.corsOrigins)
    ++ cfg.extraArgs;

  # ── ExecStartPre: is the model there? ───────────────────────────────────────
  #
  # A catalogue model is not downloaded unless the operator asks. This turns the
  # server's own late "failed to load" into a message naming the missing file
  # and the command that fixes it.
  modelCheck = pkgs.writeShellScript "breeze-tts-model-check" ''
    set -euo pipefail
    target=${lib.escapeShellArg resolvedWeights}
    if [ ! -s "$target" ]; then
      {
        echo "services.breeze-tts-nixos: model file is missing or empty:"
        echo "  $target"
        echo
        if [ ${
      if cfg.model != null
      then "1"
      else "0"
    } = 1 ]; then
          echo "Fetch it once, then restart:"
          echo "  curl -fL --create-dirs -o '$target' \\"
          echo "    'https://huggingface.co/HoppouAI/Breeze-TTS-2.cpp/resolve/main/${modelInfo.file}'"
          echo
          echo "or set services.breeze-tts-nixos.downloadModel = true to let"
          echo "the unit fetch and sha256-verify it on start."
        else
          echo "services.breeze-tts-nixos.weights.path must point at an existing GGUF."
        fi
      } >&2
      exit 1
    fi
  '';

  # ── ExecStartPre: opt-in, verified download ─────────────────────────────────
  #
  # Runtime network access is OFF by default, matching the rest of this repo.
  # When enabled, the pinned sha256 is the contract: an existing file that does
  # not match is discarded, and a resumed `.part` is verified before the atomic
  # rename.
  fetchModel = pkgs.writeShellScript "breeze-tts-fetch-model" ''
    set -euo pipefail
    target=${lib.escapeShellArg resolvedWeights}
    hash=${lib.escapeShellArg modelInfo.sha256}
    url="https://huggingface.co/HoppouAI/Breeze-TTS-2.cpp/resolve/main/${modelInfo.file}"
    dir=${lib.escapeShellArg cfg.modelDirectory}

    ${pkgs.coreutils}/bin/mkdir -p "$dir"

    verify() {
      printf '%s  %s\n' "$hash" "$1" | ${pkgs.coreutils}/bin/sha256sum --status -c -
    }

    if [ -f "$target" ]; then
      if verify "$target"; then
        echo "breeze-tts: model already present and verified: $target"
        exit 0
      fi
      echo "breeze-tts: $target failed its sha256 check; discarding it" >&2
      ${pkgs.coreutils}/bin/rm -f "$target"
    fi

    part="$target.part"
    if [ -f "$part" ]; then
      resume=(-C -)
    else
      resume=()
    fi

    echo "breeze-tts: fetching ${modelInfo.file} into $dir"
    ${pkgs.curl}/bin/curl -fL --retry 5 --retry-delay 3 --connect-timeout 15 \
      "''${resume[@]}" -o "$part" "$url"
    verify "$part"
    ${pkgs.coreutils}/bin/mv -f "$part" "$target"
  '';

  # ── ExecStartPre: the VRAM contract, against the real driver ────────────────
  #
  # NVIDIA is read through nvidia-smi, AMD through sysfs. Both report MiB.
  # No GPU means refusal by default: the failure this prevents is a silent CPU
  # fallback, not a missing feature.
  vramGuard = pkgs.writeShellScript "breeze-tts-vram-guard" ''
    set -euo pipefail

    backend=${lib.escapeShellArg cfg.backend}
    require_gpu=${
      if cfg.gpu.requireGpu
      then "1"
      else "0"
    }
    required=${toString requiredVramMiB}
    headroom=${toString cfg.gpu.headroomMiB}
    reserve=${toString cfg.gpu.reserveForOtherMiB}
    device=${toString cfg.gpu.deviceIndex}
    # What must be free now. `reserve` is NOT added: an LLM already resident has
    # already reduced the free figure the driver reports, so counting its
    # footprint again would refuse a start that fits.
    need=$((required + headroom))

    if [ "$backend" = "cpu" ]; then
      echo "breeze-tts: backend=cpu, GPU preflight skipped"
      exit 0
    fi

    if [ "$require_gpu" != "1" ]; then
      echo "breeze-tts: gpu.requireGpu=false, GPU preflight skipped"
      exit 0
    fi

    gpu_total=
    gpu_free=
    source=

    # nvidia-smi belongs to the driver package, not this module, and a systemd
    # unit's default PATH does not include the system profile.
    nvidia_smi=
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia_smi=$(command -v nvidia-smi)
    elif [ -x /run/current-system/sw/bin/nvidia-smi ]; then
      nvidia_smi=/run/current-system/sw/bin/nvidia-smi
    elif [ -x /usr/bin/nvidia-smi ]; then
      nvidia_smi=/usr/bin/nvidia-smi
    fi

    if [ -n "$nvidia_smi" ]; then
      if line=$("$nvidia_smi" -i "$device" \
          --query-gpu=memory.total,memory.free \
          --format=csv,noheader,nounits 2>/dev/null); then
        line=$(printf '%s\n' "$line" | ${pkgs.gawk}/bin/awk -F, 'NR==1 { gsub(/ /, "", $1); gsub(/ /, "", $2); print $1" "$2 }')
        if [ -n "$line" ]; then
          gpu_total=''${line%% *}
          gpu_free=''${line##* }
          source="nvidia (device $device)"
        fi
      fi
    fi

    if [ -z "$source" ]; then
      for dev in /sys/class/drm/card*/device; do
        [ -r "$dev/mem_info_vram_total" ] || continue
        total=$(${pkgs.coreutils}/bin/cat "$dev/mem_info_vram_total")
        used=$(${pkgs.coreutils}/bin/cat "$dev/mem_info_vram_used" 2>/dev/null || echo 0)
        total=$((total / 1024 / 1024))
        used=$((used / 1024 / 1024))
        if [ "$total" -gt 0 ]; then
          gpu_total=$total
          gpu_free=$((total - used))
          source="amd ($dev)"
          break
        fi
      done
    fi

    if [ -z "$source" ]; then
      {
        echo "ERROR: services.breeze-tts-nixos cannot read a dedicated GPU's memory."
        echo
        echo "Neither nvidia-smi nor an AMD mem_info_vram_* node was found."
        echo "The server would silently fall back to the CPU, which is what this"
        echo "guard exists to prevent. Fix the driver, or opt in explicitly:"
        echo
        echo "  services.breeze-tts-nixos.gpu.requireGpu = false;"
        echo "  services.breeze-tts-nixos.backend = \"cpu\";   # if that is the intent"
      } >&2
      exit 1
    fi

    echo "breeze-tts: $source VRAM free $gpu_free MiB of $gpu_total MiB; need $need MiB (model $required + headroom $headroom; reserve $reserve is checked statically, not here)"

    if [ "$gpu_free" -lt "$need" ]; then
      {
        echo "ERROR: refusing to start breeze-tts: not enough free VRAM."
        echo "  free $gpu_free MiB < required $need MiB"
        echo
        echo "Another process (the LLM) is holding the rest. Unload it, pick a"
        echo "smaller quantization (q4_k needs about 3 GiB), or lower"
        echo "gpu.headroomMiB deliberately."
      } >&2
      exit 1
    fi
  '';
in {
  options.services.breeze-tts-nixos = {
    enable = mkEnableOption "the Breeze-TTS-2.cpp streaming speech server";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/breeze-tts-2 {};
      defaultText = literalExpression "pkgs.callPackage ./pkgs/breeze-tts-2 { }";
      description = ''
        The Breeze-TTS build to run. The default is the Vulkan build. For a host
        without Vulkan, use
        `pkgs.callPackage ./pkgs/breeze-tts-2 { vulkanSupport = false; }` and
        set `backend = "cpu"` as well.
      '';
    };

    backend = mkOption {
      type = types.enum [
        "vulkan"
        "cpu"
      ];
      default = "vulkan";
      description = ''
        Which backend the server is asked to use. `cpu` adds `--cpu` and skips
        the GPU preflight; it is also the only correct pairing with a
        `vulkanSupport = false` package.
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Bind address. The default keeps the server on loopback. The server has
        no authentication and no rate limiting, so a non-loopback `host` is
        only safe behind a proxy that supplies both.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8137;
      description = "HTTP port for `/v1/audio/speech` and the web UI.";
    };

    wsPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = ''
        Fixed WebSocket port. null lets the server use `port + 1`, which is
        fine when that port is free and undesirable when it is not.
      '';
    };

    webui = mkOption {
      type = types.bool;
      default = false;
      description = "Serve the bundled browser UI at `/`. Opt-in.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open `port` and `wsPort` in the host firewall. Only meaningful with a non-loopback `host`.";
    };

    user = mkOption {
      type = types.str;
      default = "breeze-tts";
      description = "Service account. The default account is created by this module.";
    };

    group = mkOption {
      type = types.str;
      default = "breeze-tts";
      description = "Service group, created when it is the default.";
    };

    stateDirectory = mkOption {
      type = types.str;
      default = "breeze-tts";
      description = ''
        systemd `StateDirectory`, i.e. `/var/lib/<name>`. It holds `models/` and
        `voices/`, and it is the only writable path the unit gets.
      '';
    };

    modelDirectory = mkOption {
      type = types.str;
      default = "/var/lib/${cfg.stateDirectory}/models";
      defaultText = literalExpression ''"/var/lib/''${config.services.breeze-tts-nixos.stateDirectory}/models"'';
      description = ''
        Where a catalogue model's `.gguf` is expected. Also the target of
        `downloadModel`.
      '';
    };

    model = mkOption {
      type = types.nullOr (types.enum modelIds);
      default = null;
      example = "q4_k";
      description = ''
        A catalogue model, resolved to
        `${cfg.modelDirectory}/<file>`. Mutually exclusive with `weights`.

        The catalogue and its footprint estimates are in `lib/tts-models.nix`.
        For a 12 GiB card shared with a Q4 8B, `q4_k` is the safe default;
        `q8_0` fits only if the LLM's own reserve is kept under roughly 7 GiB.
      '';
    };

    downloadModel = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Fetch the selected catalogue model into `modelDirectory` at service
        start, verifying the pinned sha256 every time. Off by default: this
        repository does not otherwise reach the network at activation.

        Only valid with `model`; `weights.path`/`weights.url` are operator-owned
        and are never downloaded.
      '';
    };

    weights = mkOption {
      type = weightsType;
      default = {};
      description = ''
        A custom GGUF source. Exactly one of `model`, `weights.path` or
        `weights.url`+`weights.hash` must be set.

        A custom file has no catalogue entry, so `gpu.requiredVramMiB` and
        `hardware.memoryMax` must also be set.
      '';
    };

    chunkFirst = mkOption {
      type = types.ints.between 1 100;
      default = 4;
      description = "`--chunk-first`: frames in the first streamed chunk.";
    };

    chunkMax = mkOption {
      type = types.ints.between 1 100;
      default = 40;
      description = ''
        `--chunk-max`: the chunk size the ramp grows to. 40 is where the vocoder
        context is amortised; higher values make each chunk slower to produce
        and demand a deeper client buffer without buying throughput.
      '';
    };

    splitChars = mkOption {
      type = types.ints.between 0 100000;
      default = 300;
      description = ''
        `--split-chars`: long text is split on sentence boundaries into pieces
        of about this size. It bounds the per-piece compute and memory of an
        otherwise unbounded `text` field. 0 disables splitting and lets one
        request generate for as long as the text implies.
      '';
    };

    verbose = mkOption {
      type = types.bool;
      default = false;
      description = "`--verbose`: per-stage timings after each request.";
    };

    noWarmup = mkOption {
      type = types.bool;
      default = false;
      description = "`--no-warmup`: skip the startup generation that builds the GPU pipelines (saves ~2 s, costs ~300 ms on the first request).";
    };

    corsOrigins = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["http://localhost:5173"];
      description = ''
        Enable CORS for exactly these origins. Empty leaves CORS off, which is
        correct for the bundled UI and for SillyTavern on the same origin.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["--chunk-max" "60"];
      description = ''
        Extra server flags. The flags this module already owns (`--host`,
        `--port`, `--cpu`, `--chunk-*`, `--split-chars`, …) are refused rather
        than appended, so a guard cannot be bypassed by a second spelling.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra environment variables for the unit. Not secrets.";
    };

    startupTimeout = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "`TimeoutStartSec`. Loading several GiB from disk can take minutes.";
    };

    hardware = mkOption {
      type = hardware;
      default = {};
      description = "systemd resource caps. All null = no limit.";
    };

    gpu = mkOption {
      type = gpu;
      default = {};
      description = "The VRAM contract and start-time probe.";
    };

    internal = mkOption {
      type = types.attrs;
      internal = true;
      default = {};
      description = "Derived values for tests and diagnostics. Not a public interface.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = weightsSources == 1;
        message = ''
          services.breeze-tts-nixos: exactly one weights source is required.

          Set one of:
            * `model = "q4_k"` (a catalogue entry, expected in `modelDirectory`)
            * `weights.path = "/absolute/path.gguf"` (operator-managed)
            * `weights.url` + `weights.hash` (pinned, in the Nix store)

          Found ${toString weightsSources}.
        '';
      }
      {
        assertion = (cfg.weights.url != null) == (cfg.weights.hash != null);
        message = ''
          services.breeze-tts-nixos: `weights.url` and `weights.hash` must be
          set together. A URL without its hash is an unpinned download, and a
          hash without a URL names nothing.
        '';
      }
      {
        assertion = !cfg.downloadModel || (cfg.model != null && cfg.weights.path == null && cfg.weights.url == null);
        message = ''
          services.breeze-tts-nixos: `downloadModel = true` needs a catalogue
          `model` and cannot be combined with `weights`.

          Only catalogue files have a pinned sha256 this module can verify.
          Put a custom file in place yourself and use `weights.path`.
        '';
      }
      {
        assertion = modelInfo != null || (cfg.gpu.requiredVramMiB != null && cfg.hardware.memoryMax != null);
        message = ''
          services.breeze-tts-nixos: a custom GGUF must state its footprint.

          There is no catalogue entry to derive the guard from, so set both:
            * `gpu.requiredVramMiB` — the VRAM the model holds (see the table
              in docs/tts.md)
            * `hardware.memoryMax` — the systemd RAM cap (file size + 2 GiB is
              a safe starting point)

          The guard will not guess for a file it has never seen.
        '';
      }
      {
        assertion = cfg.gpu.totalVramMiB == null || needVramMiB <= cfg.gpu.totalVramMiB;
        message = ''
          services.breeze-tts-nixos: the requested model cannot fit on the
          declared card.

            model                ${toString requiredVramMiB} MiB
            headroom             ${toString cfg.gpu.headroomMiB} MiB
            reserve for others   ${toString cfg.gpu.reserveForOtherMiB} MiB
            ---------------------------------------
            needs                ${toString needVramMiB} MiB
            `gpu.totalVramMiB`   ${toString cfg.gpu.totalVramMiB} MiB

          Lower the model (`q4_k` is about 3 GiB), lower the reserve only if
          the other consumer really is smaller, or raise `gpu.totalVramMiB`
          only if the declared card is larger.
        '';
      }
      {
        assertion = cfg.backend != "vulkan" || (cfg.package.vulkanSupport or true);
        message = ''
          services.breeze-tts-nixos: `backend = "vulkan"` with a CPU-only
          package.

          A `vulkanSupport = false` build has no Vulkan backend, so the server
          would fall back to the CPU even though the GPU guard passed. Set
          `backend = "cpu"` as well, or use the default package.
        '';
      }
      {
        assertion = cfg.wsPort == null || cfg.wsPort != cfg.port;
        message = ''
          services.breeze-tts-nixos: `wsPort` equals `port`.

          The HTTP and WebSocket listeners are separate; one port cannot serve
          both. Leave `wsPort = null` to use `port + 1`, or name another port.
        '';
      }
      {
        assertion = cfg.chunkMax >= cfg.chunkFirst;
        message = "services.breeze-tts-nixos: `chunkMax` must be at least `chunkFirst`.";
      }
      {
        assertion = reservedInExtraArgs == [];
        message = ''
          services.breeze-tts-nixos: `extraArgs` repeats a flag this module
          already owns: ${lib.concatStringsSep ", " reservedInExtraArgs}.

          Use the named option instead (`chunkMax`, `splitChars`, `host`, …).
          Appending a second copy would give one value two sources and could
          bypass the resource bounds.
        '';
      }
      {
        assertion = !(lib.hasPrefix "/" cfg.stateDirectory);
        message = ''
          services.breeze-tts-nixos: `stateDirectory` must be relative.
          systemd creates StateDirectory entries under /var/lib; an absolute
          path is rejected by the unit.
        '';
      }
      {
        assertion = cfg.user != "" && cfg.group != "";
        message = "services.breeze-tts-nixos: `user` and `group` must not be empty.";
      }
    ];

    warnings =
      [
        ''
          services.breeze-tts-nixos: the Breeze TTS 2 weights are licensed for
          research and non-commercial use only. The source code is Apache-2.0;
          the weights are not. Hosting this as a service for others is outside
          that licence.
        ''
      ]
      ++ lib.optional (cfg.host != "127.0.0.1" && cfg.host != "::1") ''
        services.breeze-tts-nixos: `host = "${cfg.host}"` is not loopback. The
        server has no authentication and no rate limiting; put a proxy in front
        that supplies both.
      ''
      ++ lib.optional cfg.downloadModel ''
        services.breeze-tts-nixos: `downloadModel = true` makes the unit reach
        Hugging Face on start. The pinned sha256 is verified, but the network is
        no longer a build-time-only dependency.
      ''
      ++ lib.optional (cfg.backend == "cpu") ''
        services.breeze-tts-nixos: `backend = "cpu"` is much slower than
        Vulkan. Upstream measures roughly 1.5x realtime on an RTX 3060 and far
        below realtime on a CPU.
      '';

    users.users = mkIf (cfg.user == "breeze-tts") {
      breeze-tts = {
        isSystemUser = true;
        group = cfg.group;
      };
    };

    users.groups = mkIf (cfg.group == "breeze-tts") {
      breeze-tts = {};
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall (
      [cfg.port] ++ optional (cfg.wsPort != null) cfg.wsPort
    );

    # Vulkan needs the ICDs NixOS exposes at /run/opengl-driver. Make the
    # driver part of the host configuration rather than a runtime surprise.
    hardware.graphics.enable = mkIf (cfg.backend == "vulkan") (lib.mkDefault true);

    systemd.services.breeze-tts-nixos = {
      description = "Breeze-TTS-2.cpp streaming speech server";
      wantedBy = ["multi-user.target"];
      # If the LLM is enabled, its primary model has usually claimed VRAM by
      # the time this starts. A non-existent unit in After= is harmless.
      after = ["network.target"] ++ optional (cfg.backend == "vulkan") "llama-cpp-nixos.service";

      unitConfig = {
        StartLimitIntervalSec = 300;
        StartLimitBurst = 3;
      };

      environment =
        lib.optionalAttrs (cfg.backend == "vulkan") {
          VK_ICD_FILENAMES = "/run/opengl-driver/share/vulkan/icd.d:/run/opengl-driver-32/share/vulkan/icd.d";
        }
        // cfg.extraEnvironment;

      serviceConfig =
        {
          Type = "simple";
          ExecStartPre =
            optional cfg.downloadModel fetchModel
            ++ [modelCheck]
            ++ optional (cfg.backend == "vulkan" && cfg.gpu.checkAtStart) vramGuard;
          ExecStart = "${lib.getExe' cfg.package "breeze-server"} ${lib.escapeShellArgs serverArgs}";

          User = cfg.user;
          Group = cfg.group;
          StateDirectory = [
            cfg.stateDirectory
            "${cfg.stateDirectory}/models"
            "${cfg.stateDirectory}/voices"
          ];
          StateDirectoryMode = "0750";
          WorkingDirectory = "/var/lib/${cfg.stateDirectory}";

          Restart = "on-failure";
          RestartSec = 5;
          OOMPolicy = "stop";
          TimeoutStartSec = cfg.startupTimeout;
          TimeoutStopSec = 30;
          LimitNOFILE = 8192;
          TasksMax = 64;

          # GPU access means no PrivateDevices and no memory-exec restriction:
          # the Vulkan runtime loads device nodes and JIT-compiles shaders.
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
        }
        // hardwareConfig;

      path = [
        pkgs.coreutils
        pkgs.curl
      ];
    };

    services.breeze-tts-nixos.internal = {
      inherit
        needVramMiB
        requiredVramMiB
        runtimeNeedVramMiB
        reservedInExtraArgs
        resolvedWeights
        serverArgs
        weightsSources
        ;
      modelCatalog = modelCatalog;
      memoryMax = cfg.hardware.memoryMax;
      vramGuardScript = toString vramGuard;
      modelCheckScript = toString modelCheck;
      fetchModelScript = toString fetchModel;
    };
  };
}
