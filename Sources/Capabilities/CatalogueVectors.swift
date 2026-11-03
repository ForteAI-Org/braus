import CryptoKit
import Darwin
import Foundation

/// CatalogueVectors stores validated catalogue vectors by text digest and embedding space identity.
/// The composition owns its location and preparation task; no model or task is retained here.
public struct CatalogueVectors: Sendable {
    public let modelID: String
    private var values: [String: [Float]]

    /// Failure identifies invalid cache contents or an embedding result that cannot be compared safely.
    public enum Failure: Error, Sendable {
        case invalidContents, differentModel, invalidVectors
        case cleanupFailed(primary: String, cleanup: String)
    }

    /// Event reports a recoverable cache read failure before entries are calculated again.
    public enum Event: Sendable, Equatable {
        case cacheUnavailable(String)
    }

    private init(modelID: String, values: [String: [Float]]) {
        self.modelID = modelID
        self.values = values
    }

    private struct Storage: Codable {
        let schema: Int
        let modelID: String
        let values: [String: [Float]]
    }

    /// Loads one model's cache. A different space, damaged JSON or invalid vector throws.
    public static func load(from file: URL, modelID: String) throws -> CatalogueVectors {
        let result = try JSONDecoder().decode(Storage.self, from: Data(contentsOf: file))
        guard result.modelID == modelID else { throw Failure.differentModel }
        guard result.schema == 1,
              result.values.keys.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }),
              valid(Array(result.values.values)) else { throw Failure.invalidContents }
        return Self(modelID: result.modelID, values: result.values)
    }

    /// Replaces the destination atomically with a private file. Failed writes leave the old destination intact.
    /// The caller creates the parent directory and serializes writers to the same destination.
    public func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Storage(schema: 1, modelID: modelID, values: values))
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".catalogue-\(UUID().uuidString)")
        let descriptor = temporary.withUnsafeFileSystemRepresentation {
            guard let path = $0 else { errno = EINVAL; return CInt(-1) }
            return Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var closed = false
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            closed = true
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                file.withUnsafeFileSystemRepresentation { destination in Darwin.rename(source, destination) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            let primary = error
            do {
                if !closed { try handle.close() }
                try FileManager.default.removeItem(at: temporary)
            } catch {
                throw Failure.cleanupFailed(primary: String(describing: primary), cleanup: String(describing: error))
            }
            throw primary
        }
    }

    /// Returns a vector only for the entry's current text; schema changes alone do not invalidate text vectors.
    public func vector(for entry: CatalogueEntry) -> [Float]? { values[Self.key(entry)] }

    /// Returns a vector for exact UTF-8 text in this model's embedding space.
    public func vector(forText text: String) -> [Float]? { values[Self.key(text)] }

    /// Adds a validated vector to the aggregate snapshot. The composition serializes persistence.
    public mutating func insert(_ vector: [Float], forText text: String) throws {
        let existing = values.values.first.map { [$0, vector] } ?? [vector]
        guard Self.valid(existing) else { throw Failure.invalidVectors }
        values[Self.key(text)] = vector
    }

    /// Embeds only missing content, discarding removed entries and vectors from a different model.
    /// A partial or invalid result throws without publishing a partially updated value.
    public static func prepare(
        entries: [CatalogueEntry],
        embedding: any TextEmbedding,
        cached: CatalogueVectors? = nil
    ) async throws -> CatalogueVectors {
        try await prepare(texts: entries.map { text(for: $0) }, embedding: embedding, cached: cached)
    }

    /// Prepares the union of catalogue and guide texts with a single embedding adapter and cache writer.
    /// Only the supplied live content survives; unchanged text is reused across guide revisions.
    public static func prepare(
        texts: [String],
        embedding: any TextEmbedding,
        cached: CatalogueVectors? = nil
    ) async throws -> CatalogueVectors {
        var result = Self(modelID: embedding.modelID, values: [:])
        var missing: [(String, String)] = []
        var seen: Set<String> = []
        for text in texts {
            let key = key(text)
            guard seen.insert(key).inserted else { continue }
            if cached?.modelID == embedding.modelID, let vector = cached?.vector(forText: text) {
                try result.insert(vector, forText: text)
            } else { missing.append((key, text)) }
        }
        if !missing.isEmpty {
            let vectors = try await embedding.vectors(for: missing.map(\.1))
            guard vectors.count == missing.count else { throw Failure.invalidVectors }
            for (item, vector) in zip(missing, vectors) { try result.insert(vector, forText: item.1) }
        }
        return result
    }

    /// Recovers unreadable caches explicitly, then saves a complete replacement. Inference and write failures throw.
    public static func prepare(
        entries: [CatalogueEntry],
        embedding: any TextEmbedding,
        file: URL,
        onEvent: @Sendable (Event) -> Void = { _ in }
    ) async throws -> CatalogueVectors {
        let cached: CatalogueVectors?
        do {
            cached = try load(from: file, modelID: embedding.modelID)
        } catch {
            onEvent(.cacheUnavailable(String(describing: error)))
            cached = nil
        }
        let result = try await prepare(entries: entries, embedding: embedding, cached: cached)
        try result.save(to: file)
        return result
    }

    /// Names a model-specific file inside the support directory supplied by the composition.
    public static func file(in directory: URL, modelID: String) -> URL {
        let name = modelID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let digest = SHA256.hash(data: Data(modelID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("catalogue-\(String(name).prefix(100))-\(digest.prefix(16)).json")
    }

    /// Returns the exact embedding text in the order fixed by the catalogue contract.
    public static func text(for entry: CatalogueEntry) -> String {
        ([entry.contract.id.rawValue, entry.contract.group, entry.contract.description] + entry.exampleQuestions)
            .joined(separator: "\n")
    }

    private static func key(_ entry: CatalogueEntry) -> String {
        Self.key(text(for: entry))
    }

    private static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func valid(_ vectors: [[Float]]) -> Bool {
        guard let dimensions = vectors.first?.count else { return true }
        return dimensions > 0 && vectors.allSatisfy {
            $0.count == dimensions && $0.allSatisfy(\.isFinite) && $0.contains { $0 != 0 }
        }
    }
}
