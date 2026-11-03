import CryptoKit
import Foundation
import Memory
import Testing

@Suite("Digest16")
struct Digest16Tests {
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb924"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223"),
    ])
    func knownVectors(text: String, hexadecimal: String) {
        let digest = Digest16.of(text)
        #expect(digest.count == 16)
        #expect(digest.map { String(format: "%02x", $0) }.joined() == hexadecimal)
    }

    @Test
    func exactUTF8IncludingEmbeddedZero() {
        let text = "é\u{0}🧠"
        #expect(Digest16.of(text) == Data(SHA256.hash(data: Data(text.utf8)).prefix(16)))
        #expect(Digest16.of(text) != Digest16.of("é"))
        #expect(Digest16.of("é") != Digest16.of("e\u{301}"))
    }
}
