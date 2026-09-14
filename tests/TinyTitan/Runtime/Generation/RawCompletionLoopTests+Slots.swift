import Testing
import Foundation
import Metal
@testable import TinyTitan

/// `runRawCompletion(slot:)` must carry the slot to the producer and keep the
/// chunked prefill fast path for slot 0 only: chunked prefill writes slot 0's
/// KV region, so a batched sequence prefills through the slot-aware decode step.
extension RawCompletionLoopTests {

    /// Records which produce overload the loop reached, and with which slot.
    final class SlotRecordingProducer: LogitProducer, ChunkedPrefillRunner,
                                       @unchecked Sendable {
        let vocabSize: Int
        private let nextToken: Int32
        private(set) var slotCalls: [Int] = []
        private(set) var legacyProduceCalls = 0
        private(set) var chunkedCalls = 0

        init(vocabSize: Int, nextToken: Int32) {
            self.vocabSize = vocabSize
            self.nextToken = nextToken
        }

        func reset() {
            slotCalls.removeAll()
            legacyProduceCalls = 0
            chunkedCalls = 0
        }

        func produce(token: Int32, position: Int, into logits: MTLBuffer) async throws {
            legacyProduceCalls += 1
            write(into: logits)
        }

        func produce(token: Int32, position: Int, slot: Int,
                     into logits: MTLBuffer) async throws {
            slotCalls.append(slot)
            write(into: logits)
        }

        func prefillChunked(tokens: ArraySlice<Int32>,
                            startPosition: Int,
                            outputMode: PrefillOutputMode,
                            config: PrefillRuntimeConfig,
                            into logits: MTLBuffer,
                            onProgress: (Int) -> Void) async throws -> PrefillResult {
            chunkedCalls += 1
            write(into: logits)
            onProgress(tokens.count)
            return PrefillResult(newPosition: startPosition + tokens.count,
                                 seed: .logitsWritten)
        }

        private func write(into logits: MTLBuffer) {
            let ptr = logits.contents().bindMemory(to: Float16.self, capacity: vocabSize)
            for i in 0..<vocabSize { ptr[i] = Float16(-30) }
            ptr[Int(nextToken)] = Float16(30)
        }
    }

    @Test func nonZeroSlotPrefillsThroughTheSlotAwareDecodeStep() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load(from: ChatMLTemplateTests.fixtureFolder())
        let tokenA = tokenizer.encode("a", addBOS: false).first!
        let promptIDs = tokenizer.encode("go", addBOS: true)
        let producer = SlotRecordingProducer(vocabSize: tokenizer.vocabSize,
                                             nextToken: tokenA)
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)

        let result = try await runRawCompletion(
            producer: producer,
            tokenizer: tokenizer,
            promptIds: promptIDs,
            config: GenerationConfig(maxNewTokens: 2, temperature: 0),
            context: context,
            scratch: scratch,
            prefillConfig: .production(chunkTokens: 32),
            slot: 2) { _ in }

        #expect(result.newTokens == 2)
        #expect(producer.chunkedCalls == 0,
                "slot 2 must not use slot-0 chunked prefill")
        #expect(producer.legacyProduceCalls == 0,
                "the slot-aware overload must be the one reached")
        // The prompt's tokens plus one decode step: the first generated token is
        // sampled from the last prefill row, so it does not produce again.
        #expect(producer.slotCalls.count == promptIDs.count + 1)
        #expect(producer.slotCalls.allSatisfy { $0 == 2 },
                "every step must name slot 2, got \(producer.slotCalls)")
    }

    @Test func slotZeroKeepsTheChunkedPrefillPath() async throws {
        let context = try MetalContext()
        let tokenizer = try await GFTokenizer.load(from: ChatMLTemplateTests.fixtureFolder())
        let tokenA = tokenizer.encode("a", addBOS: false).first!
        let promptIDs = tokenizer.encode("go", addBOS: true)
        let producer = SlotRecordingProducer(vocabSize: tokenizer.vocabSize,
                                             nextToken: tokenA)
        let scratch = try RawCompletionScratch(context: context, vocab: tokenizer.vocabSize)

        let result = try await runRawCompletion(
            producer: producer,
            tokenizer: tokenizer,
            promptIds: promptIDs,
            config: GenerationConfig(maxNewTokens: 2, temperature: 0),
            context: context,
            scratch: scratch,
            prefillConfig: .production(chunkTokens: 32),
            slot: 0) { _ in }

        #expect(result.newTokens == 2)
        #expect(producer.chunkedCalls == 1,
                "slot 0 must keep the chunked prefill fast path")
        // Chunked prefill leaves the first row's logits, so only the second
        // generated token costs a produce step.
        #expect(producer.slotCalls == [0],
                "only the decoded step goes through produce, in slot 0")
    }
}
