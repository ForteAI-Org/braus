import ApplicationServices
@testable import AccessibilityFacts
import Testing

@Suite("NativeAccessibility identity")
struct NativeAccessibilityIdentityTests {
    @Test func leastRecentlyUsedHandleIsEvicted() {
        let registry = NativeAccessibilityIdentity.Tokens(capacity: 3)
        let nodes = (10000..<10003).map { AXUIElementCreateApplication(Int32($0)) }
        let original = nodes.map { registry.token(for: $0) }
        #expect(registry.token(for: nodes[0]) == original[0])
        _ = registry.token(for: AXUIElementCreateApplication(10003))
        #expect(registry.token(for: nodes[0]) == original[0])
        #expect(registry.token(for: nodes[1]) != original[1])
        for pid in 10004..<10100 {
            _ = registry.token(for: AXUIElementCreateApplication(Int32(pid)))
            #expect(registry.count == 3)
        }
        #expect(registry.token(for: AXUIElementCreateApplication(10000)) != original[0])
    }
}
