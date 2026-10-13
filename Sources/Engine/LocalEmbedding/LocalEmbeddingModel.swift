//
//  LocalEmbeddingModel.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Accelerate
import CryptoKit
import Foundation
import Memory

/// LocalEmbeddingModel is a `TextEmbedding` that runs a pinned BERT-family model on this Mac: the tokenizer
/// and the encoder of this module over the model's own files, the pooling and the prefixes its card
/// prescribes, then an L2 normalization. It needs no network and no other process. Loading checks every file
/// against its manifest; a missing or different file throws `Failure`, and the caller says the semantic
/// search is unavailable rather than answering without it. Immutable after init and safe to call from any
/// task: each call allocates its own buffers.
public final class LocalEmbeddingModel: TextEmbedding, @unchecked Sendable {
    // Sendable: the tokenizer, the encoder and the space are immutable after init.

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case missingFile(String)
        case digestMismatch(file: String, expected: String, found: String)
        case unreadable(String)

        public var description: String {
            switch self {
                case .missingFile(let path): "the model file \(path) is not installed"
                case .digestMismatch(let file, let expected, let found): "\(file) has sha256 \(found), the manifest pins \(expected)"
                case .unreadable(let why): "the model cannot be loaded: \(why)"
            }
        }
    }

    public let manifest: EmbeddingModelManifest
    public let space: EmbeddingSpace
    /// How long the load took, file checks included, for the measures.
    public let loadDuration: Duration
    private let tokenizer: UnigramTokenizer
    private let encoder: TransformerEncoder

    /// Loads the model from `directory`, which holds the manifest's files. `verifyWeights` hashes the weights
    /// file too (about half a second for the larger model); the tokenizer and the configuration are always
    /// hashed, and the weights' size always checked.
    public init(manifest: EmbeddingModelManifest, directory: URL, verifyWeights: Bool = true) throws {
        let started = ContinuousClock.now
        func file(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missingFile(url.path) }
            return url
        }
        let configuration = try file("config.json")
        let tokenizerFile = try file("tokenizer.json")
        let weights       = try file(manifest.weightsFile)
        try Self.check(configuration, manifest.configurationDigest)
        try Self.check(tokenizerFile, manifest.tokenizerDigest)
        let size = (try? FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? Int) ?? -1
        guard size == manifest.weightsBytes else {
            throw Failure.digestMismatch(file: manifest.weightsFile, expected: "\(manifest.weightsBytes) bytes", found: "\(size) bytes")
        }
        if verifyWeights { try Self.check(weights, manifest.weightsDigest) }
        do {
            let config = try TransformerEncoder.Configuration(contentsOf: configuration)
            self.tokenizer = try UnigramTokenizer(contentsOf: tokenizerFile)
            self.encoder   = try TransformerEncoder(weights: weights, configuration: config)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
        guard encoder.configuration.hidden == manifest.dimensions else {
            throw Failure.unreadable("the configuration has \(encoder.configuration.hidden) dimensions, the manifest \(manifest.dimensions)")
        }
        self.manifest = manifest
        self.space    = manifest.space
        self.loadDuration = started.duration(to: .now)
    }

    public func embed(_ texts: [String], as role: EmbeddingRole) throws -> [EmbeddedText] {
        try texts.map { text in
            let encoding = tokenizer.encode(space.formatted(text, as: role), maximumTokens: manifest.maximumTokens)
            let hidden = try encoder.encode(encoding.ids)
            let width = encoder.configuration.hidden
            var pooled = [Float](repeating: 0, count: width)
            switch manifest.pooling {
                case .cls:
                    pooled = Array(hidden[0..<width])
                case .mean:
                    let rows = encoding.ids.count
                    hidden.withUnsafeBufferPointer { hidden in
                        for row in 0..<rows { vDSP_vadd(pooled, 1, hidden.baseAddress! + row * width, 1, &pooled, 1, vDSP_Length(width)) }
                    }
                    var divisor = Float(rows)
                    vDSP_vsdiv(pooled, 1, &divisor, &pooled, 1, vDSP_Length(width))
            }
            var norm: Float = 0
            vDSP_svesq(pooled, 1, &norm, vDSP_Length(width))
            norm = norm.squareRoot()
            guard norm > 0, norm.isFinite else { throw Failure.unreadable("a vector without length") }
            vDSP_vsdiv(pooled, 1, &norm, &pooled, 1, vDSP_Length(width))
            return EmbeddedText(vector: pooled, tokenCount: encoding.ids.count, isTruncated: encoding.isTruncated)
        }
    }

    /// The token ids of a text formatted for `role`, for the checks against the reference tokenizer.
    func tokenIDs(_ text: String, as role: EmbeddingRole? = nil) -> [Int] {
        tokenizer.encode(role.map { space.formatted(text, as: $0) } ?? text, maximumTokens: manifest.maximumTokens).ids
    }

    private static func check(_ url: URL, _ expected: String) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.missingFile(url.path) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let found = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard found == expected else { throw Failure.digestMismatch(file: url.lastPathComponent, expected: expected, found: found) }
    }
}
