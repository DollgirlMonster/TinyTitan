import Testing

@testable import TinyTitan

/// The frontier checkpoints split one chunked prefill into several adjacent
/// calls. That is only free if the split calls run the same spans, at the same
/// positions, as the single call would -- which is what these pin.
@Suite("Raw completion checkpoint capture")
struct RawCompletionCaptureTests {
    @Test func onlyWholeChunkBoundariesInsideTheUncachedRangeSurvive() {
        #expect(
            capturePositions(
                [12, 4, 8, 8, 3, 0, 16, 20], from: 0, promptCount: 16, chunkTokens: 4)
                == [4, 8, 12])
        // Resumed at 6: boundaries count chunks from there, not from zero.
        #expect(
            capturePositions([8, 10, 14, 18], from: 6, promptCount: 20, chunkTokens: 4)
                == [10, 14, 18])
        #expect(capturePositions([4], from: 0, promptCount: 16, chunkTokens: 0).isEmpty)
    }

    @Test(arguments: [(0, 37, 4), (6, 50, 4), (0, 8_193, 4_096), (4_000, 30_000, 4_096)])
    func aSplitPrefillRunsExactlyTheSpansOfOneCall(
        start: Int, promptCount: Int, chunk: Int
    ) {
        let single = PrefillChunkPlanner.spans(
            tokenCount: promptCount - start, startPosition: start, chunkTokens: chunk)
            .map { [$0.startPosition, $0.tokenCount] }

        let everyBoundary = Array(stride(from: start + chunk, to: promptCount, by: chunk))
        var split: [[Int]] = []
        var position = start
        for boundary in capturePositions(
            everyBoundary, from: start, promptCount: promptCount, chunkTokens: chunk)
            + [promptCount]
        {
            split += PrefillChunkPlanner.spans(
                tokenCount: boundary - position, startPosition: position, chunkTokens: chunk)
                .map { [$0.startPosition, $0.tokenCount] }
            position = boundary
        }
        #expect(split == single)
    }
}
