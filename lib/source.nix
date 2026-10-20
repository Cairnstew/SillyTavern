# lib/source.nix
#
# The ONE definition of the package's source tree.
#
# Why this file exists
# --------------------
#
# The application source has to be filtered before it becomes a build input:
# `pkgs/sillytavern/filter.nix` drops `.git`, `node_modules`, `dist` and
# `result`. Without that filter, a checkout with a local `npm install` tree
# ships ~400 MiB of dependencies that the committed lockfile does not describe,
# and the resulting store path changes whenever a stray file appears in the
# working tree.
#
# This filter was originally spelled out FOUR times — in `flake.nix` (twice:
# the overlay and the `packages` output), in `overlay.nix`, and in the two
# places that supply the module's default package (`modules/sillytavern.nix`
# and `default.nix`). Two of those four used the UNFILTERED source, which
# had three consequences a consumer can observe:
#
#   1. `pkgs.sillytavern` from the overlay and the package the module
#      actually runs were DIFFERENT store paths — two builds of the same
#      software, and `pkgs.sillytavern` did not mean "what the module runs".
#
#   2. The module's package hash changed when a stray `node_modules`
#      appeared in the source tree, so a `path:` flake input pointing at a
#      developer's working copy was not reproducible.
#
#   3. The unfiltered tree was copied into the store as the build input,
#      so the `path:`-input case paid for 400 MiB it never used.
#
# One definition, used by all four call sites, removes the drift by
# construction: a consumer who applies the overlay and a consumer who does
# not now get the SAME package, because the source and the `name` are the
# same and `cleanSourceWith` derives its output path from the CONTENT.
#
# `lib` is a parameter rather than being imported from `<nixpkgs>` because
# the consumer's `lib` and the flake's `lib` are both legitimate here, and
# neither should be hard-coded. The filter itself does not use `lib` (it
# compares path basenames), so the two produce identical trees — and
# `cleanSourceWith`'s output path is derived from the content, so the store
# path is the same either way.
#
# Deliberately NOT part of `lib/default.nix`: that file's contract is
# "pure — takes values and returns strings or attrsets, and never
# instantiates `pkgs`", so that it can be unit-tested without a package set
# and reused from a consumer's own module. `cleanSourceWith` instantiates a
# derivation, so this file stands apart.
{ lib }:

# `src` is the tree to filter. In practice it is always the repository root:
# `./.` from a file at the root, `../.` from one a level down.
src:
lib.cleanSourceWith {
  inherit src;

  # The name is part of the fixed-output derivation's store path, so it has
  # to be the same string everywhere this is used. Changing it orphans the
  # old build rather than reusing it.
  name = "sillytavern-source";

  filter = import ../pkgs/sillytavern/filter.nix { inherit lib; };
}
