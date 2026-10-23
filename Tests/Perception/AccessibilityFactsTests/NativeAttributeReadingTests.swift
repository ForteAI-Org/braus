import ApplicationServices
import Foundation
@testable import AccessibilityFacts
import PerceptionCore
import Testing

@Suite("Native attribute result and type preservation")
struct NativeAttributeReadingTests {

    @Test("successful empty text remains distinct from every unavailable result")
    func emptyAndUnavailable() {
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: "" as CFString) == .value(.string("")))
        #expect(LiveAccessibilityReader.nativeReading(.noValue, reference: nil) == .noValue)
        #expect(LiveAccessibilityReader.nativeReading(.attributeUnsupported, reference: nil) == .unsupported)
        #expect(LiveAccessibilityReader.nativeReading(.cannotComplete, reference: nil) == .timedOut)
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: nil) == .emptyReply)
        #expect(LiveAccessibilityReader.nativeReading(.invalidUIElement, reference: nil)
                == .failed(code: Int(AXError.invalidUIElement.rawValue)))
    }

    @Test("boolean, numeric and textual encodings retain their native types")
    func scalarTypes() {
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: kCFBooleanFalse) == .value(.boolean(false)))
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: kCFBooleanTrue) == .value(.boolean(true)))
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: NSNumber(value: 0))
                == .value(.number(representation: "0")))
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: NSNumber(value: 0.5))
                == .value(.number(representation: "0.5")))
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: "false" as CFString)
                == .value(.string("false")))
        #expect(LiveAccessibilityReader.nativeReading(.success, reference: "Selected" as CFString)
                == .value(.string("Selected")))
    }

    @Test("unrecognized payload types stay typed diagnostics and cannot become text or false")
    func otherType() {
        let reading = LiveAccessibilityReader.nativeReading(.success, reference: [] as CFArray)
        #expect(reading == .value(.other(typeID: UInt64(CFArrayGetTypeID()))))
        #expect(reading.diagnosticText.hasPrefix("other-type:"))
    }
    @Test("an expired raw-fact deadline starts no native attribute request")
    func deadlineBeforeRead() throws {
        let node = AXUIElementCreateApplication(Int32.max)
        let reading = LiveAccessibilityReader().nativeControlFacts(node, isPastDeadline: { true })
        let facts = try #require(reading)
        #expect(facts.role == .notRead && facts.subrole == .notRead)
        #expect(facts.value == .notRead && facts.selected == .notRead)
        #expect(facts.ownerProcessID == nil)
    }

}
