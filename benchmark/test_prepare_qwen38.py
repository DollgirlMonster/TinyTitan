#!/usr/bin/env python3
"""Tests for the `--reuse-ngram-table` gate.

The PLE table is 102 GB of fp16 and the same bytes in every quantization, so a
build may hardlink an existing one instead of fetching the 128 shards that
carry it. What makes that safe is not the bytes but the constants the table is
addressed by: a table built with different multipliers, offsets or vocabulary
sizes reads wrongly and produces garbage ids, and nothing inside the file says
so. So the refusal is the part worth pinning.

    cd benchmark && python3.13 -m unittest test_prepare_qwen38 -v

It imports the converter, which imports numpy, ml_dtypes and safetensors, so it
skips where those are absent.
"""
from __future__ import annotations

import json
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

try:
    import prepare_qwen38 as prepare
    IMPORT_ERROR = ""
except SystemExit as exc:  # the module exits when a dependency is missing
    prepare = None
    IMPORT_ERROR = str(exc)


@unittest.skipIf(prepare is None, f"prepare_qwen38 unavailable: {IMPORT_ERROR}")
class ReuseNgramTableTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="ngram-reuse-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.constants = {key: f"value-{key}" for key in prepare.REUSE_CONSTANT_KEYS}

    def install(self, constants: dict | None = None, sidecar: bool = True) -> pathlib.Path:
        directory = self.root / "install"
        directory.mkdir()
        if sidecar:
            (directory / "ple_constants.json").write_text(
                json.dumps(self.constants if constants is None else constants))
        (directory / "ngram_table.bin").write_bytes(b"table")
        return directory

    def test_a_matching_install_returns_its_table(self) -> None:
        directory = self.install()
        self.assertEqual(prepare.reusable_table_path(directory, self.constants),
                         directory / "ngram_table.bin")

    def test_a_table_file_is_taken_as_given(self) -> None:
        table = self.install() / "ngram_table.bin"
        self.assertEqual(prepare.reusable_table_path(table, self.constants), table)

    def test_every_addressed_constant_is_checked(self) -> None:
        directory = self.install()
        for key in prepare.REUSE_CONSTANT_KEYS:
            with self.subTest(key=key):
                changed = dict(self.constants)
                changed[key] = "something else"
                with self.assertRaises(SystemExit) as caught:
                    prepare.reusable_table_path(directory, changed)
                self.assertIn(key, str(caught.exception))

    def test_a_directory_without_the_sidecar_is_reused_unchecked(self) -> None:
        # The current contract: with no `ple_constants.json` beside the table
        # there is nothing to compare, and the size gate on the Swift side is
        # all that is left. Pinned so a change to it is deliberate.
        directory = self.install(sidecar=False)
        self.assertEqual(prepare.reusable_table_path(directory, self.constants),
                         directory / "ngram_table.bin")

    def test_a_missing_table_is_refused(self) -> None:
        directory = self.install()
        (directory / "ngram_table.bin").unlink()
        with self.assertRaises(SystemExit) as caught:
            prepare.reusable_table_path(directory, self.constants)
        self.assertIn("no such file", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
