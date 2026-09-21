import Darwin
import Testing
@testable import TinyTitan

/// One profile per (model, width), resolved family -> table -> environment.
@Suite struct ModelProfileTests {
    static let shipped: [(String, ModelFamily)] = [
        ("qwen3.6-35b-a3b", .qwen36), ("ornith-1.5-35b-a3b", .qwen36),
        ("qwen-agentworld", .qwen36), ("kat-coder-v2.5", .qwen36),
        ("qwen3.8-flash-next", .qwen38flash),
    ]

    @Test func everyShippedInstallHasItsOwnRow() {
        for (id, family) in Self.shipped {
            for bits in [4, 8] {
                let p = ModelProfile.resolve(modelID: id, family: family, weightBits: bits, environment: [:])
                #expect(p.isTabled, "\(id) \(bits)-bit falls back to its family")
                #expect(p.key == ModelProfile.Key(id, bits))
            }
        }
        #expect(ModelProfile.table.count == 10)
    }

    @Test func modelsSharingAFamilyResolveIndependently() {
        // Same family, different keys: editing one row cannot move the other.
        let a = ModelProfile.resolve(modelID: "qwen-agentworld", family: .qwen36, weightBits: 4, environment: [:])
        let q = ModelProfile.resolve(modelID: "qwen3.6-35b-a3b", family: .qwen36, weightBits: 4, environment: [:])
        #expect(a.key != q.key)
        #expect(ModelProfile.table[a.key] != nil && ModelProfile.table[q.key] != nil)
    }

    @Test func tabledValuesMatchWhatWasMeasured() {
        let q38 = ModelProfile.resolve(modelID: "qwen3.8-flash-next", family: .qwen38flash, weightBits: 4, environment: [:])
        #expect(q38.expertCacheBudgetBytes == 12 << 30)
        // Depth 1 since 2026-09-21: the ring was re-measured and wins at both
        // prompt lengths now (7-token +15.7%, ~500-token +14.6%), which
        // supersedes the 2026-09-05 decision to leave it off.
        #expect(q38.prefetchDepth == 1)
        #expect(q38.keepExpertCacheWired)
        #expect(!q38.earlyExpertHits)
        let q38b = ModelProfile.resolve(modelID: "qwen3.8-flash-next", family: .qwen38flash, weightBits: 8, environment: [:])
        #expect(q38b.expertCacheBudgetBytes == Int(9.5 * Double(1 << 30)) && q38b.prefetchIOTier == 0)
        // Inferred from the 4-bit A/B (see the 8-bit row comment), not measured.
        #expect(q38b.prefetchDepth == 1)
        #expect(q38.sampling.temperature == 1.0 && q38.sampling.topP == 0.95)
        #expect(!q38.hcFused && !q38.qsaGPUSelect)
        let q36 = ModelProfile.resolve(modelID: "qwen3.6-35b-a3b", family: .qwen36, weightBits: 8, environment: [:])
        #expect(q36.expertCacheBudgetBytes == 12 << 30)
        #expect(q36.keepExpertCacheWired)
        #expect(!q36.earlyExpertHits)
        let q36four = ModelProfile.resolve(modelID: "qwen3.6-35b-a3b", family: .qwen36, weightBits: 4, environment: [:])
        #expect(q36four.expertCacheBudgetBytes == 10 << 30)
        #expect(q36.prefetchDepth == 1)
        #expect(q36.prefillChunkTokens == 4_096)
        #expect(q36.sampling == GenerationDefaults.house)
    }

    @Test func samplingRowsFollowTheirSeries() {
        let qwen36Series = GenerationDefaults.Sampling(temperature: 0.6, topK: GenerationDefaults.topK, topP: 0.95)
        let qwen38Series = GenerationDefaults.Sampling(temperature: 1.0, topK: GenerationDefaults.topK, topP: 0.95)
        let expected: [(String, ModelFamily, GenerationDefaults.Sampling)] = [
            ("qwen3.6-35b-a3b", .qwen36, qwen36Series),
            ("qwen-agentworld", .qwen36, qwen36Series),
            // A fine-tune does not inherit its base's sampling: KAT-Coder's own
            // generation_config.json asks for 1.0, so its rows must not be
            // swept along by the 0.6 the rest of the qwen36 series uses.
            ("kat-coder-v2.5", .qwen36, qwen38Series),
            ("qwen3.8-flash-next", .qwen38flash, qwen38Series),
            // Not a Qwen-named series: it keeps the house values until its own
            // card is checked.
            ("ornith-1.5-35b-a3b", .qwen36, GenerationDefaults.house),
        ]
        for (id, family, sampling) in expected {
            for bits in [4, 8] {
                let p = ModelProfile.resolve(modelID: id, family: family, weightBits: bits, environment: [:])
                #expect(p.sampling == sampling, "\(id) \(bits)-bit")
            }
        }
    }

    @Test func unknownModelFallsBackToItsFamily() {
        let p = ModelProfile.resolve(modelID: "qwen3.6-35b-a3b-mtp-4bit", family: .qwen36MTP, weightBits: 4, environment: [:])
        #expect(!p.isTabled)
        let f = RuntimeConfiguration.decodeTuning(family: .qwen36MTP, weightBits: 4)
        #expect(p.expertCacheBudgetBytes == f.expertCacheBudgetBytes)
        #expect(p.prefetchDepth == f.prefetchDepth)
        #expect(p.prefillChunkTokens == nil)
        #expect(p.sampling == GenerationDefaults.forFamily(.qwen36MTP))
    }

    @Test func environmentOverridesTheTable() {
        let env = ["TINYTITAN_ROUTER_TOPK_SIMD": "0", "TINYTITAN_HC_FUSED": "1", "TINYTITAN_PREFETCH_IO_TIER": "throttle",
                   "TINYTITAN_PREDICTIVE_PREFETCH": "1", "TINYTITAN_PREFETCH_TOP_M": "3",
                   "TINYTITAN_QSA_GPU_SELECT": "verify"]
        let p = ModelProfile.resolve(modelID: "qwen3.6-35b-a3b", family: .qwen36, weightBits: 4, environment: env)
        #expect(!p.routerTopKSimd)
        #expect(p.hcFused)
        #expect(p.qsaGPUSelect)
        #expect(p.prefetchDepth == 3)
        #expect(p.prefetchIOTier == IOPOL_THROTTLE)
        let off = ModelProfile.resolve(modelID: "qwen3.8-flash-next", family: .qwen38flash, weightBits: 4,
                                       environment: ["TINYTITAN_PREDICTIVE_PREFETCH": "0"])
        #expect(off.prefetchDepth == 0)
        let wired = ModelProfile.resolve(modelID: "qwen3.6-35b-a3b", family: .qwen36, weightBits: 4,
                                         environment: ["TINYTITAN_KEEP_WIRED": "1"])
        #expect(wired.keepExpertCacheWired)
        let early = ModelProfile.resolve(modelID: "qwen3.8-flash-next", family: .qwen38flash,
                                         weightBits: 4, environment: ["TINYTITAN_EARLY_HITS": "1"])
        #expect(early.earlyExpertHits)
    }

    @Test func keepWiredTriStateReadsOnlyZeroAndOne() {
        #expect(ExpertCacheWiring.override(environment: [:]) == nil, "unset names no override")
        #expect(ExpertCacheWiring.override(environment: ["TINYTITAN_KEEP_WIRED": "1"]) == true)
        #expect(ExpertCacheWiring.override(environment: ["TINYTITAN_KEEP_WIRED": "0"]) == false)
        #expect(ExpertCacheWiring.override(environment: ["TINYTITAN_KEEP_WIRED": "true"]) == nil,
                "only 0 and 1 name an override; anything else falls back to the row")
        #expect(ExpertCacheWiring.override(environment: ["TINYTITAN_KEEP_WIRED": ""]) == nil)
    }

    @Test func keepWiredOverrideWorksInBothDirections() {
        // Every table row that streams experts wires the cache, so before this
        // `TINYTITAN_KEEP_WIRED=0` was a no-op and the 12 GiB cache could not be
        // paged out on a 24 GB Mac (TT-008).
        let rowWires = ModelProfile.resolve(modelID: "qwen3.8-flash-next", family: .qwen38flash,
                                            weightBits: 4, environment: [:])
        #expect(rowWires.keepExpertCacheWired, "the row wires it by default")
        let forcedOff = ModelProfile.resolve(modelID: "qwen3.8-flash-next", family: .qwen38flash,
                                             weightBits: 4, environment: ["TINYTITAN_KEEP_WIRED": "0"])
        #expect(!forcedOff.keepExpertCacheWired, "0 must beat a row that wires it")
        let forcedOn = ModelProfile.resolve(modelID: "qwen3.5-4b", family: .qwen35Dense,
                                            weightBits: 4, environment: ["TINYTITAN_KEEP_WIRED": "1"])
        #expect(forcedOn.keepExpertCacheWired, "1 must beat a row that does not")
        let rowLeavesItOff = ModelProfile.resolve(modelID: "qwen3.5-4b", family: .qwen35Dense,
                                                  weightBits: 4, environment: [:])
        #expect(!rowLeavesItOff.keepExpertCacheWired)
        let unrecognised = ModelProfile.resolve(modelID: "qwen3.8-flash-next", family: .qwen38flash,
                                                weightBits: 4, environment: ["TINYTITAN_KEEP_WIRED": "yes"])
        #expect(unrecognised.keepExpertCacheWired, "an unrecognised value is not an override")
    }

    @Test func summaryNamesTheKeyAndEveryKnob() {
        let p = ModelProfile.resolve(modelID: "qwen-agentworld", family: .qwen36, weightBits: 8, environment: [:])
        for needle in ["model=qwen-agentworld", "bits=8", "tabled", "budget=", "prefetch=1",
                       "chunk=4096", "topk_simd=true", "hc_fused=false", "keep_wired=true"] {
            #expect(p.summary.contains(needle), Comment(rawValue: needle))
        }
    }
}
