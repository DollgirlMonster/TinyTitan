import Foundation
import Testing
@testable import TinyTitanServerCore
import TinyTitan
import TinyTitanMemory

/// The resident side-engine's home in the server: which install it loads, and
/// how the engine's vocabulary becomes memory's.
///
/// No model is loaded here — a fake `SideEngineModel` answers the adapter, and
/// resolution is a filesystem question — so these run with the unit tests.
@Suite struct SideEngineServiceTests {

    // MARK: - which install

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-engine-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anExplicitOffMeansNoEngine() {
        #expect(ServerSideEngineFactory.resolve(
            environment: ["TINYTITAN_SIDE_ENGINE": "0"], modelsDirectory: "/models") == nil)
        #expect(ServerSideEngineFactory.resolve(
            environment: ["TINYTITAN_SIDE_ENGINE": "off"], modelsDirectory: "/models") == nil)
    }

    @Test func theDefaultInstallIsThe4BUnderTheModelsDirectory() throws {
        let models = try temporaryDirectory("models")
        defer { try? FileManager.default.removeItem(at: models) }
        let install = models.appendingPathComponent("qwen3.5_4B_4Bit", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)

        let resolved = ServerSideEngineFactory.resolve(environment: [:],
                                                       modelsDirectory: models.path)
        #expect(resolved == install.path)
        #expect(ServerSideEngineFactory.defaultInstall == "qwen3.5_4B_4Bit")
    }

    @Test func aNamedInstallResolvesUnderTheModelsDirectory() throws {
        let models = try temporaryDirectory("models")
        defer { try? FileManager.default.removeItem(at: models) }
        let install = models.appendingPathComponent("qwen3.5_9B_4Bit", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)

        let resolved = ServerSideEngineFactory.resolve(
            environment: ["TINYTITAN_SIDE_ENGINE": "qwen3.5_9B_4Bit"],
            modelsDirectory: models.path)
        #expect(resolved == install.path)
    }

    @Test func aMissingInstallResolvesToNothing() throws {
        let models = try temporaryDirectory("models")
        defer { try? FileManager.default.removeItem(at: models) }
        #expect(ServerSideEngineFactory.resolve(environment: [:],
                                                modelsDirectory: models.path) == nil)
        #expect(ServerSideEngineFactory.resolve(environment: [:],
                                                modelsDirectory: nil) == nil)
        #expect(ServerSideEngineFactory.resolve(
            environment: ["TINYTITAN_SIDE_ENGINE": "qwen3.5_9B_4Bit"],
            modelsDirectory: models.path) == nil)
    }

    @Test func anExplicitPathIsUsedAsGiven() throws {
        let directory = try temporaryDirectory("install")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = ServerSideEngineFactory.resolve(
            environment: ["TINYTITAN_SIDE_ENGINE": directory.path],
            modelsDirectory: nil)
        #expect(resolved == directory.path)
    }

    // MARK: - the adapter

    @Test func aYesAndANoBecomeTrueAndFalse() async {
        let engine = SideEngine { FakeSideEngineModel(answer: "YES") }
        let adapter = SideEngineMemoryAdapter(engine: engine)
        let answer = await adapter.duplicates(MemoryFact(key: "characters/marcus/eyes",
                                                         value: "grey"),
                                              MemoryFact(key: "characters/marcus/eye_colour",
                                                         value: "grey"))
        #expect(answer == true)
    }

    @Test func aCompletionOutsideTheAnswerSetIsNoDecision() async {
        let engine = SideEngine { FakeSideEngineModel(answer: "Maybe") }
        let adapter = SideEngineMemoryAdapter(engine: engine)
        let answer = await adapter.contradicts(MemoryFact(key: "state/inn", value: "standing"),
                                               MemoryFact(key: "state/inn", value: "burned"))
        #expect(answer == nil)
    }

    @Test func aModelThatWillNotLoadIsNoDecision() async {
        let engine = SideEngine { throw SideEngineError.missingTokenizer("/nowhere") }
        let adapter = SideEngineMemoryAdapter(engine: engine)
        let answer = await adapter.couldAnswer("When does the ferry run?",
                                               MemoryFact(key: "rules/ferry", value: "Sundays"))
        #expect(answer == nil)
    }

    @Test func shutdownReleasesTheWeightsAndStopsAnswering() async {
        let engine = SideEngine { FakeSideEngineModel(answer: "NO") }
        let adapter = SideEngineMemoryAdapter(engine: engine)
        let before = await adapter.duplicates(MemoryFact(key: "a/one", value: "1"),
                                              MemoryFact(key: "a/two", value: "1"))
        #expect(before == false)

        await adapter.shutdown()
        let loaded = await engine.isLoaded
        #expect(loaded == false)
        let after = await adapter.duplicates(MemoryFact(key: "a/one", value: "1"),
                                             MemoryFact(key: "a/two", value: "1"))
        #expect(after == nil)
    }
}

/// Answers every question with one scripted string.
///
/// unchecked-invariant: `answer` is set once at construction and only read
/// afterwards.
private final class FakeSideEngineModel: SideEngineModel, @unchecked Sendable {
    private let answer: String

    init(answer: String) {
        self.answer = answer
    }

    var contention: (@Sendable () -> Bool)?
    var busyThreads = 1
    var idleThreads = 4
    var endOfSequence = 0
    var threads: Int { 1 }

    func reset() {}
    func encode(system: String, user: String) throws -> [Int] { [1] }
    func decode(_ tokens: [Int]) -> String { answer }
    func generate(prompt: [Int], maximumTokens: Int, stopping: Set<Int>) throws -> [Int] { [0] }
}
