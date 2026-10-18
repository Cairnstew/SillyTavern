# modules/sillytavern.nix
#
# The NixOS module for SillyTavern.
#
# Import order matters and is fixed here rather than left to the consumer:
#
#   options.nix     declares the whole option surface
#   config.nix      renders config.yaml, the secrets env file and the argv, and
#                   exposes them as `internal` read-only options
#   services.nix    builds the systemd unit, and imports assertions.nix itself
#   assertions.nix  validates the combinations that fail silently
#
# `config.nix` must come before `services.nix` so that the `internal` options it
# defines are available to read. NixOS evaluates `imports` in order for that
# purpose; `services.nix` only reads them lazily, so the dependency is real but
# not order-critical at eval time.
#
# The `internal` options exist rather than passing values as module arguments
# because a module cannot take arguments. They are all `readOnly`, so a consumer
# cannot accidentally override them, and the secret-bearing ones are `internal`
# so they are omitted from generated documentation.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./options.nix
    ./config.nix
    ./services.nix
    ./assertions.nix
  ];
}
