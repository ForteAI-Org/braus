import Dispatch
import Foundation
import LocalEmbedding
import Memory
import Synchronization
import Testing

@Suite
struct EmbeddingServiceTests {
    static let source = EmbeddingService.Source(
        manifest: .graniteEmbedding107MMultilingual,
        directory: URL(fileURLWithPath: "/unused")
    )

    final class Probe: Sendable {
        struct State {
            var loads = 0
            var identities: [ObjectIdentifier] = []
            weak var model: Model?
        }
        let state = Mutex(State())
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let blocks: Bool

        init(blocks: Bool = false) { self.blocks = blocks }

        func waitForInference() -> Bool { entered.wait(timeout: .now() + 5) == .success }

        func load(_ source: EmbeddingService.Source) -> any TextEmbedding {
            let model = Model(probe: self, space: source.space)
            state.withLock { $0.loads += 1; $0.model = model }
            return model
        }
    }

    final class Model: TextEmbedding {
        let probe: Probe
        let space: EmbeddingSpace
        init(probe: Probe, space: EmbeddingSpace) { self.probe = probe; self.space = space }
        func embed(_ texts: [String], as role: EmbeddingRole) throws -> [EmbeddedText] {
            probe.state.withLock { $0.identities.append(ObjectIdentifier(self)) }
            if probe.blocks {
                probe.entered.signal()
                guard probe.resume.wait(timeout: .now() + 5) == .success else {
                    throw EmbeddingService.Unavailable.failed("inference gate timed out")
                }
            }
            let vector = [Float(1)] + Array(repeating: Float(0), count: space.dimensions - 1)
            return texts.map { _ in EmbeddedText(vector: vector, tokenCount: 1, isTruncated: false) }
        }
    }

    @Test func oneInstancePerProcess() async throws {
        let probe = Probe()
        let service = EmbeddingService(loader: { probe.load($0) })
        let recall = service.embedding(for: Self.source.space)
        let digest = service.embedding(for: Self.source.space)
        #expect(await service.ready(Self.source) == nil)
        _ = try recall.embed(["recall"], as: .query)
        #expect(await service.ready(Self.source) == nil)
        _ = try digest.embed(["digest"], as: .document)
        #expect(probe.state.withLock { $0.loads == 1 && Set($0.identities).count == 1 && $0.identities.count == 2 })
    }

    @Test(.enabled(if: LocalEmbeddingReferenceTests.hasModels,
                   "BRAUS_RECALL_MODELS names no folder of the pinned models"))
    func installedVectorsThroughService() async throws {
        let model = try LocalEmbeddingReferenceTests.model(.graniteEmbedding107MMultilingual)
        let reference = try #require(LocalEmbeddingReferenceTests.reference)
        let service = EmbeddingService { _ in model }
        #expect(await service.ready(Self.source) == nil)
        for role in [EmbeddingRole.document, .query] {
            let before = try model.embed(reference.texts, as: role)
            let after = try service.embed(reference.texts, as: role, in: Self.source.space)
            #expect(before == after)
            #expect(before.map { $0.vector.map(\.bitPattern) } == after.map { $0.vector.map(\.bitPattern) })
        }
    }

    @Test func otherModelRefused() async {
        let service = EmbeddingService(loader: { Probe().load($0) })
        service.prepare(.lazy, source: Self.source)
        let other = EmbeddingService.Source(manifest: .multilingualE5Small, directory: Self.source.directory)
        #expect(await service.ready(other) == .differentModel)
        #expect(!service.isLoaded)
        #expect(await service.ready(Self.source) == nil)
        _ = service.release()
        #expect(await service.ready(other) == .differentModel)
    }

    @Test func sameSpaceKeepsFirstDirectory() async {
        let directories = Mutex<[URL]>([])
        let service = EmbeddingService { source in
            directories.withLock { $0.append(source.directory) }
            return Probe().load(source)
        }
        service.prepare(.lazy, source: Self.source)
        let other = EmbeddingService.Source(manifest: Self.source.manifest, directory: URL(fileURLWithPath: "/other"))
        #expect(await service.ready(other) == nil)
        #expect(directories.withLock { $0 } == [Self.source.directory])
    }

    @Test func loadFailureIsReported() async {
        let service = EmbeddingService { _ in throw EmbeddingService.Unavailable.notInstalled }
        #expect(await service.ready(Self.source) == .notInstalled)
        #expect(!service.isLoaded)
    }

    @Test func lazyLoadsOnFirstUse() async {
        let probe = Probe()
        let service = EmbeddingService(loader: { probe.load($0) })
        service.prepare(.lazy, source: Self.source)
        #expect(probe.state.withLock { $0.loads } == 0)
        #expect(!service.isLoaded)
        #expect(await service.ready(Self.source) == nil)
        #expect(probe.state.withLock { $0.loads } == 1)
    }

    @Test func eagerLoadsAtPrepare() async throws {
        let probe = Probe()
        let service = EmbeddingService(loader: { probe.load($0) })
        service.prepare(.eager, source: Self.source)
        for _ in 0..<1_000 {
            if service.isLoaded { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(service.isLoaded)
        #expect(probe.state.withLock { $0.loads } == 1)
    }

    @Test func concurrentFirstUse() async throws {
        let probe = Probe()
        let service = EmbeddingService { source in
            try await Task.sleep(for: .milliseconds(30))
            return probe.load(source)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    #expect(await service.ready(Self.source) == nil)
                    _ = try service.embed(["text"], as: .query, in: Self.source.space)
                }
            }
            try await group.waitForAll()
        }
        #expect(probe.state.withLock { $0.loads } == 1)
    }

    @Test func releaseFreesTheModel() async throws {
        let probe = Probe()
        let service = EmbeddingService(loader: { probe.load($0) })
        let recall = service.embedding(for: Self.source.space)
        let digest = service.embedding(for: Self.source.space)
        #expect(await service.ready(Self.source) == nil)
        _ = try recall.embed(["text"], as: .query)
        _ = try digest.embed(["text"], as: .document)
        #expect(service.release() > 0)
        #expect(!service.isLoaded)
        #expect(probe.state.withLock { $0.model == nil })
        #expect(throws: EmbeddingService.Unavailable.notLoaded) { try recall.embed(["text"], as: .query) }
    }

    @Test func readyAfterRelease() async throws {
        let probe = Probe()
        let service = EmbeddingService(loader: { probe.load($0) })
        #expect(await service.ready(Self.source) == nil)
        let before = try service.embed(["text"], as: .query, in: Self.source.space)
        _ = service.release()
        #expect(throws: EmbeddingService.Unavailable.notLoaded) {
            try service.embed(["text"], as: .query, in: Self.source.space)
        }
        #expect(probe.state.withLock { $0.loads } == 1)
        #expect(await service.ready(Self.source) == nil)
        #expect(try service.embed(["text"], as: .query, in: Self.source.space) == before)
        #expect(probe.state.withLock { $0.loads } == 2)
    }

    @Test(arguments: [false, true])
    func releaseDuringInference(cancelRelease: Bool) async throws {
        let probe = Probe(blocks: true)
        let service = EmbeddingService(loader: { probe.load($0) })
        #expect(await service.ready(Self.source) == nil)
        let inference = Task.detached { try service.embed(["text"], as: .query, in: Self.source.space) }
        #expect(probe.waitForInference())
        #expect(service.release() == 0)
        #expect(service.isLoaded)
        if cancelRelease { #expect(await service.ready(Self.source) == nil) }
        #expect(probe.state.withLock { $0.loads } == 1)
        probe.resume.signal()
        _ = try await inference.value
        #expect(service.isLoaded == cancelRelease)
        #expect(probe.state.withLock { $0.model != nil } == cancelRelease)
    }
}
