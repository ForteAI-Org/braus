import Foundation
import Testing
@testable import ModelTransports

@Suite("Canonical HTTP request bodies")
struct CanonicalHTTPTests {
    @Test
    func nestedKeysAreSortedForEveryInsertionOrder() throws {
        let url = try #require(URL(string: "https://example.invalid"))
        var reference: Data?
        for rotation in 0..<20 {
            var body: [String: Any] = [:]
            for offset in 0..<30 {
                body[String(format: "key%02d", (rotation + offset) % 30)] = ["z": 1, "a": 2]
            }
            let request = try HTTPTransport.request(url, headers: [:], body: body, timeout: 1)
            let expected = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            #expect(request.httpBody == expected)
            if let reference { #expect(request.httpBody == reference) }
            reference = expected
        }
    }
}
