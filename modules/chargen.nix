# modules/chargen.nix
#
# The character-card generator (`sillytavern-mkchar`).
#
# SillyTavern reads characters from `<dataRoot>/<handle>/characters/` as
# TavernCard PNG/JSON files, and writing one by hand that is both valid
# (every v2 key, right types — see `src/validator/TavernCardValidator.js`)
# and good (enough `description` for the model to roleplay with) is fiddly.
# `scripts/st_mkchar.py` walks the operator through a fixed questionnaire and
# asks a chat-completion endpoint to draft the long-form fields.
#
# This module puts that script on PATH with the endpoint and model
# pre-defaulted, so on a host that already runs a backend it is just:
#
#   sillytavern-mkchar
#
# ── Endpoint precedence ───────────────────────────────────────────────────────
#
# Explicit `charGen.endpoint` wins. Otherwise, when the llama.cpp module in
# this flake is enabled in the same system, its router is used
# (`http://<host>:<port>/v1` — the server is OpenAI-compatible). Otherwise
# the Ollama default (`http://127.0.0.1:11434/v1`).
#
# This is the same OPTIONAL cross-module read `modules/config.nix` does for
# the Breeze TTS backend (`or null` when the module is not imported), and it
# is one-way: nothing here sets a llama.cpp option, and llama.cpp never reads
# this one.
#
# The pre-defaults are injected with `wrapProgram --set-default`, not baked
# into the script: `ST_CHARGEN_ENDPOINT` set in the environment and every
# CLI flag (`--endpoint`, `--model`, `--api-key-file`) still override them.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sillytavern-nixos;
  gen = cfg.charGen;

  llama = config.services.llama-cpp-nixos or null;
  llamaEnabled = llama != null && (llama.enable or false);
  llamaEndpoint =
    if llamaEnabled then "http://${llama.host}:${toString llama.port}/v1" else null;

  resolvedEndpoint =
    if gen.endpoint != null then
      gen.endpoint
    else if llamaEndpoint != null then
      llamaEndpoint
    else
      "http://127.0.0.1:11434/v1";

  wrapped = pkgs.symlinkJoin {
    name = "sillytavern-mkchar-wrapped";
    paths = [ gen.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/sillytavern-mkchar \
        --set-default ST_CHARGEN_ENDPOINT ${lib.escapeShellArg resolvedEndpoint} \
        --set-default ST_CHARGEN_MODEL ${lib.escapeShellArg gen.model} \
        ${lib.optionalString (gen.apiKeyFile != null) "--set-default ST_CHARGEN_API_KEY_FILE ${lib.escapeShellArg (toString gen.apiKeyFile)}"}
    '';
    meta = (gen.package.meta or { }) // {
      description = "Guided TavernCard v2 generator, pre-pointed at this host's model endpoint";
    };
  };
in
{
  options.services.sillytavern-nixos.charGen = {
    enable = lib.mkEnableOption "the guided character-card generator CLI (sillytavern-mkchar)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/sillytavern/mkchar.nix { };
      defaultText = lib.literalExpression "this flake's st_mkchar wrapper";
      description = "The generator package to install. Override to ship a patched script.";
    };

    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://127.0.0.1:11434/v1";
      description = ''
        OpenAI-compatible base URL the generator drafts with
        (`/chat/completions` is appended unless already present).

        `null` (the default) resolves at build time: the llama.cpp router in
        the same system when `services.llama-cpp-nixos.enable` is set, else
        the Ollama default `http://127.0.0.1:11434/v1`. `--endpoint` on the
        command line always wins over all of these.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "llama3.1";
      example = "qwen2.5:14b";
      description = ''
        Default chat model id sent as `model` in the completions request.
        Must exist on the endpoint (an Ollama tag, a llama.cpp router model
        id, …). `--model` on the command line overrides this.
      '';
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.age.secrets.chargen_api_key.path";
      description = ''
        File holding the endpoint's bearer token, read at runtime and exported
        as `ST_CHARGEN_API_KEY_FILE`. `null` sends no token, which is right
        for Ollama and for the llama.cpp router with no API key. Prefer this
        over `--api-key`: a flag value is visible in `ps` and shell history.
      '';
    };
  };

  config = lib.mkIf gen.enable {
    environment.systemPackages = [ wrapped ];
  };
}
