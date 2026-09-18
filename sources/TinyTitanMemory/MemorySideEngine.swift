import Foundation

/// One fact as the side-engine sees it.
///
/// The whole fact, key included: the key carries the claim as often as the
/// value does, and withholding it halved accuracy when it was measured
/// (`docs/side-engine-tasks.md`).
public struct MemoryFact: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// The judgements a resident side-engine is asked, in memory's own terms.
///
/// The engine itself lives in the runtime target, which this one cannot import
/// — `TinyTitanMemory` depends on `ContinuityCore` and nothing else — so the
/// server adapts `SideEngine` to this port. Two rules make an optional,
/// fallible engine safe to consult:
///
/// - **`nil` is "no decision"**, and the caller then behaves exactly as it did
///   before the engine existed. A shut-down engine, a completion the parser
///   refused, a timeout — each falls back to the deterministic behaviour
///   instead of blocking a write.
/// - **Only the tasks that were measured good on both halves appear here.**
///   The shipped prompts decide contradiction, duplication and retrieval from
///   the 4B up, and the reply check from the 9B; durability and supersession
///   are one-sided at every size and deliberately have no method
///   (`docs/side-engine-tasks.md`).
public protocol MemorySideEngine: Sendable {
    /// T5: do these two facts say the same thing? True means a reader learns
    /// nothing from the second that the first did not already tell them.
    func duplicates(_ a: MemoryFact, _ b: MemoryFact) async -> Bool?

    /// T3: do these two statements disagree?
    ///
    /// Advisory. Disagreement is not supersession — telling a state that moved
    /// on from one that is wrong is T4, which no measured size decides — so a
    /// caller must not refuse a write on this answer alone.
    func contradicts(_ a: MemoryFact, _ b: MemoryFact) async -> Bool?

    /// T7: could this fact answer this question?
    func couldAnswer(_ question: String, _ fact: MemoryFact) async -> Bool?

    /// Release the engine. The memory service calls this on shutdown, because
    /// the engine is a second resident model and should not wait for process
    /// exit to let its weights go.
    func shutdown() async
}

public extension MemorySideEngine {
    /// A value with nothing resident to release says nothing.
    func shutdown() async {}
}
