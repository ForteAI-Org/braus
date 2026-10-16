import ApplicationServices
@testable import AccessibilityFacts
import Foundation
import Testing

/// M2: what one read of a node's children says. Only a genuine absence is a leaf; a timeout is retried once;
/// every other failure, and an answer that is no list of elements, is a list nobody read.
@Suite("Reading a node's children (M2)")
struct ChildrenAnswerTests {

    typealias Answer = LiveAccessibilityReader.ChildrenAnswer

    @Test("an empty list, noValue and attributeUnsupported are a leaf")
    func leaf() {
        #expect(Answer(.success, [] as CFArray) == .listed([]))
        #expect(Answer(.noValue, nil) == .listed([]))
        #expect(Answer(.attributeUnsupported, nil) == .listed([]))
    }

    @Test("a timeout is worth one retry")
    func timeout() {
        #expect(Answer(.cannotComplete, nil) == .retry)
    }

    @Test("notImplemented, invalidUIElement, any other code, no value and a value of another shape are a list nobody read",
          arguments: [AXError.notImplemented, .invalidUIElement, .failure, .apiDisabled, .illegalArgument])
    func unread(code: AXError) {
        #expect(Answer(code, nil) == .unread)
    }

    @Test("a success with nothing or with something that is no list of elements was not read")
    func malformed() {
        #expect(Answer(.success, nil) == .unread)
        #expect(Answer(.success, "Esporta" as CFString) == .unread)
        #expect(Answer(.success, ["Esporta"] as CFArray) == .unread)
    }
}
