import ApplicationServices
@testable import AccessibilityFacts
import Foundation
import Memory
import PerceptionCore
import Synchronization
import Testing

struct ValueReadingAfterTests {
    @Test(arguments: [
        ("AXTextField", "Token", "eyJabcdefgh.abcdefgh.abcdefgh", true),
        ("AXTextField", "Account", "GB82 WEST 1234 5698 7654 32", true),
        ("AXStaticText", "Caption", "sk-aaaaaaaaaaaaaaaa", true),
        ("AXTextField", "Key", "C major", false)
    ])
    func text(role: String, label: String, value: String, withheld: Bool) {
        let reads = Mutex(0)
        let reader = LiveAccessibilityReader(valueGuard: SensitivityClassifier().valueGuard,
                                             copyAttributeValue: { _, attribute, result in
            switch attribute as String {
            case kAXRoleAttribute: result.pointee = role as CFString
            case kAXSubroleAttribute: result.pointee = "" as CFString
            case kAXTitleAttribute: result.pointee = label as CFString
            case kAXValueAttribute:
                reads.withLock { $0 += 1 }
                result.pointee = value as CFString
            default: return .noValue
            }
            return .success
        })
        #expect(reader.value(AXUIElementCreateApplication(0)) == (withheld ? nil : value))
        #expect(reads.withLock { $0 } == 1)
    }
}

struct NumericValueReadingTests {
    @Test(arguments: [("PIN", "AXTextField", true, 1), ("Volume", "AXTextField", false, 1),
                      ("Volume", "AXSecureTextField", true, 0)])
    func number(label: String, role: String, withheld: Bool, expectedReads: Int) {
        let reads = Mutex(0)
        let reader = LiveAccessibilityReader(valueGuard: SensitivityClassifier().valueGuard,
                                             copyAttributeValue: { _, attribute, result in
            switch attribute as String {
            case kAXRoleAttribute: result.pointee = role as CFString
            case kAXSubroleAttribute: result.pointee = "" as CFString
            case kAXTitleAttribute: result.pointee = label as CFString
            case kAXValueAttribute:
                reads.withLock { $0 += 1 }
                result.pointee = NSNumber(value: 1234)
            default: return .noValue
            }
            return .success
        })
        #expect(reader.numericValue(AXUIElementCreateApplication(0)) == (withheld ? nil : 1234))
        #expect(reads.withLock { $0 } == expectedReads)
    }
}
