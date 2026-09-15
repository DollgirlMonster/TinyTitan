import Foundation
import Metal
import Testing
@testable import TinyTitan

/// A sidecar metadata geometry block, as `tools/export_ane_prefill.py` writes
/// it. The defaults are the 35B-A3B row; tests that use another shape pass it.
private func sidecarGeometry(family: String = "qwen36", hidden: Int = 2048,
                             numHeads: Int = 16, numKVHeads: Int = 2,
                             headDim: Int = 256, chunkTokens: Int = 4096,
                             layers: [Int] = [3]) -> [String: Any] {
    ["family": family, "hiddenSize": hidden, "numHeads": numHeads,
     "numKVHeads": numKVHeads, "headDim": headDim,
     "chunkTokens": chunkTokens, "fullAttentionLayers": layers]
}

/// A model's full-attention mask: 1 at `layers`, 2 (linear) elsewhere.
private func fullMask(layers: [Int], count: Int = 40) -> [UInt8] {
    var mask = [UInt8](repeating: 2, count: count)
    for layer in layers where layer >= 0 && layer < count { mask[layer] = 1 }
    return mask
}

@Suite struct ANEPrefillAttentionTests {
    @Test func environmentSwitchDefaultsOnAndFailsClosed() throws {
        // Default-on since the deferred-pin A/Bs qualified it on an idle
        // machine: 3.14x end to end at 4-bit, 1.91x at 8-bit. A model with no
        // sidecar still loads -- the runner degrades to the GPU unless the
        // setting was named explicitly.
        #expect(try RuntimePrefillANE.environmentValue([:]) == .on)
        #expect(!RuntimePrefillANE.wasRequestedExplicitly([:]))
        #expect(RuntimePrefillANE.wasRequestedExplicitly(
            ["TINYTITAN_PREFILL_ANE": "off"]))
        #expect(try RuntimePrefillANE.environmentValue(
            ["TINYTITAN_PREFILL_ANE": "off"]) == .off)
        #expect(try RuntimePrefillANE.environmentValue(
            ["TINYTITAN_PREFILL_ANE": "on"]) == .on)
        #expect(throws: PrefillError.self) {
            try RuntimePrefillANE.environmentValue(["TINYTITAN_PREFILL_ANE": "1"])
        }
        #expect(throws: PrefillError.self) {
            try RuntimePrefillANE.environmentValue(["TINYTITAN_PREFILL_ANE": ""])
        }
    }

    @Test func missingSidecarFailsClosedWithExportHint() throws {
        let ctx = try MetalContext()
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: PrefillError.self) {
            _ = try ANEPrefillAttention(modelDirectory: empty,
                                        device: ctx.device,
                                        hiddenSize: 2048, kvDim: 512,
                                        weightsSha256: nil,
                                        family: .qwen36,
                                        fullAttentionLayerMask: fullMask(layers: [3]),
                                        sparseIndexer: .none,
                                        configChunkTokens: 4096)
        }
    }

    @Test func sidecarExportedFromDifferentWeightsIsRejected() throws {
        let ctx = try MetalContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        let sidecar = dir.appendingPathComponent("ane_prefill")
        try FileManager.default.createDirectory(
            at: sidecar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta: [String: Any] = [
            "version": 1, "family": "qwen36", "chunkTokens": 4096,
            "histories": [0], "layers": [3],
            "geometry": sidecarGeometry(),
            "weightsSha256": String(repeating: "a", count: 64),
            "aneCompileVerified": true,
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: sidecar.appendingPathComponent("ane_prefill.json"))
        // Matching digest loads; a different one must fail closed rather than
        // computing plausible-looking attention from the wrong weights.
        _ = try ANEPrefillAttention(modelDirectory: dir, device: ctx.device,
                                    hiddenSize: 2048, kvDim: 512,
                                    weightsSha256: String(repeating: "A", count: 64),
                                    family: .qwen36,
                                    fullAttentionLayerMask: fullMask(layers: [3]),
                                        sparseIndexer: .none,
                                        configChunkTokens: 4096)
        #expect(throws: PrefillError.self) {
            _ = try ANEPrefillAttention(modelDirectory: dir, device: ctx.device,
                                        hiddenSize: 2048, kvDim: 512,
                                        weightsSha256: String(repeating: "b", count: 64),
                                        family: .qwen36,
                                        fullAttentionLayerMask: fullMask(layers: [3]),
                                        sparseIndexer: .none,
                                        configChunkTokens: 4096)
        }
    }

    /// A sidecar is built for one geometry. Running one that belongs to another
    /// model -- another width, head split, family or layer set -- computes a
    /// *different* attention and produces fluent output nothing flags, so each
    /// disagreement must be refused and send the runner to the GPU path.
    @Test func sidecarForAnotherGeometryIsRejected() throws {
        let ctx = try MetalContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        let sidecar = dir.appendingPathComponent("ane_prefill")
        try FileManager.default.createDirectory(
            at: sidecar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let metaURL = sidecar.appendingPathComponent("ane_prefill.json")
        func write(_ geometry: [String: Any], layers: [Int] = [3]) throws {
            let meta: [String: Any] = [
                "version": 1, "family": "qwen36", "chunkTokens": 4096,
                "histories": [0], "layers": layers, "geometry": geometry,
                "aneCompileVerified": true,
            ]
            try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
        }
        func load() throws {
            _ = try ANEPrefillAttention(modelDirectory: dir, device: ctx.device,
                                        hiddenSize: 2048, kvDim: 512,
                                        weightsSha256: nil,
                                        family: .qwen36,
                                        fullAttentionLayerMask: fullMask(layers: [3, 7]),
                                        sparseIndexer: .none,
                                        configChunkTokens: 4096)
        }
        // No geometry block at all (a sidecar from the qwen36-only exporter).
        let legacy: [String: Any] = [
            "version": 1, "family": "qwen36", "chunkTokens": 4096,
            "histories": [0], "layers": [3], "aneCompileVerified": true,
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: metaURL)
        #expect(throws: PrefillError.self) { try load() }

        // Another hidden width (the 4B's 2560 against this 2048 model).
        try write(sidecarGeometry(hidden: 2560))
        #expect(throws: PrefillError.self) { try load() }

        // Another head split: 4 kv heads x 256 is the 4B's kvDim, not 512.
        try write(sidecarGeometry(numKVHeads: 4))
        #expect(throws: PrefillError.self) { try load() }

        // Another family's sidecar.
        try write(sidecarGeometry(family: "qwen3_5_dense"))
        #expect(throws: PrefillError.self) { try load() }

        // A layer that is not full attention in this model.
        try write(sidecarGeometry(), layers: [4])
        #expect(throws: PrefillError.self) { try load() }

        // The matching geometry loads.
        try write(sidecarGeometry())
        try load()
    }

    /// Qwen 3.8: a sparse-indexed family cannot be served by a dense sidecar,
    /// and the arithmetic says there is no window where it could — the smallest
    /// chunk the ANE accepts is a full 4,096 tokens, already past the 2,051
    /// visible keys where dense attention matches the indexer's selection.
    ///
    /// The sidecar and the model match exactly here, so the refusal can only
    /// come from the indexer; the same sidecar loads with `.none`.
    @Test func aSparseIndexedModelIsRefusedEvenWithAMatchingSidecar() throws {
        let ctx = try MetalContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        let sidecar = dir.appendingPathComponent("ane_prefill")
        try FileManager.default.createDirectory(
            at: sidecar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta: [String: Any] = [
            "version": 1, "family": "qwen36", "chunkTokens": 4096,
            "histories": [0], "layers": [3],
            "geometry": sidecarGeometry(), "aneCompileVerified": true,
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: sidecar.appendingPathComponent("ane_prefill.json"))

        let indexer = SparseIndexerConfig(numHeads: 24, numKVHeads: 2,
                                          headDim: 256, budget: 2048,
                                          compressRatio: 4)
        #expect(QSAExactness(indexer).maximumExactVisibleKeys == 2_051)
        do {
            _ = try ANEPrefillAttention(
                modelDirectory: dir, device: ctx.device,
                hiddenSize: 2048, kvDim: 512, weightsSha256: nil,
                family: .qwen36, fullAttentionLayerMask: fullMask(layers: [3]),
                sparseIndexer: indexer,
                                        configChunkTokens: 4096)
            Issue.record("a sparse-indexed model was allowed to load a sidecar")
        } catch {
            // The indexer's guard, not one of the geometry guards.
            #expect("\(error)".contains("sparse-indexed"))
            #expect("\(error)".contains("\(QSAExactness(indexer).maximumExactVisibleKeys)"))
        }

        // Same sidecar, no indexer: it loads.
        _ = try ANEPrefillAttention(
            modelDirectory: dir, device: ctx.device,
            hiddenSize: 2048, kvDim: 512, weightsSha256: nil,
            family: .qwen36, fullAttentionLayerMask: fullMask(layers: [3]),
            sparseIndexer: .none,
                                        configChunkTokens: 4096)
    }

    /// Eligibility and shadow continuity, using a synthetic sidecar manifest
    /// so no Core ML package or model weights are involved.
    @Test func chunkEligibilityEnforcesAlignmentCoverageAndContinuity() throws {
        let ctx = try MetalContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        let sidecar = dir.appendingPathComponent("ane_prefill")
        try FileManager.default.createDirectory(
            at: sidecar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta: [String: Any] = [
            "version": 1, "family": "qwen36", "chunkTokens": 4096,
            "histories": [0, 4096], "layers": [3, 7], "aneCompileVerified": true,
            "geometry": sidecarGeometry(layers: [3, 7]),
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: sidecar.appendingPathComponent("ane_prefill.json"))
        let ane = try ANEPrefillAttention(modelDirectory: dir,
                                          device: ctx.device,
                                          hiddenSize: 2048, kvDim: 512,
                                          weightsSha256: nil,
                                          family: .qwen36,
                                          fullAttentionLayerMask: fullMask(layers: [3, 7]),
                                        sparseIndexer: .none,
                                        configChunkTokens: 4096)
        #expect(ane.maxPromptTokens == 8192)
        #expect(ane.coveredLayers == Set([3, 7]))

        // Config chunk mismatch, misaligned start, uncovered history: all out.
        #expect(!ane.eligibleChunk(startPosition: 0, tokenCount: 512,
                                   configChunkTokens: 1024))
        #expect(!ane.eligibleChunk(startPosition: 100, tokenCount: 4096,
                                   configChunkTokens: 4096))
        #expect(!ane.eligibleChunk(startPosition: 8192, tokenCount: 100,
                                   configChunkTokens: 4096))

        // A short single-chunk prompt stays on the GPU (padding waste).
        #expect(!ane.eligibleChunk(startPosition: 0, tokenCount: 512,
                                   configChunkTokens: 4096))
        // Fresh full-chunk prompt resets the shadow and is eligible.
        #expect(ane.eligibleChunk(startPosition: 0, tokenCount: 4096,
                                  configChunkTokens: 4096))
        // Without finishChunk, a follow-up chunk must fall back (continuity).
        #expect(!ane.eligibleChunk(startPosition: 4096, tokenCount: 100,
                                   configChunkTokens: 4096))
        ane.finishChunk(startPosition: 0, tokenCount: 4096)
        #expect(ane.shadowTokens == 4096)
        #expect(ane.eligibleChunk(startPosition: 4096, tokenCount: 100,
                                  configChunkTokens: 4096))
        // A partial final chunk clears the shadow: nothing may resume it.
        ane.finishChunk(startPosition: 4096, tokenCount: 100)
        #expect(ane.shadowTokens == 0)
    }

    /// Issue #7: an exporter that did not watch the ANE compile can write a
    /// sidecar the ANE refuses, which Core ML then runs on the CPU at ~38x the
    /// GPU prefill cost while exiting 0. The runtime must not trust it.
    @Test func sidecarWithoutVerifiedANECompilationIsRejected() throws {
        let ctx = try MetalContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        let sidecar = dir.appendingPathComponent("ane_prefill")
        try FileManager.default.createDirectory(
            at: sidecar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let metaURL = sidecar.appendingPathComponent("ane_prefill.json")
        func write(_ meta: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
        }
        let base: [String: Any] = [
            "version": 1, "family": "qwen36", "chunkTokens": 4096,
            "histories": [0], "layers": [3],
            "geometry": sidecarGeometry(),
        ]
        func load() throws {
            _ = try ANEPrefillAttention(modelDirectory: dir, device: ctx.device,
                                        hiddenSize: 2048, kvDim: 512,
                                        weightsSha256: nil,
                                        family: .qwen36,
                                        fullAttentionLayerMask: fullMask(layers: [3]),
                                        sparseIndexer: .none,
                                        configChunkTokens: 4096)
        }
        // Missing flag (any sidecar written before this check): refused.
        try write(base)
        #expect(throws: PrefillError.self) { try load() }
        // Explicitly false (an export that saw the ANE refuse): refused.
        var failed = base
        failed["aneCompileVerified"] = false
        try write(failed)
        #expect(throws: PrefillError.self) { try load() }
        // Verified: loads.
        var verified = base
        verified["aneCompileVerified"] = true
        try write(verified)
        try load()
    }

    /// A model may carry one sidecar per chunk width, because the width that
    /// wins depends on the prompt: 4,096 for long ones, a smaller chunk to
    /// reach the band under it at all.
    @Test func theConfiguredChunkSelectsTheSidecarDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fallback = dir.appendingPathComponent("ane_prefill")
        let narrow = dir.appendingPathComponent("ane_prefill-1024")
        try FileManager.default.createDirectory(at: fallback,
                                                withIntermediateDirectories: true)

        // Nothing chunk-specific: the default directory is used.
        #expect(ANEPrefillAttention.sidecarDirectory(
            modelDirectory: dir, configChunkTokens: 1024).lastPathComponent
            == "ane_prefill")

        // An empty directory is not a sidecar; the metadata file decides.
        try FileManager.default.createDirectory(at: narrow,
                                                withIntermediateDirectories: true)
        #expect(ANEPrefillAttention.sidecarDirectory(
            modelDirectory: dir, configChunkTokens: 1024).lastPathComponent
            == "ane_prefill")

        try JSONSerialization.data(withJSONObject: ["version": 1])
            .write(to: narrow.appendingPathComponent("ane_prefill.json"))
        #expect(ANEPrefillAttention.sidecarDirectory(
            modelDirectory: dir, configChunkTokens: 1024).lastPathComponent
            == "ane_prefill-1024")
        // A different configured chunk still falls back to the default.
        #expect(ANEPrefillAttention.sidecarDirectory(
            modelDirectory: dir, configChunkTokens: 4096).lastPathComponent
            == "ane_prefill")
    }

    /// The graph's shapes are fixed by its chunk, so a sidecar built for
    /// another width cannot be fed — it is refused, not approximated.
    @Test func aSidecarBuiltForAnotherChunkIsRefused() throws {
        let ctx = try MetalContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        let sidecar = dir.appendingPathComponent("ane_prefill")
        try FileManager.default.createDirectory(at: sidecar,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta: [String: Any] = [
            "version": 1, "family": "qwen36", "chunkTokens": 1024,
            "histories": [0], "layers": [3],
            "geometry": sidecarGeometry(chunkTokens: 1024),
            "aneCompileVerified": true,
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: sidecar.appendingPathComponent("ane_prefill.json"))
        do {
            _ = try ANEPrefillAttention(
                modelDirectory: dir, device: ctx.device,
                hiddenSize: 2048, kvDim: 512, weightsSha256: nil,
                family: .qwen36, fullAttentionLayerMask: fullMask(layers: [3]),
                sparseIndexer: .none, configChunkTokens: 4096)
            Issue.record("a 1,024-token sidecar loaded under a 4,096 chunk")
        } catch {
            // Names the fix, so the operator does not have to guess the width.
            #expect("\(error)".contains("--chunk 4096"))
        }
    }

    @Test func shadowAppendSkipsPartialChunksAndStoresFullOnes() throws {
        let ctx = try MetalContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-test-\(UUID().uuidString)")
        let sidecar = dir.appendingPathComponent("ane_prefill")
        try FileManager.default.createDirectory(
            at: sidecar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta: [String: Any] = [
            "version": 1, "family": "qwen36", "chunkTokens": 8,
            "histories": [0, 8], "layers": [3], "aneCompileVerified": true,
            "geometry": sidecarGeometry(hidden: 16, numHeads: 1, numKVHeads: 1,
                                        headDim: 4, chunkTokens: 8, layers: [3]),
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: sidecar.appendingPathComponent("ane_prefill.json"))
        let ane = try ANEPrefillAttention(modelDirectory: dir,
                                          device: ctx.device,
                                          hiddenSize: 16, kvDim: 4,
                                          weightsSha256: nil,
                                          family: .qwen36,
                                          fullAttentionLayerMask: fullMask(layers: [3], count: 8),
                                          sparseIndexer: .none,
                                          configChunkTokens: 8)
        let kPtr = ane.stagingK.contents().bindMemory(to: Float16.self,
                                                      capacity: 8 * 4)
        for index in 0..<(8 * 4) { kPtr[index] = Float16(index) }
        // Partial chunk: never appended (it is always the last chunk).
        ane.appendShadow(layer: 3, startPosition: 0, tokenCount: 4)
        ane.finishChunk(startPosition: 0, tokenCount: 4)
        #expect(ane.shadowTokens == 0)
        // Full chunk: appended and visible after finishChunk.
        ane.appendShadow(layer: 3, startPosition: 0, tokenCount: 8)
        ane.finishChunk(startPosition: 0, tokenCount: 8)
        #expect(ane.shadowTokens == 8)
    }
}
