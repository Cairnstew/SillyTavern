#!/usr/bin/env python3
"""Tests for scripts/st_link_models.py — the model-cache linker.

The behaviours worth pinning down here are the ones that would be *data loss*
or a *silent no-op* if they broke:

  * a cache directory holding downloaded models is MOVED ASIDE, never deleted;
  * the link is created when there is nothing there, and REPLACED when it
    points somewhere else;
  * running it twice does the same thing as running it once;
  * a missing target is an error, not a dangling link.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import st_link_models as linker  # noqa: E402


class LinkCacheTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.data_root = self.root / "data"
        self.data_root.mkdir()
        self.target = self.root / "models"
        (self.target / "Xenova" / "whisper-small").mkdir(parents=True)
        (self.target / "Xenova" / "whisper-small" / "config.json").write_text("{}")
        self.cache = self.data_root / "_cache"

    def tearDown(self):
        self._tmp.cleanup()

    def test_creates_the_link_when_there_is_nothing_there(self):
        linker.link_cache(str(self.data_root), str(self.target))
        self.assertTrue(self.cache.is_symlink())
        self.assertEqual(os.readlink(self.cache), str(self.target))

    def test_is_idempotent(self):
        linker.link_cache(str(self.data_root), str(self.target))
        linker.link_cache(str(self.data_root), str(self.target))
        self.assertTrue(self.cache.is_symlink())
        self.assertEqual(os.readlink(self.cache), str(self.target))

    def test_repoints_a_link_that_points_elsewhere(self):
        other = self.root / "other"
        other.mkdir()
        os.symlink(str(other), self.cache)
        linker.link_cache(str(self.data_root), str(self.target))
        self.assertEqual(os.readlink(self.cache), str(self.target))

    def test_replaces_an_empty_cache_directory(self):
        self.cache.mkdir()
        linker.link_cache(str(self.data_root), str(self.target))
        self.assertTrue(self.cache.is_symlink())

    def test_moves_a_populated_cache_directory_aside_rather_than_deleting_it(self):
        # The one behaviour that is data loss if it breaks: the operator's
        # downloaded models must survive the link being created.
        self.cache.mkdir()
        (self.cache / "Cohee").mkdir()
        (self.cache / "Cohee" / "model.onnx").write_text("weights")

        linker.link_cache(str(self.data_root), str(self.target))

        self.assertTrue(self.cache.is_symlink())
        moved = self.data_root / "_cache.moved-by-nix"
        self.assertTrue(moved.is_dir())
        self.assertEqual(
            (moved / "Cohee" / "model.onnx").read_text(), "weights"
        )

    def test_a_second_populated_cache_gets_its_own_aside_directory(self):
        self.cache.mkdir()
        (self.cache / "one").write_text("1")
        linker.link_cache(str(self.data_root), str(self.target))

        # Put a real directory back and run again: the first moved-aside
        # directory must not be overwritten.
        self.cache.unlink()
        self.cache.mkdir()
        (self.cache / "two").write_text("2")
        linker.link_cache(str(self.data_root), str(self.target))

        self.assertEqual(
            (self.data_root / "_cache.moved-by-nix" / "one").read_text(), "1"
        )
        self.assertEqual(
            (self.data_root / "_cache.moved-by-nix.1" / "two").read_text(), "2"
        )

    def test_a_missing_target_is_an_error(self):
        with self.assertRaises(SystemExit):
            linker.link_cache(str(self.data_root), str(self.root / "nope"))
        # And nothing was created: a dangling link would be worse than none.
        self.assertFalse(self.cache.exists())
        self.assertFalse(self.cache.is_symlink())


class CommandLineTests(unittest.TestCase):
    def test_the_script_runs_as_a_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data_root = root / "data"
            data_root.mkdir()
            target = root / "models"
            target.mkdir()

            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO / "scripts" / "st_link_models.py"),
                    "--data-root",
                    str(data_root),
                    "--target",
                    str(target),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((data_root / "_cache").is_symlink())


if __name__ == "__main__":
    unittest.main()
