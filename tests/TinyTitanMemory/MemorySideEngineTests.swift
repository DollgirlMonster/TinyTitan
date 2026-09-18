import Foundation
import Testing
@testable import TinyTitanMemory

/// The side-engine port, and the one judgement wired to a write so far.
///
/// The engine itself needs a model and lives in the runtime target; what is
/// here is the contract the memory path depends on, driven by a stub: a
/// `true` verdict stops a near-duplicate, a `nil` verdict changes nothing, and
/// no engine at all is the control.
@Suite struct MemorySideEngineTests {
    private func configuration(workspace: String = "repo-a") -> MemoryConfiguration {
        var configuration = MemoryConfiguration()
        configuration.isEnabled = true
        configuration.workspace = workspace
        configuration.user = "local"
        return configuration
    }

    private func fact(_ key: String, _ value: String) throws -> MemoryRecord {
        MemoryRecord(key: try MemoryKey(validating: key), value: value)
    }

    @Test func aFactUnderANewKeyThatAnExistingOneAlreadySaysIsNotStored() async throws {
        let store = InMemoryStore()
        let engine = StubSideEngine(duplicates: true)
        let log = LogCollector()
        let service = MemoryService(configuration: configuration(),
                                    durableStore: store,
                                    sideEngine: engine,
                                    log: { log.append($0) })
        let context = try #require(await service.beginSession(id: "s-dup"))
        try await store.set(try fact("characters/marcus/eyes", "grey"), in: context.scope)

        let written = await service.storeConsolidation(
            [try fact("characters/marcus/eye_colour", "grey")], in: context)

        #expect(written == 0)
        #expect(engine.pairs.count == 1)
        #expect(engine.pairs.first?.0.key == "characters/marcus/eye_colour")
        #expect(engine.pairs.first?.1.key == "characters/marcus/eyes")
        let stored = try await store.get(try MemoryKey(validating: "characters/marcus/eye_colour"),
                                         in: context.scope)
        #expect(stored == nil)
        #expect(log.messages().contains { $0.contains("near-duplicate stopped") })
        #expect(log.messages().contains { $0.contains("stopped 1 near-duplicate") })
    }

    @Test func withoutAnEngineTheSameFactIsStored() async throws {
        let store = InMemoryStore()
        let service = MemoryService(configuration: configuration(), durableStore: store)
        let context = try #require(await service.beginSession(id: "s-plain"))
        try await store.set(try fact("characters/marcus/eyes", "grey"), in: context.scope)

        let written = await service.storeConsolidation(
            [try fact("characters/marcus/eye_colour", "grey")], in: context)

        #expect(written == 1)
        let stored = try await store.get(try MemoryKey(validating: "characters/marcus/eye_colour"),
                                         in: context.scope)
        #expect(stored?.value == "grey")
    }

    @Test func aNoDecisionFromTheEngineStoresTheFact() async throws {
        let store = InMemoryStore()
        let service = MemoryService(configuration: configuration(),
                                    durableStore: store,
                                    sideEngine: StubSideEngine(duplicates: nil))
        let context = try #require(await service.beginSession(id: "s-nil"))
        try await store.set(try fact("characters/marcus/eyes", "grey"), in: context.scope)

        let written = await service.storeConsolidation(
            [try fact("characters/marcus/eye_colour", "grey")], in: context)

        #expect(written == 1)
    }

    @Test func onlyFactsInTheSameLeadingSegmentAreCompared() async throws {
        let store = InMemoryStore()
        let engine = StubSideEngine(duplicates: true)
        let service = MemoryService(configuration: configuration(),
                                    durableStore: store,
                                    sideEngine: engine)
        let context = try #require(await service.beginSession(id: "s-category"))
        try await store.set(try fact("gotchas/other", "grey"), in: context.scope)

        let written = await service.storeConsolidation(
            [try fact("characters/marcus/eyes", "grey")], in: context)

        #expect(written == 1)
        #expect(engine.pairs.isEmpty)
    }

    @Test func theSameKeyIsNeverComparedWithItself() async throws {
        let store = InMemoryStore()
        let engine = StubSideEngine(duplicates: true)
        let service = MemoryService(configuration: configuration(),
                                    durableStore: store,
                                    sideEngine: engine)
        let context = try #require(await service.beginSession(id: "s-same-key"))
        // Same key, different value: the unchanged check does not fire, and
        // the duplication check must not ask the engine about a key against
        // itself.
        try await store.set(try fact("characters/marcus/eyes", "grey"), in: context.scope)

        let written = await service.storeConsolidation(
            [try fact("characters/marcus/eyes", "hazel")], in: context)

        #expect(written == 1)
        #expect(engine.pairs.isEmpty)
    }

    @Test func theComparisonCountIsBounded() async throws {
        let store = InMemoryStore()
        let engine = StubSideEngine(duplicates: false)
        let service = MemoryService(configuration: configuration(),
                                    durableStore: store,
                                    sideEngine: engine)
        let context = try #require(await service.beginSession(id: "s-bounded"))
        for index in 0..<20 {
            try await store.set(try fact("characters/p\(index)", "value \(index)"),
                                in: context.scope)
        }

        let written = await service.storeConsolidation(
            [try fact("characters/new_fact", "something else")], in: context)

        #expect(written == 1)
        #expect(engine.pairs.count == MemoryService.maximumDuplicateCandidates)
    }
}

/// Answers every duplication question the same way, and records what it was
/// asked.
///
/// unchecked-invariant: `asked` is only ever touched under `lock`.
private final class StubSideEngine: MemorySideEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Bool?
    private var asked: [(MemoryFact, MemoryFact)] = []

    init(duplicates answer: Bool?) {
        self.answer = answer
    }

    var pairs: [(MemoryFact, MemoryFact)] { lock.withLock { asked } }

    func duplicates(_ a: MemoryFact, _ b: MemoryFact) async -> Bool? {
        lock.withLock { asked.append((a, b)) }
        return answer
    }

    func contradicts(_ a: MemoryFact, _ b: MemoryFact) async -> Bool? { nil }

    func couldAnswer(_ question: String, _ fact: MemoryFact) async -> Bool? { nil }
}

/// Collects the service's log events.
///
/// unchecked-invariant: `events` is only ever touched under `lock`.
private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MemoryLogEvent] = []

    func append(_ event: MemoryLogEvent) {
        lock.withLock { events.append(event) }
    }

    func messages() -> [String] {
        lock.withLock { events.map(\.message) }
    }
}
