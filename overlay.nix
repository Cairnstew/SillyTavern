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
#
# `src` is deliberately NOT passed. Without it the package falls back to
# `fetchgit`, so an overlay user gets a build of the upstream release branch
# rather than of whatever is checked out here. To build the local tree, set
# `services.sillytavern.package` explicitly (see docs/installing.md).
final: _prev: {
  sillytavern = final.callPackage ./pkgs/sillytavern {
    version = (final.lib.importJSON ./version.json).version;
  };
}
