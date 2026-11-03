import CryptoKit
import Foundation

/// Digest16 fingerprints exact UTF-8 text with the first 16 bytes of SHA-256.
/// Callers own the canonical form; this function does not normalize or truncate text.
public enum Digest16 {
    public static func of(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)).prefix(16))
    }
}
