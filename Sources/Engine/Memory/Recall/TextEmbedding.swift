//
//  TextEmbedding.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

/// EmbeddingRole is what a text is to a retrieval model: the query a request is searched with, or a
/// document of the catalogue. Models trained with distinct formats for the two (a prefix, an instruction)
/// receive the format of the role; others receive the text as it is.
public enum EmbeddingRole: String, Sendable, Equatable, Hashable, CaseIterable {
    case query, document
}

/// EmbeddingSpace identifies the vectors one configuration produces: the model and its exact revision, the
/// digests of the artifacts it was loaded from, the tokenizer, the formats of the two roles, the pooling, the
/// normalization, the precision and the number of dimensions. Two vectors are comparable only in the same
/// space: a new model, revision, tokenizer, prefix, pooling or dimension is another space, never compared with
/// this one. `spaceID` is derived from all of them, so it changes whenever any of them does.
public struct EmbeddingSpace: Sendable, Equatable, Hashable {
    public let modelID: String
    public let modelRevision: String
    public let weightsDigest: String
    public let tokenizerDigest: String
    public let dimensions: Int
    public let pooling: String
    public let normalization: String
    public let precision: String
    public let queryPrefix: String
    public let documentPrefix: String
    public let maximumTokens: Int

    public init(modelID: String, modelRevision: String, weightsDigest: String, tokenizerDigest: String, dimensions: Int,
                pooling: String, normalization: String = "l2", precision: String = "float32", queryPrefix: String,
                documentPrefix: String, maximumTokens: Int) {
        self.modelID         = modelID
        self.modelRevision   = modelRevision
        self.weightsDigest   = weightsDigest
        self.tokenizerDigest = tokenizerDigest
        self.dimensions      = dimensions
        self.pooling         = pooling
        self.normalization   = normalization
        self.precision       = precision
        self.queryPrefix     = queryPrefix
        self.documentPrefix  = documentPrefix
        self.maximumTokens   = maximumTokens
    }

    /// The space's identity: the model, its revision, and a digest of everything else that decides a vector.
    public var spaceID: String {
        let fields = [modelID, modelRevision, weightsDigest, tokenizerDigest, String(dimensions), pooling, normalization,
                      precision, queryPrefix, documentPrefix, String(maximumTokens)]
        return "\(modelID)@\(modelRevision.prefix(12))/\(StructuralDigest.fnv1a(fields.joined(separator: "\u{1F}")))"
    }

    /// The text the model receives for a role.
    public func formatted(_ text: String, as role: EmbeddingRole) -> String {
        (role == .query ? queryPrefix : documentPrefix) + text
    }
}

/// EmbeddedText is one text's vector, in its space, with how many tokens the model read and whether the text
/// had to be cut to the model's context: a cut text is a vector of less than the text, said rather than hidden.
public struct EmbeddedText: Sendable, Equatable {
    public let vector: [Float]
    public let tokenCount: Int
    public let isTruncated: Bool

    public init(vector: [Float], tokenCount: Int, isTruncated: Bool) {
        self.vector      = vector
        self.tokenCount  = tokenCount
        self.isTruncated = isTruncated
    }
}

/// TextEmbedding is the role of a local model that turns texts into vectors of one space. It reads nothing
/// but the texts it is given: no chat, no network. An implementation that cannot produce a vector throws;
/// it never answers an empty or a zero vector in its place, since that would read as a text that means nothing.
public protocol TextEmbedding: Sendable {

    /// The space every vector of this model belongs to.
    var space: EmbeddingSpace { get }

    /// The vectors of `texts`, in order, each formatted for `role` and normalized as the space says.
    func embed(_ texts: [String], as role: EmbeddingRole) throws -> [EmbeddedText]
}
