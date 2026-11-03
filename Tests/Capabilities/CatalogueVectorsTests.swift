import Capabilities
import Foundation
import Testing

@Suite
struct CatalogueVectorsTests {
    @Test func reusesOnlyUnchangedContentInTheSameModel() async throws {
        let model = CountingTextEmbedding()
        let entry = searchEntry("scroll", examples: ["Scroll down"])
        let first = try await CatalogueVectors.prepare(entries: [entry], embedding: model)
        let unchanged = try await CatalogueVectors.prepare(entries: [entry], embedding: model, cached: first)
        #expect(await model.textCount == 1)
        #expect(unchanged.vector(for: entry) == [1, 0])
        let changed = searchEntry("scroll", examples: ["Scroll up"])
        let second = try await CatalogueVectors.prepare(entries: [changed], embedding: model, cached: first)
        #expect(await model.textCount == 2)
        #expect(second.vector(for: entry) == nil)
        let other = CountingTextEmbedding(modelID: "other")
        _ = try await CatalogueVectors.prepare(entries: [changed], embedding: other, cached: second)
        #expect(await other.textCount == 1)
    }

    @Test func roundTripIsPrivateAtomicAndRejectsWrongModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let file = directory.appendingPathComponent("vectors.json")
        let entry = searchEntry("scroll")
        let original = try await CatalogueVectors.prepare(entries: [entry], embedding: CountingTextEmbedding())
        try original.save(to: file)
        try original.save(to: file)
        #expect(try CatalogueVectors.load(from: file, modelID: "fake").vector(for: entry) == [1, 0])
        #expect(throws: (any Error).self) { try CatalogueVectors.load(from: file, modelID: "other") }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["vectors.json"])
        try Data("broken".utf8).write(to: file)
        let model = CountingTextEmbedding()
        let recovered = try await CatalogueVectors.prepare(entries: [entry], embedding: model, file: file)
        #expect(await model.textCount == 1)
        #expect(recovered.vector(for: entry) == original.vector(for: entry))
        #expect(try CatalogueVectors.load(from: file, modelID: "fake").vector(for: entry) == [1, 0])
    }

    @Test func failedReplacementLeavesDestinationAndRemovesTemporaryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let destination = directory.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let vectors = try await CatalogueVectors.prepare(entries: [searchEntry("scroll")],
                                                         embedding: CountingTextEmbedding())
        #expect(throws: (any Error).self) { try vectors.save(to: destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["occupied"])
    }

    @Test func rejectsInvalidOutputBeforeSaving() async throws {
        let invalid: [[Float]] = [[], [0, 0], [.nan, 1], [.infinity, 1]]
        for vector in invalid {
            await #expect(throws: (any Error).self) {
                try await CatalogueVectors.prepare(entries: [searchEntry("scroll")],
                                                   embedding: CountingTextEmbedding(output: vector))
            }
        }
    }
}

actor CountingTextEmbedding: Capabilities.TextEmbedding {
    nonisolated let modelID: String
    private(set) var textCount = 0
    let output: [Float]

    init(modelID: String = "fake", output: [Float] = [1, 0]) {
        self.modelID = modelID
        self.output = output
    }

    func vectors(for texts: [String]) async throws -> [[Float]] {
        textCount += texts.count
        return texts.map { _ in output }
    }
}
