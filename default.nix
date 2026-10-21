# default.nix — the non-flake entry point.
#
# The top level is a plain ATTRSET, deliberately, because that is what makes the
# obvious non-flake incantation work:
#
#   # in a non-flake configuration.nix
#   imports = [
#     (import (builtins.fetchTarball {
#       url = "https://github.com/Cairnstew/SillyTavern/archive/release.tar.gz";
#     })).nixosModules.default
#   ];
#
# Selecting `.nixosModules` straight off an `import` requires the imported file to
# evaluate to an attrset. A function of `{ flake }` would fail with
# `error: expected a set but found a function` while this file's own comment
# advertised it. A function top level is only reachable as `(import path) { … }`,
# which is the flake-compat calling convention; flake-compat is not how anyone
# should consume this, because its job is to let a NON-flake consumer read a
# consumer's flake outputs, and here the consumer is importing us directly.
# `builtins.fetchTarball` is both simpler and the shape that works.
#
# What a non-flake consumer gets:
#
#   nixosModules.default                  the module, with `package` supplied
#   nixosModules.sillytavern              the same module under a stable name
#
# The options live under `services.sillytavern-nixos`, NOT `services.sillytavern`:
# nixos-unstable ships its own minimal module under that name and it cannot be
# removed from a NixOS system. See modules/options.nix.
#   homeModules.default                   the Home Manager half
#   homeModules.sillytavern               the same module under a stable name
#   lib                                   renderYaml / renderEnvFile / keyToEnv / …
#   overlay                               adds pkgs.sillytavern
#
# Not bridged: `packages`, `apps`, `checks`, `devShells`, `formatter`. Those are
# per-system flake outputs and need an instantiated package set; see the note on
# `lib` below.
let
  # nixpkgs' `lib`, used ONLY for the shared helper library, which needs nothing
  # beyond string/list/attrset functions.
  #
  # Deliberately NOT an instantiated package set. Building one here would mean
  # choosing a channel behind the consumer's back and then handing the module a
  # `pkgs` that is not theirs. The consumer's own nixpkgs decides licensing and
  # unfree-ness, and they have to allow it regardless.
  lib = (import <nixpkgs> { }).lib;

  # `modules/sillytavern.nix` cannot reference `self`, because a flake input's
  # module scope has no path back to its own flake — so it cannot ask the flake
  # for its own `packages` output.
  #
  # It does not need to. It builds the package itself, from
  # `pkgs.callPackage ./pkgs/sillytavern` on the CONSUMER's package set, with
  # the filtered source from `lib/source.nix`. That matters: an earlier version
  # of a sibling project imported `<nixpkgs>` here and handed the module its own
  # package, which broke the moment the consumer passed their own
  # `nixpkgs.pkgs`, with "attribute 'project-zomboid-server' missing".
  # Deriving it from the module's own `pkgs` argument cannot go stale that way.
  #
  # This file used to set `services.sillytavern-nixos.package` as well, and the
  # two definitions agreed only by accident. They no longer do: the module
  # computes the source with the CONSUMER's `lib`, and this file could only
  # offer `<nixpkgs>`'s — two `lib` versions whose `cleanSourceWith` need not
  # agree on the output path, which is a "conflicting definition values" error
  # waiting for a consumer whose nixpkgs and channel differ. One owner, one
  # definition.
  #
  # `mkDefault` in the module, so an explicit `package` set by the consumer
  # still wins.
  sillytavernModule = {
    imports = [ ./modules/sillytavern.nix ];
  };
in
{
  # For `<nixpkgs-overlays>` consumers who want to reach the package from their
  # own package set.
  overlay = import ./overlay.nix;

  nixosModules = {
    default = sillytavernModule;
    sillytavern = sillytavernModule;
    # The llama.cpp backend, for non-flake consumers. Opt-in, like the flake
    # output: import it only where an inference server belongs.
    llama-cpp = {
      imports = [ ./modules/llama.nix ];
    };
  };

  # The Home Manager half, for the same reason the flake exposes it: the SillyTavern
  # data root is a systemd `StateDirectory`, and a system module cannot install
  # anything into a user's home directory.
  #
  # A plain Home Manager module — nothing for the caller to supply, unlike
  # `sillytavernModule` above, which has to fill in `package`. It stays inert
  # until a system config that provides the instance is in scope, because that is
  # where it reads the URL and account names from.
  homeModules = {
    default = import ./modules/home.nix;
    sillytavern = import ./modules/home.nix;
  };

  # The shared library the flake exports as `self.lib`: `renderYaml`,
  # `renderEnvFile`, `renderCliArgv`, `keyToEnv`, `userKeyFor`, `mkUserArg`,
  # `mkProxyUpstream`. A consumer writing their own integration, or merging
  # rendered config into something else, wants these.
  #
  # `lib.tests` is deliberately absent: it calls `nixpkgs.lib.nixosSystem`, which
  # lives in nixpkgs' *own* `lib` output and not in the instantiated package set's
  # — `(import <nixpkgs> {}).lib ? nixosSystem` is `false`. Reaching the full `lib`
  # without flakes means reaching into `<nixpkgs>`' internals, so `tests` stays a
  # flake-only output. Call `nixpkgs.lib.nixosSystem` directly instead, which is
  # what any real non-flake configuration does anyway.
  lib = import ./lib { inherit lib; };
}
