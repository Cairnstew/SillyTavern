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

  # The module supplies its OWN package, so that `package` never has to be set
  # by hand and so that a same-named but incompatible package in the consumer's
  # pkgs cannot be picked up by accident.
  #
  # This is not hypothetical. nixos-unstable ships `pkgs.sillytavern` at the
  # SAME version (1.19.0), and its `bin` entry point is `src/server-global.js`
  # — which sets `globalThis.FORCE_GLOBAL_MODE = true`. In that mode SillyTavern
  # explicitly ignores `--configPath` and `--dataRoot` (src/command-line.js
  # warns about each and uses the XDG paths instead). So pointing this module at
  # the nixpkgs package produces a server that starts, serves HTTP 200, and
  # silently ignores the systemd StateDirectory, writing everything into the
  # service account's ~/.local/share instead.
  #
  # `mkDefault` means an explicit `services.sillytavern-nixos.package` still
  # wins, and the overlay's `pkgs.sillytavern` is used when a consumer sets that.
  config.services.sillytavern-nixos.package = lib.mkDefault (
    pkgs.callPackage ../pkgs/sillytavern {
      version = (pkgs.lib.importJSON ../version.json).version;
      # Must be passed explicitly. `callPackage` otherwise auto-fills `src`
      # from `pkgs`, where it now resolves to the renamed `simple-revision-control`
      # package and fails with "The \"src\" package has been renamed".
      src = ../.;
    }
  );
}
