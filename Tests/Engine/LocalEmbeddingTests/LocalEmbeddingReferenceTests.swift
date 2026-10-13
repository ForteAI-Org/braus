//
//  LocalEmbeddingReferenceTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation
@testable import LocalEmbedding
import Memory
import Testing

/// LocalEmbeddingReferenceTests check the Swift runtime against what Hugging Face's own code gives for the
/// same pinned files: the ids of `transformers`' XLM-RoBERTa tokenizer, token for token, and each model's normalized embedding of the
/// same texts as query and as document, with the pooling and prefixes of its card. The reference comes from
/// `Tools/Engine/Scripts/recall-embedding-reference.py` (torch 2.14.0, transformers 5.17.0, tokenizers 0.23.2,
/// float32). The model files are read from `BRAUS_RECALL_MODELS`, a folder holding one directory per pinned
/// model; without it the suites are skipped and say why. These are checks of the runtime, not of retrieval.
@Suite("The local embedding runtime reproduces the reference tokenizer and models")
struct LocalEmbeddingReferenceTests {

    struct Reference: Decodable {
        struct Model: Decodable {
            let pooling: String
            let token_ids: [[Int]]
            let query: [[Float]]
            let document: [[Float]]
        }
        let texts: [String]
        let models: [String: Model]
    }

    static let reference: Reference? = {
        guard let url = Bundle.module.url(forResource: "recall-embedding-reference", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Reference.self, from: data)
    }()

    static var modelsDirectory: URL? {
        ProcessInfo.processInfo.environment["BRAUS_RECALL_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static let hasModels = modelsDirectory != nil

    static func model(_ manifest: EmbeddingModelManifest) throws -> LocalEmbeddingModel {
        let directory = try #require(modelsDirectory).appendingPathComponent(manifest.directoryName)
        return try LocalEmbeddingModel(manifest: manifest, directory: directory)
    }

    static let cases: [(name: String, manifest: EmbeddingModelManifest)] = [
        ("multilingual-e5-small", .multilingualE5Small),
        ("granite-embedding-107m-multilingual", .graniteEmbedding107MMultilingual),
    ]

    @Test("the fixture is present and complete")
    func fixture() throws {
        let reference = try #require(Self.reference)
        #expect(reference.texts.count == 18)
        for (name, _) in Self.cases {
            let model = try #require(reference.models[name])
            #expect(model.token_ids.count == reference.texts.count)
            #expect(model.query.allSatisfy { $0.count == 384 } && model.document.allSatisfy { $0.count == 384 })
        }
    }

    @Test("token ids equal transformers' tokenizer's, for every text and both models",
          .enabled(if: hasModels, "BRAUS_RECALL_MODELS names no folder of the pinned models"),
          arguments: [0, 1])
    func tokens(_ index: Int) throws {
        let reference = try #require(Self.reference)
        let (name, manifest) = Self.cases[index]
        let model = try Self.model(manifest)
        let expected = try #require(reference.models[name]).token_ids
        for (text, ids) in zip(reference.texts, expected) {
            #expect(model.tokenIDs(text) == ids, "\(name): \(text.debugDescription)")
        }
    }

    @Test("embeddings match the reference as query and as document, cosine above 0.99999",
          .enabled(if: hasModels, "BRAUS_RECALL_MODELS names no folder of the pinned models"),
          arguments: [0, 1])
    func vectors(_ index: Int) throws {
        let reference = try #require(Self.reference)
        let (name, manifest) = Self.cases[index]
        let model = try Self.model(manifest)
        let entry = try #require(reference.models[name])
        for (role, expected) in [(EmbeddingRole.query, entry.query), (.document, entry.document)] {
            let got = try model.embed(reference.texts, as: role)
            for (position, (vector, wanted)) in zip(got, expected).enumerated() {
                let cosine = zip(vector.vector, wanted).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                let worst = zip(vector.vector, wanted).map { abs($0 - $1) }.max() ?? 1
                #expect(cosine > 0.99999 && worst < 2e-4,
                        "\(name) \(role) \(reference.texts[position].debugDescription): cosine \(cosine), max |Δ| \(worst)")
            }
        }
    }

    @Test("a file that is not the pinned one is refused, and a missing one is said missing",
          .enabled(if: hasModels, "BRAUS_RECALL_MODELS names no folder of the pinned models"))
    func refusals() throws {
        let source = try #require(Self.modelsDirectory).appendingPathComponent(EmbeddingModelManifest.multilingualE5Small.directoryName)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("recall-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(throws: LocalEmbeddingModel.Failure.missingFile(copy.appendingPathComponent("config.json").path)) {
            try LocalEmbeddingModel(manifest: .multilingualE5Small, directory: copy)
        }
        try FileManager.default.copyItem(at: source.appendingPathComponent("config.json"), to: copy.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(at: copy.appendingPathComponent("model.safetensors"),
                                                   withDestinationURL: source.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: copy.appendingPathComponent("tokenizer.json"))
        do {
            _ = try LocalEmbeddingModel(manifest: .multilingualE5Small, directory: copy)
            Issue.record("a tokenizer that is not the pinned one was accepted")
        } catch LocalEmbeddingModel.Failure.digestMismatch(let file, _, _) {
            #expect(file == "tokenizer.json")
        }
    }
}
