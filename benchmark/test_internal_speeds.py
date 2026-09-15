"""The internal-speed record and its release comparison.

`tools/internal-speeds.py` writes one JSON record per release and diffs it
against a previous one; that diff is the release gate for engine speed. These
tests pin the two things that decide whether the gate is trustworthy:

- **which record it compares against.** Records are per model, and only a
  qwen36 install can carry an ANE sidecar, so the newest file on disk is not
  necessarily a comparable one. A 125B MoE's decode rate must never become the
  4B's baseline by being newest.
- **what a missing ANE number says.** "This model is not qwen36" is only true
  of a dense install; a qwen36 install that simply has no sidecar yet is a
  different situation and must not read alike.

They need no model, no built binary and no ANE sidecar.

Run from this directory, like the other benchmark tests:

    cd benchmark && python3 -m unittest test_internal_speeds -v
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_tool():
    """`tools/internal-speeds.py` is not importable by name (hyphen)."""
    spec = importlib.util.spec_from_file_location(
        "internal_speeds", ROOT / "tools" / "internal-speeds.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


internal_speeds = load_tool()


def record(model: str, prompt: str = internal_speeds.DEFAULT_PROMPT) -> dict:
    return {"model": {"path": model, "prompt": prompt},
            "quality": {"keyword_coverage": 0.5, "response_sha256": "abc"}}


class MissingAneReasonTests(unittest.TestCase):
    def test_qwen36_without_a_sidecar_is_not_called_another_family(self):
        reason = internal_speeds.missing_ane_reason(
            "models/qwen-agentworld_35B_A3B_4Bit", "qwen36")
        self.assertIn("qwen-agentworld_35B_A3B_4Bit", reason)
        self.assertIn("export_ane_prefill.py", reason)
        # The exporter *can* serve this model; only the sidecar is absent.
        self.assertNotIn("supports the qwen36 family only", reason)

    def test_dense_model_is_told_the_exporter_cannot_serve_it(self):
        reason = internal_speeds.missing_ane_reason(
            "models/qwen3.5_4B_4Bit", "qwen3_5_dense")
        self.assertIn("supports the qwen36 family only", reason)
        self.assertIn("qwen3_5_dense", reason)


class NewestBaselineTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.real_results = internal_speeds.RESULTS
        internal_speeds.RESULTS = self.dir
        self.addCleanup(setattr, internal_speeds, "RESULTS", self.real_results)

    def write(self, name: str, payload: dict) -> pathlib.Path:
        path = self.dir / name
        path.write_text(json.dumps(payload))
        return path

    def test_picks_the_newest_record_for_the_same_model_and_prompt(self):
        self.write("a-4b.json", record("models/qwen3.5_4B_4Bit"))
        newest = self.write("b-4b.json", record("models/qwen3.5_4B_4Bit"))
        # Newer, but a different model: never the 4B's baseline.
        self.write("c-moe.json", record("models/qwen-agentworld_35B_A3B_4Bit"))
        out = self.dir / "d-4b.json"

        self.assertEqual(internal_speeds.newest_baseline(
            out, "models/qwen3.5_4B_4Bit", internal_speeds.DEFAULT_PROMPT),
            str(newest))

    def test_the_record_being_written_is_never_its_own_baseline(self):
        path = self.write("only.json", record("models/qwen3.5_4B_4Bit"))
        self.assertIsNone(internal_speeds.newest_baseline(
            path, "models/qwen3.5_4B_4Bit", internal_speeds.DEFAULT_PROMPT))

    def test_a_different_prompt_is_not_comparable(self):
        self.write("other-prompt.json",
                   record("models/qwen3.5_4B_4Bit", "explain quicksort"))
        self.assertIsNone(internal_speeds.newest_baseline(
            self.dir / "new.json", "models/qwen3.5_4B_4Bit",
            internal_speeds.DEFAULT_PROMPT))

    def test_no_previous_record_at_all(self):
        self.assertIsNone(internal_speeds.newest_baseline(
            self.dir / "new.json", "models/qwen3.5_4B_4Bit",
            internal_speeds.DEFAULT_PROMPT))

    def test_an_unreadable_record_is_skipped_not_fatal(self):
        (self.dir / "broken.json").write_text("{not json")
        good = self.write("good.json", record("models/qwen3.5_4B_4Bit"))
        self.assertEqual(internal_speeds.newest_baseline(
            self.dir / "new.json", "models/qwen3.5_4B_4Bit",
            internal_speeds.DEFAULT_PROMPT), str(good))


class ModelFamilyTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.real_root = internal_speeds.ROOT
        internal_speeds.ROOT = self.dir
        self.addCleanup(setattr, internal_speeds, "ROOT", self.real_root)

    def test_reads_the_family_from_the_manifest(self):
        model = self.dir / "models" / "m"
        model.mkdir(parents=True)
        (model / "manifest.json").write_text(
            json.dumps({"arch": {"family": "qwen36"}}))
        self.assertEqual(internal_speeds.model_family("models/m"), "qwen36")

    def test_a_missing_or_malformed_manifest_is_none(self):
        model = self.dir / "models" / "m"
        model.mkdir(parents=True)
        self.assertIsNone(internal_speeds.model_family("models/m"))
        (model / "manifest.json").write_text("{not json")
        self.assertIsNone(internal_speeds.model_family("models/m"))


class CompareTests(unittest.TestCase):
    def candidate(self, **overrides) -> dict:
        base = {
            "generation": {
                "prefill_tokens_per_second": 100.0,
                "decode_tokens_per_second": 50.0,
                "effective_decode_gbps": 60.0,
                "ttft_seconds": 1.0,
                "decode_seconds": 5.0,
                "total_seconds": 6.0,
            },
            "gpu": {"qkv_gemv_gbps": 70.0, "routed_moe_gbps": 44.0,
                    "gdn_inproj_gbps": 77.0},
            "cpu": {"best_gbps": 43.0},
            "quality": {"keyword_coverage": 0.5, "response_sha256": "abc"},
        }
        for dotted, value in overrides.items():
            section, field = dotted.split("__")
            base[section][field] = value
        return base

    def test_an_identical_record_passes(self):
        self.assertTrue(internal_speeds.compare(
            self.candidate(), self.candidate(), 10.0))

    def test_a_small_dip_stays_within_the_threshold(self):
        self.assertTrue(internal_speeds.compare(
            self.candidate(),
            self.candidate(generation__decode_tokens_per_second=46.0), 10.0))

    def test_a_bandwidth_regression_fails(self):
        self.assertFalse(internal_speeds.compare(
            self.candidate(),
            self.candidate(gpu__routed_moe_gbps=30.0), 10.0))

    def test_a_latency_regression_fails(self):
        self.assertFalse(internal_speeds.compare(
            self.candidate(),
            self.candidate(generation__ttft_seconds=1.5), 10.0))

    def test_a_quality_drop_fails(self):
        self.assertFalse(internal_speeds.compare(
            self.candidate(),
            self.candidate(quality__keyword_coverage=0.2), 10.0))


if __name__ == "__main__":
    unittest.main()
