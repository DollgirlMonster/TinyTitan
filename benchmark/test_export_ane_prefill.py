"""The ANE sidecar exporter's geometry and width rules.

Two things decide whether a sidecar is right, and both are pure functions of
the model's manifest and its weight index:

- **the geometry** (`geometry_for`) — what the Core ML graph is built for. A
  graph built for the wrong width or head split computes a *different*
  attention and produces fluent nonsense, so every deviation the graph cannot
  reproduce must be refused rather than approximated;
- **the width of each tensor** (`tensor_weight_bits`) — the manifest's slot is
  not authoritative. The dense Qwen 3.5 installs declare a 4-bit attention
  slot but store `k_proj`/`v_proj` at 8 bits, recorded as per-stem `quant`
  entries; reading those as nibbles is a documented failure mode.

These import the exporter, which imports coremltools, so they skip where that
is not installed (the CI python does not have it; `~/.venvs/coreml-py311` does):

    cd benchmark && ~/.venvs/coreml-py311/bin/python -m unittest \
        test_export_ane_prefill -v
"""
from __future__ import annotations

import io
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

try:
    import export_ane_prefill as exporter
    IMPORT_ERROR = ""
except Exception as exc:  # coremltools or numpy absent
    exporter = None
    IMPORT_ERROR = str(exc)


def arch(**overrides) -> dict:
    """The 35B-A3B row, which every supported family only varies from."""
    base = {
        "family": "qwen36", "hiddenSize": 2048, "numHeads": 16,
        "numKVHeads": 2, "numFullKVHeads": 2, "headDim": 256,
        "fullHeadDim": 256, "attentionScale": 0.0625, "attentionKEqV": False,
        "ropeNeoxSubdim": True, "slidingWindow": 0,
        "fullRopeTheta": 10_000_000, "partialRotaryFactor": 0.25,
        "numLayers": 40,
        "fullAttentionLayerMask": [2, 2, 2, 1] * 10,
    }
    base.update(overrides)
    return {"arch": base}


PREFIX = "language_model.model.layers."
ENTRIES = {f"{PREFIX}3.self_attn.q_proj.weight": {}}


@unittest.skipIf(exporter is None, f"exporter needs coremltools: {IMPORT_ERROR}")
class GeometryTests(unittest.TestCase):
    def test_reads_the_geometry_and_the_full_attention_layers(self):
        geom = exporter.geometry_for(arch(), ENTRIES)
        self.assertEqual(
            (geom.family, geom.hidden, geom.q_heads, geom.kv_heads,
             geom.head_dim, geom.rotary, geom.layers),
            ("qwen36", 2048, 16, 2, 256, 64, (3, 7, 11, 15, 19, 23, 27, 31, 35, 39)))

    def test_a_dense_shape_is_derived_not_assumed(self):
        # The 4B: hidden 2560, 16 q heads, 4 kv heads, 8 full-attention layers.
        geom = exporter.geometry_for(
            arch(hiddenSize=2560, numKVHeads=4, numFullKVHeads=4, numLayers=32,
                 fullAttentionLayerMask=[2, 2, 2, 1] * 8),
            {f"{PREFIX}3.self_attn.q_proj.weight": {}})
        self.assertEqual((geom.hidden, geom.q_heads, geom.kv_heads,
                          geom.q_dim, geom.kv_dim, len(geom.layers)),
                         (2560, 16, 4, 4096, 1024, 8))

    def test_the_prefix_is_discovered_from_the_index(self):
        # The 3.8 family spells it the other way round.
        entries = {"model.language_model.layers.3.self_attn.q_proj.weight": {}}
        geom = exporter.geometry_for(arch(family="qwen3_5_dense"), entries)
        self.assertEqual(geom.prefix, "model.language_model.layers.")

    def test_qwen38_is_refused_for_its_indexer_not_its_shape(self):
        with self.assertRaises(SystemExit) as caught:
            exporter.geometry_for(arch(family="qwen38flash"), ENTRIES)
        self.assertIn("2,051", str(caught.exception))

    def test_a_geometry_the_graph_cannot_reproduce_is_refused(self):
        for override, fragment in (
            ({"attentionKEqV": True}, "K and V separately"),
            ({"ropeNeoxSubdim": False}, "NeoX"),
            ({"slidingWindow": 4096}, "sliding-window"),
        ):
            with self.subTest(override=override):
                with self.assertRaises(SystemExit) as caught:
                    exporter.geometry_for(arch(**override), ENTRIES)
                self.assertIn(fragment, str(caught.exception))

    def test_a_model_with_no_full_attention_layer_is_refused(self):
        with self.assertRaises(SystemExit):
            exporter.geometry_for(
                arch(fullAttentionLayerMask=[2] * 40), ENTRIES)

    def test_an_unknown_attention_layout_is_refused(self):
        with self.assertRaises(SystemExit):
            exporter.geometry_for(arch(), {"something.else.weight": {}})

    def test_the_recorded_metadata_carries_what_the_runtime_validates(self):
        meta = exporter.geometry_for(arch(), ENTRIES).as_metadata()
        for key in ("family", "hiddenSize", "numHeads", "numKVHeads",
                    "headDim", "chunkTokens", "fullAttentionLayers"):
            self.assertIn(key, meta)
        self.assertEqual(meta["chunkTokens"], exporter.CHUNK)
        self.assertEqual(meta["family"], "qwen36")


@unittest.skipIf(exporter is None, f"exporter needs coremltools: {IMPORT_ERROR}")
class TensorWidthTests(unittest.TestCase):
    def test_a_per_tensor_override_beats_the_slot(self):
        # The dense installs' shape: a 4-bit slot, an 8-bit k_proj.
        manifest = {"quant": {"attention": {"weightBits": 4},
                              f"{PREFIX}3.self_attn.k_proj": {"weightBits": 8}}}
        self.assertEqual(
            exporter.tensor_weight_bits(
                manifest, f"{PREFIX}3.self_attn.k_proj.weight", 4), 8)
        self.assertEqual(
            exporter.tensor_weight_bits(
                manifest, f"{PREFIX}3.self_attn.q_proj.weight", 4), 4)

    def test_the_slot_is_the_fallback(self):
        manifest = {"quant": {"attention": {"weightBits": 8}}}
        self.assertEqual(
            exporter.tensor_weight_bits(
                manifest, f"{PREFIX}3.self_attn.k_proj.weight", 8), 8)


@unittest.skipIf(exporter is None, f"exporter needs coremltools: {IMPORT_ERROR}")
class LoadTensorTests(unittest.TestCase):
    def entry(self, rows, cols, size, dtype=0):
        return {"shape": (rows, cols, 0, 0), "size": size, "dtype": dtype,
                "offset": 0, "scale": (0, 2 * rows * (cols // 64)),
                "bias": (0, 2 * rows * (cols // 64))}

    def test_a_manifest_that_lies_about_its_width_is_refused(self):
        # 8-bit payload declared as 4-bit: 1,048,576 bytes for 512x2048.
        with self.assertRaises(SystemExit) as caught:
            exporter.load_tensor(io.BytesIO(b"\x00" * (1 << 21)),
                                 self.entry(512, 2048, 1 << 20),
                                 weight_bits=4, name="k_proj")
        self.assertIn("refusing to guess", str(caught.exception))

    def test_an_unsupported_width_is_refused(self):
        with self.assertRaises(SystemExit):
            exporter.load_tensor(io.BytesIO(b"\x00" * 32),
                                 self.entry(8, 8, 32), weight_bits=3,
                                 name="k_proj")


if __name__ == "__main__":
    unittest.main()
