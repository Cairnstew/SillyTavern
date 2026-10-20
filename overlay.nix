# overlay.nix
#
# Exposes the server as `pkgs.sillytavern`.
#
# Consumers do not need this: the flake's `nixosModules` wrapper supplies the
# package to the module. It exists for the two cases that cannot get there — a
# non-flake consumer, or someone who wants to reach the package from their own
# package set.
#
# nixpkgs calls an overlay with BOTH `final` and `prev`, which is why this is
# written `final: _prev:`. Using `prev` would give the package a `pkgs` that
# lacks `sillytavern` itself.
final: _prev:
let
  inherit (final) lib;

  # The application source: THIS tree, filtered exactly as the flake does it.
  #
  # `lib/source.nix` holds the one definition, shared with `flake.nix`,
  # `modules/sillytavern.nix` and `default.nix`. The two overlays must
  # produce the same derivation — a divergence here means `pkgs.sillytavern`
  # means two different things depending on which entry point the consumer
  # reached for.
  source = import ./lib/source.nix { inherit lib; } ./.;
in
{
  # `src` is passed EXPLICITLY. It must be, and this is not a style preference:
  #
  # `pkgs/sillytavern/default.nix` declares an argument literally named `src`
  # (`src ? null`, defaulting to a `fetchgit` of the upstream release branch).
  # `callPackage` fills ANY argument whose name matches an attribute of the
  # package set — and nixpkgs also defines `src`. So when this overlay omits it,
  # `callPackage` does NOT fall through to the `? null` default; it injects
  # `pkgs.src`, which nixpkgs has renamed to `simple-revision-control` and
  # which throws when forced:
  #
  #   error: The "src" package has been renamed to "simple-revision-control".
  #          If you encounter this error and did not intend to use that package
  #          you may have a falsely constructed overlay.
  #
  # That made this file — the documented NON-FLAKE entry point, re-exported as
  # `overlay` from default.nix:78 — fail to evaluate outright. The `fetchgit`
  # fallback it was relying on was dead code: reachable only by not calling
  # through `callPackage` at all.
  #
  # Passing `src` explicitly both fixes the failure and restores the intent:
  # an overlay user now gets a build of THIS tree, reproducible and matching
  # the flake's overlay.
  #
  # NB the local binding above is called `source`, but the ARGUMENT must be
  # spelled `src = source;`. Writing `inherit source;` passes an argument named
  # `source`, which `pkgs/sillytavern/default.nix` does not declare — so `src`
  # stays unfilled and `callPackage` injects `pkgs.src` anyway. That mistake
  # reproduces this exact error even with a perfectly good filtered source in
  # scope, which is what makes the trap worth spelling out.
  sillytavern = final.callPackage ./pkgs/sillytavern {
    src = source;
    version = (final.lib.importJSON ./version.json).version;
  };
}