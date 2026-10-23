import CoreFoundation
import Foundation
import Testing
@testable import AccessibilityFacts

@Suite("Native numeric state")
struct NativeNumericStateTests {

    @Test("native booleans and exact numeric 0, 1 and 2 preserve their state")
    func exactStates() {
        #expect(CFGetTypeID(NSNumber(value: false)) == CFBooleanGetTypeID())
        #expect(CFGetTypeID(NSNumber(value: true)) == CFBooleanGetTypeID())
        #expect(LiveAccessibilityReader.numericStateValue(NSNumber(value: false)) == 0)
        #expect(LiveAccessibilityReader.numericStateValue(NSNumber(value: true)) == 1)
        for value in 0...2 {
            #expect(LiveAccessibilityReader.numericStateValue(NSNumber(value: value)) == value)
            #expect(LiveAccessibilityReader.numericStateValue(NSNumber(value: Double(value))) == value)
        }
    }

    @Test("fractions, nonfinite numbers and out-of-range values never become a toggle state")
    func invalidNumbers() {
        for value in [-1, 0.5, 1.5, 2.5, 3, Double.greatestFiniteMagnitude, .nan, .infinity, -.infinity] {
            #expect(LiveAccessibilityReader.numericStateValue(NSNumber(value: value)) == nil)
        }
        #expect(LiveAccessibilityReader.numericStateValue(NSNumber(value: Int64.max)) == nil)
        #expect(LiveAccessibilityReader.numericStateValue(NSNumber(value: UInt64.max)) == nil)
    }

    @Test("a text value, including numeric or empty text, is not a native numeric state")
    func textAndUnavailableValues() {
        for value in ["0", "1", "2", "on", "Selected", ""] {
            #expect(LiveAccessibilityReader.numericStateValue(value as NSString) == nil)
        }
        #expect(LiveAccessibilityReader.numericStateValue(nil) == nil)
        #expect(LiveAccessibilityReader.numericStateValue(NSNull()) == nil)
        #expect(LiveAccessibilityReader.numericStateValue(Data() as NSData) == nil)
    }
}
