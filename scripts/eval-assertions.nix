#!/usr/bin/env nix
# eval-assertions.nix — evaluate a configuration and report this module's
# assertion failures. Usage:
#   nix eval --impure --json -f scripts/eval-assertions.nix --argstr settings '{...}'
# or edit the `settings` argument below.
{
  settings ? { },
  extra ? { },
}:
let
  f = builtins.getFlake "path:/home/seanc/Projects/SillyTavern";
  lib = f.inputs.nixpkgs.lib;
  pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; };
  system = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      f.nixosModules.sillytavern
      (
        { lib, ... }:
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/null";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.05";
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
          services.sillytavern-nixos = ({
            enable = true;
            config.enableUserAccounts = true;
            users.me = {
              name = "Me";
              passwordFile = pkgs.writeText "pw" "x";
            };
          } // extra);
        }
      )
    ];
  };
  failures = builtins.filter (a: !a.assertion) system.config.assertions;
in
{
  count = builtins.length failures;
  messages = map (a: a.message) failures;
}
