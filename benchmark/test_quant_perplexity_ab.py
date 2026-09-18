"""The paired arithmetic the perplexity A/B's conclusion rests on.

`quant_perplexity_ab.py` turns two per-token NLL vectors into a mean, a
standard error and a t. A sign error there would read as a real precision
effect, so the arithmetic is pinned here. It also pins the parsing of the
bench's two output lines and the default-corpus rule, since a mis-parsed mean
or a corpus that silently changed would be as wrong as a bad statistic.

No model, no built binary.

    cd benchmark && python3 -m unittest test_quant_perplexity_ab -v
"""
from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ab = _load("quant_perplexity_ab", "benchmark/quant_perplexity_ab.py")


class PairedTests(unittest.TestCase):
    def test_identical_vectors_differ_by_nothing(self):
        mean, stderr, t = ab.paired([1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
        self.assertEqual(mean, 0.0)
        self.assertEqual(stderr, 0.0)
        self.assertEqual(t, float("inf"))

    def test_a_constant_offset_has_no_standard_error(self):
        mean, stderr, t = ab.paired([1.0, 2.0, 3.0], [0.0, 1.0, 2.0])
        self.assertAlmostEqual(mean, 1.0)
        self.assertAlmostEqual(stderr, 0.0)
        self.assertEqual(t, float("inf"))

    def test_an_inconsistent_offset_is_divided_by_its_standard_error(self):
        # differences 1, 0, 1: mean 2/3, stdev sqrt(1/3), se stdev/sqrt(3).
        mean, stderr, t = ab.paired([1.0, 2.0, 3.0], [0.0, 2.0, 2.0])
        self.assertAlmostEqual(mean, 2.0 / 3.0)
        self.assertAlmostEqual(stderr, (1.0 / 3.0) ** 0.5 / 3 ** 0.5)
        self.assertAlmostEqual(t, mean / stderr)

    def test_a_single_position_is_a_mean_with_no_error(self):
        mean, stderr, t = ab.paired([2.0], [1.0])
        self.assertEqual(mean, 1.0)
        self.assertEqual(stderr, 0.0)
        self.assertEqual(t, float("inf"))


class ParsingTests(unittest.TestCase):
    SAMPLE = ("models/qwen3.5_4B_4Bit: 1024 tokens scored, threads 8, "
              "token hash 0123456789abcdef\n"
              "mean nll 2.123456  perplexity 8.365432  seconds 70.1  (14.6 tok/s)\n")

    def test_the_summary_line_is_read(self):
        match = ab.SUMMARY.search(self.SAMPLE)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "2.123456")
        self.assertEqual(match.group(2), "8.365432")
        self.assertEqual(match.group(3), "70.1")

    def test_the_token_hash_is_read(self):
        match = ab.HEADER.search(self.SAMPLE)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "0123456789abcdef")


class CorpusTests(unittest.TestCase):
    def test_a_named_text_is_the_whole_corpus(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "held-out.txt"
            path.write_text("one two three", encoding="utf-8")
            text, used = ab.corpus_text(str(path))
            self.assertEqual(text, "one two three")
            self.assertEqual(used, [str(path)])

    def test_the_default_corpus_is_the_repository_documentation(self):
        text, used = ab.corpus_text(None)
        self.assertTrue(text)
        self.assertTrue(used)
        for relative in used:
            self.assertTrue((ROOT / relative).exists(), relative)


if __name__ == "__main__":
    unittest.main()
