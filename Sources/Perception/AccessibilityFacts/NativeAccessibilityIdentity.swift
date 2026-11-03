import ApplicationServices
import Foundation

/// NativeAccessibilityIdentity shares opaque tokens between perception and focus by AX handle equality.
/// The registry evicts the least recently used handle at capacity. An evicted handle gets a fresh token
/// if read again; equality alone cannot detect replacement of a remote element before eviction.
package enum NativeAccessibilityIdentity {
    private static let tokens = Tokens(capacity: 4_096)

    package static func token(for node: AXUIElement) -> String {
        tokens.token(for: node)
    }

    /// The lock owns all retained handles and recency state; handles are compared, never messaged.
    final class Tokens: @unchecked Sendable {
        private let lock = NSLock()
        private let capacity: Int
        private var entries: [AXUIElement: String] = [:]
        private var recency: [AXUIElement] = []

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
        }

        var count: Int { lock.withLock { entries.count } }

        func token(for node: AXUIElement) -> String {
            lock.withLock {
                if let token = entries[node] {
                    recency.removeAll { $0 == node }
                    recency.append(node)
                    return token
                }
                if entries.count == capacity {
                    entries.removeValue(forKey: recency.removeFirst())
                }
                let token = "native:\(UUID().uuidString)"
                entries[node] = token
                recency.append(node)
                return token
            }
        }
    }
}
