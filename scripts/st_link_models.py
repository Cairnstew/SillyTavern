#!/usr/bin/env python3
"""Point SillyTavern's model cache at a directory you chose.

Upstream hardcodes where the models it runs itself live:

    src/transformers.js:134
      const cacheDir = path.join(globalThis.DATA_ROOT, '_cache');

and transformers.js resolves a model file from that cache FIRST, falling back
to `<the transformers.js package>/models/` (the `localModelPath`). There is no
config key and no environment variable for either path, so a module that
wants to put the weights somewhere else has to change what `_cache` IS.

This script makes `<dataRoot>/_cache` a symlink to the directory the operator
chose. It is deliberately narrow:

  * it only ever touches `<dataRoot>/_cache` — one path, no globs;
  * it never writes INSIDE the target: the target may be a read-only store
    path, and the server's own writes into it are its business;
  * a cache directory that already holds downloaded models is MOVED ASIDE,
    never deleted. Those models are hundreds of MiB of somebody's downloads,
    and losing them because a Nix option changed would be unforgivable;
  * it is idempotent: running it twice does the same thing as running it once.

The link is created before the server starts, so the very first start already
sees the right cache. Upstream's `migrateCacheToDataDir` calls
`fs.mkdirSync(cacheDir, { recursive: true })` on every pipeline load, and
`mkdirSync` with `recursive: true` is a no-op on an existing symlink to an
existing directory — so the link survives that call.
"""

from __future__ import annotations

import argparse
import os
import sys

# The one path this script touches. Upstream's own name for it.
CACHE_DIRNAME = "_cache"


def _log(msg: str) -> None:
    print(f"st-link-models: {msg}", file=sys.stderr, flush=True)


def _free_name(path: str) -> str:
    """A path next to `path` that does not exist yet."""
    base = f"{path}.moved-by-nix"
    if not os.path.exists(base) and not os.path.islink(base):
        return base
    counter = 1
    while os.path.exists(f"{base}.{counter}") or os.path.islink(f"{base}.{counter}"):
        counter += 1
    return f"{base}.{counter}"


def link_cache(data_root: str, target: str) -> None:
    if not os.path.isdir(target):
        raise SystemExit(
            f"st-link-models: the model directory {target} does not exist, "
            "or is not a directory."
        )

    cache = os.path.join(data_root, CACHE_DIRNAME)

    if os.path.islink(cache):
        current = os.readlink(cache)
        if current == target:
            _log(f"{cache} already points at {target}")
            return
        _log(f"repointing {cache} from {current} to {target}")
        os.unlink(cache)
    elif os.path.isdir(cache):
        # A real directory here means the server has downloaded models into
        # it at some point. Those are the operator's files; move them aside
        # rather than deleting them, and say so loudly enough to be seen in
        # the journal.
        if not os.listdir(cache):
            _log(f"replacing the empty {cache} with a link to {target}")
            os.rmdir(cache)
        else:
            moved = _free_name(cache)
            _log(
                f"{cache} holds downloaded models; moving them to {moved} "
                "and linking it to the configured model directory"
            )
            os.rename(cache, moved)
    elif os.path.exists(cache):
        raise SystemExit(
            f"st-link-models: {cache} exists and is neither a directory nor a "
            "symlink. Refusing to replace it."
        )

    os.symlink(target, cache)
    _log(f"linked {cache} -> {target}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Point SillyTavern's model cache at a directory."
    )
    parser.add_argument(
        "--data-root",
        required=True,
        help="The server's data root; the cache is <data-root>/_cache.",
    )
    parser.add_argument(
        "--target",
        required=True,
        help="The directory the cache should point at.",
    )
    args = parser.parse_args(argv)

    link_cache(args.data_root, args.target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
