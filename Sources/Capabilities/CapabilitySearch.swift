import Foundation
import LocalMCP

/// DocumentSearch owns a frozen lexical index and optional semantic vectors, independent of transport and engine.
/// The caller supplies lexical text and an immutable vector snapshot.
public struct DocumentSearch: Sendable {
    /// Hit identifies a document and its retrieval score, which is not a probability.
    public struct Hit: Sendable, Equatable {
        public let id: String
        public let score: Double
    }

    public static let minimumScore: Double = 0.01

    public static let semanticWeight: Double = 0.8

    /// Fallback identifies why a query used the unchanged BM25 index.
    public enum Fallback: Sendable, Equatable {
        case noVectors, noEmbedding, differentModel, incompleteVectors, invalidVectors
        case embeddingFailed(String)
    }

    /// Event exposes typed fallback evidence without coupling search to a telemetry backend.
    public enum Event: Sendable, Equatable {
        case lexicalFallback(Fallback)
    }

    /// Settings are selected on tuning questions only; the verification split never changes them.
    struct Settings: Sendable, Equatable {
        var semanticWeight: Double = DocumentSearch.semanticWeight
        var minimumScore: Double = 0.2
        var minimumCosine: Double = 0.6
    }

    private let vectors: CatalogueVectors?
    private let embedding: (any TextEmbedding)?
    private let entries: [SearchDocument]
    private let settings: Settings
    private let onEvent: @Sendable (Event) -> Void

    private struct Document: Sendable {
        let id: String
        let frequencies: [String: Int]
        let length: Int
    }

    private static let k1 = 0.9
    private static let b = 0.4

    private let documents: [Document]
    private let documentFrequencies: [String: Int]
    private let averageLength: Double

    /// Preserves the lexical-only index and its exact scores when no semantic dependencies are supplied.
    public init(
        documents: [SearchDocument],
        vectors: CatalogueVectors? = nil,
        embedding: (any TextEmbedding)? = nil,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.init(documents: documents, vectors: vectors, embedding: embedding, settings: Settings(), onEvent: onEvent)
    }

    init(
        documents: [SearchDocument],
        vectors: CatalogueVectors?,
        embedding: (any TextEmbedding)?,
        settings: Settings,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.entries = documents.sorted { $0.id < $1.id }
        self.vectors = vectors
        self.embedding = embedding
        self.settings = settings
        self.onEvent = onEvent
        let documents = self.entries.map { entry in
            let tokens = Self.tokens(entry.text)
            return Document(
                id: entry.id,
                frequencies: tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 },
                length: tokens.count
            )
        }
        self.documents = documents
        self.documentFrequencies = documents.reduce(into: [:]) { frequencies, document in
            for term in document.frequencies.keys { frequencies[term, default: 0] += 1 }
        }
        self.averageLength = documents.isEmpty ? 0
            : documents.reduce(0.0) { $0 + Double($1.length) } / Double(documents.count)
    }

    /// Returns matches ordered by score then identifier, with unchanged lexical fallback scores.
    /// Semantic scores require absolute cosine evidence before candidate normalization, so unrelated queries
    /// cannot become confident solely by being the best of a poor set. Missing vectors never await a model.
    @concurrent
    public func search(_ query: String, limit: Int) async -> [Hit] {
        guard limit > 0, !Self.tokens(query).isEmpty, !documents.isEmpty else { return [] }
        let lexical = lexicalScores(query)
        guard let vectors else { return fallback(.noVectors, lexical: lexical, limit: limit) }
        guard let embedding else { return fallback(.noEmbedding, lexical: lexical, limit: limit) }
        guard vectors.modelID == embedding.modelID else {
            return fallback(.differentModel, lexical: lexical, limit: limit)
        }
        let documentVectors = entries.compactMap { vectors.vector(forText: $0.vectorText) }
        guard documentVectors.count == entries.count else {
            return fallback(.incompleteVectors, lexical: lexical, limit: limit)
        }
        do {
            let queries = try await embedding.vectors(for: [query])
            guard queries.count == 1, let queryVector = queries.first,
                  let dimensions = documentVectors.first?.count,
                  queryVector.count == dimensions, queryVector.allSatisfy(\.isFinite),
                  queryVector.contains(where: { $0 != 0 }) else {
                return fallback(.invalidVectors, lexical: lexical, limit: limit)
            }
            let cosines = documentVectors.map { Self.cosine(queryVector, $0) }
            guard (cosines.max() ?? 0) >= settings.minimumCosine else { return [] }
            let lexicalByID = Dictionary(uniqueKeysWithValues: lexical.map { ($0.id, $0.score) })
            let lexicalValues = documents.map { lexicalByID[$0.id] ?? 0 }
            let normalizedLexical = Self.normalized(lexicalValues)
            let normalizedSemantic = Self.normalized(cosines.map { max(0, $0) })
            let mixed = documents.indices.compactMap { index -> Hit? in
                guard cosines[index] >= settings.minimumCosine else { return nil }
                let score = (1 - settings.semanticWeight) * normalizedLexical[index]
                    + settings.semanticWeight * normalizedSemantic[index]
                return score >= settings.minimumScore ? Hit(id: documents[index].id, score: score) : nil
            }
            return ranked(mixed, limit: limit)
        } catch {
            return fallback(.embeddingFailed(String(describing: error)), lexical: lexical, limit: limit)
        }
    }

    private func fallback(_ reason: Fallback, lexical: [Hit], limit: Int) -> [Hit] {
        onEvent(.lexicalFallback(reason))
        return ranked(lexical.filter { $0.score >= Self.minimumScore }, limit: limit)
    }

    private func ranked(_ hits: [Hit], limit: Int) -> [Hit] {
        Array(hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }.prefix(limit))
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        var dot = 0.0
        var left = 0.0
        var right = 0.0
        for (a, b) in zip(lhs, rhs) {
            dot += Double(a) * Double(b)
            left += Double(a) * Double(a)
            right += Double(b) * Double(b)
        }
        return max(-1, min(1, dot / sqrt(left * right)))
    }

    private static func normalized(_ scores: [Double]) -> [Double] {
        guard let maximum = scores.max(), maximum > 0 else { return scores.map { _ in 0 } }
        let minimum = scores.min() ?? 0
        guard maximum > minimum else { return scores.map { _ in 1 } }
        return scores.map { ($0 - minimum) / (maximum - minimum) }
    }

    private func lexicalScores(_ query: String) -> [Hit] {
        let terms = Set(Self.tokens(query)).sorted()
        guard !terms.isEmpty, averageLength > 0 else { return [] }
        let count = Double(documents.count)
        let hits = documents.compactMap { document -> Hit? in
            var score = 0.0
            for term in terms {
                guard let frequency = document.frequencies[term],
                      let documentFrequency = documentFrequencies[term] else { continue }
                let df = Double(documentFrequency)
                let tf = Double(frequency)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let normalization = Self.k1 * (1 - Self.b + Self.b * Double(document.length) / averageLength)
                score += idf * tf * (Self.k1 + 1) / (tf + normalization)
            }
            return Hit(id: document.id, score: score)
        }
        return hits
    }

    private static let stopwords: Set<String> = Set((
        "a an and are as at be by for from in is it of on or that the this to with "
        + "a al alla alle con da dal della delle di e gli i il in la le lo o per su un una uno"
    ).split(separator: " ").map(String.init))

    private static func tokens(_ text: String) -> [String] {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
        var tokens: [String] = []
        var word = ""
        for scalar in normalized.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                word.unicodeScalars.append(scalar)
            default:
                if !word.isEmpty, !stopwords.contains(word) { tokens.append(word) }
                word = ""
            }
        }
        if !word.isEmpty, !stopwords.contains(word) { tokens.append(word) }
        return tokens
    }
}

/// SearchDocument is immutable text indexed independently from capability contracts.
public struct SearchDocument: Sendable {
    public let id: String
    public let text: String
    let vectorText: String

    public init(id: String, text: String) {
        self.init(id: id, text: text, vectorText: text)
    }

    init(id: String, text: String, vectorText: String) {
        self.id = id
        self.text = text
        self.vectorText = vectorText
    }
}

/// CapabilitySearch adapts a frozen catalogue to the shared document retrieval algorithm.
public struct CapabilitySearch: Sendable {
    public struct Hit: Sendable, Equatable {
        public let id: CapabilityID
        public let score: Double
    }

    public typealias Fallback = DocumentSearch.Fallback
    public typealias Event = DocumentSearch.Event
    typealias Settings = DocumentSearch.Settings
    public static let maximumHits = 5
    public static let minimumScore = DocumentSearch.minimumScore
    public static let semanticWeight = DocumentSearch.semanticWeight
    private let searchIndex: DocumentSearch

    public init(entries: [CatalogueEntry], vectors: CatalogueVectors? = nil,
                embedding: (any TextEmbedding)? = nil,
                onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.init(entries: entries, vectors: vectors, embedding: embedding, settings: Settings(), onEvent: onEvent)
    }

    init(entries: [CatalogueEntry], vectors: CatalogueVectors?, embedding: (any TextEmbedding)?,
         settings: Settings, onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        let documents = entries.map { entry in
            let contract = entry.contract
            let properties = contract.inputSchema["properties"].object?.keys.sorted() ?? []
            let text = ([contract.id.rawValue, contract.group, contract.description] + properties
                + entry.exampleQuestions).joined(separator: " ")
            return SearchDocument(id: contract.id.rawValue, text: text, vectorText: CatalogueVectors.text(for: entry))
        }
        searchIndex = DocumentSearch(documents: documents, vectors: vectors, embedding: embedding,
                                     settings: settings, onEvent: onEvent)
    }

    @concurrent
    public func search(_ query: String, limit: Int) async -> [Hit] {
        await searchIndex.search(query, limit: min(limit, Self.maximumHits)).map { Hit(id: .init(rawValue: $0.id), score: $0.score) }
    }
}

/// TextEmbedding supplies ordered vectors from the process-wide embedding model without exposing its engine.
/// The model identity must include the revision and embedding space, and remain constant for this adapter's lifetime.
/// Catalogue preparation uses a document adapter; search uses a query adapter of the same space.
public protocol TextEmbedding: Sendable {
    var modelID: String { get }
    func vectors(for texts: [String]) async throws -> [[Float]]
}
