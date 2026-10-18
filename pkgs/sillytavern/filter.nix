# pkgs/sillytavern/filter.nix
#
# The source filter for the SillyTavern package.
#
# A checkout of this repository is not packageable as-is:
#
#   .git/          hundreds of MiB of history, and it makes the store path
#                  depend on which branch was checked out. (When the source
#                  comes from `./.` inside the flake, Nix has already stripped
#                  this — the check is here for a `path:` or local-directory
#                  source, which has not.)
#   node_modules/  a local `npm install` tree, ~400 MiB, and one that does NOT
#                  match package-lock.json — so the package would silently ship
#                  dependencies the lockfile does not describe
#   dist/          webpack output, rebuilt by the server on every start
#   result         a Nix build symlink, which would make the source depend on
#                  build results and recurse
#
# `.gitignore` also lists `/default/scaffold`, which is generated content and is
# simply absent from a fresh checkout. Nothing depends on it existing:
# `src/endpoints/content-manager.js` reads `default/scaffold/index.json` behind
# an `fs.existsSync` and merges it if present.
#
# This is deliberately a short exclusion list rather than a `lib.fileset`
# allow-list. The package needs nearly the whole tree, so an allow-list would be
# long and would need editing every time upstream adds a directory — which is
# exactly the kind of routine maintenance that silently breaks a package build.
#
# Passed to `lib.cleanSourceWith` as `filter`, which calls it as
# `filter path type` and keeps the entry when it returns true.
{
  lib,
}:

path: type:
let
  base = baseNameOf (toString path);
in
# `.git` is a DIRECTORY at the top level; skipping on the basename alone would
# also skip any file called `.git`, which is harmless but worth being precise
# about.
!(base == ".git" && type == "directory")
&& base != "node_modules"
&& base != "dist"
&& base != "result"
