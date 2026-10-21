import CryptoKit
import Darwin
import Foundation
import LocalMCP

/// RefusalFile is the refusals of every context in one 0600 JSON file (`refusals.json`) in the support folder:
/// per context key the tool and the salted digest of the refused arguments, and the file's random salt.
nonisolated struct RefusalFile: Sendable {

    let url: URL
    let context: String
    let salt: String

    /// The salt of a barrier with no file: one per process.
    static let processSalt = UUID().uuidString

    private struct Stored: Codable {
        var salt: String
        var refusals: [String: Entry]
    }

    private struct Entry: Codable {
        let tool: String
        let digest: String
    }

    init(folder: URL, context: String) {
        let url = folder.appending(path: "refusals.json")
        self.url = url
        self.context = context
        let initialized = try? Self.locked(url) {
            if let stored = try Self.read(url) { return stored.salt }
            let stored = Stored(salt: UUID().uuidString, refusals: [:])
            try Self.write(stored, to: url)
            return stored.salt
        }
        salt = initialized ?? UUID().uuidString
    }

    private static func read(_ url: URL) throws -> Stored? {
        do {
            return try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func load() throws -> ActionBarrier.Refused? {
        try Self.locked(url) {
            guard let stored = try Self.read(url), stored.salt == salt else { throw StoreFailure.inconsistentSalt }
            return stored.refusals[context].map { ActionBarrier.Refused(tool: $0.tool, digest: $0.digest) }
        }
    }

    /// Serializes read/modify/replace across processes; a separate lock survives atomic replacement of the JSON file.
    private static func locked<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StoreFailure.lockUnavailable }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw StoreFailure.lockUnavailable }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func write(_ stored: Stored, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stored).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Writes this context's refusal, preserving all other contexts under the same cross-process lock.
    func save(_ refused: ActionBarrier.Refused?) -> Bool {
        do {
            try Self.locked(url) {
                guard var stored = try Self.read(url), stored.salt == salt else { throw StoreFailure.inconsistentSalt }
                stored.refusals[context] = refused.map { Entry(tool: $0.tool, digest: $0.digest) }
                try Self.write(stored, to: url)
            }
            return true
        } catch {
            return false
        }
    }

    private enum StoreFailure: Error {
        case lockUnavailable, inconsistentSalt
    }

    static func digest(of arguments: JSONValue, salt: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(arguments)) ?? Data()
        return SHA256.hash(data: Data(salt.utf8) + data).map { String(format: "%02x", $0) }.joined()
    }
}
