import ApplicationServices
import CoreGraphics
import Foundation
@testable import MacDriver
import Testing

/// M2: a read that did not succeed is told from a genuine absence. The classifier over `AXError`, a batched
/// answer decoded, and the walk over a source of plain values (`FakeElements`): what did not answer is marked
/// where it is, the siblings keep their paths, the counts are distinct nodes, and a window that answers
/// nothing is an error, never an empty complete read.
@Suite("Reading a Mac window that does not answer (M2)")
struct MacTreeReadTests {

    // MARK: The classifier

    @Test("a whole request that fails is a read that did not succeed, whatever its code",
          arguments: [(AXError.cannotComplete, MacReadFailure.timedOut), (.noValue, .failed(code: -25212)),
                      (.attributeUnsupported, .failed(code: -25205)), (.notImplemented, .failed(code: -25208)),
                      (.invalidUIElement, .failed(code: -25202)), (.failure, .failed(code: -25200))])
    func requestFailure(code: AXError, expected: MacReadFailure) {
        #expect(MacReadFailure.ofRequest(code) == expected)
    }

    @Test("one attribute: only noValue and attributeUnsupported are absent; notImplemented and invalidUIElement prove no absence",
          arguments: [(AXError.noValue, MacReadFailure.MacAttributeAnswer.absent), (.attributeUnsupported, .absent),
                      (.notImplemented, .unread(.failed(code: -25208))), (.invalidUIElement, .unread(.failed(code: -25202))),
                      (.cannotComplete, .unread(.timedOut)), (.failure, .unread(.failed(code: -25200)))])
    func attributeFailure(code: AXError, expected: MacReadFailure.MacAttributeAnswer) {
        #expect(MacReadFailure.ofAttribute(code) == expected)
    }

    // MARK: A batched answer

    private static func axError(_ code: AXError) -> AnyObject {
        var code = code
        return AXValueCreate(.axError, &code)!
    }

    @Test("a batched request that failed, or answered another shape, is the request's failure")
    func batchFailure() {
        let names = [kAXTitleAttribute, kAXValueAttribute]
        #expect(AttributeValues(names: names, result: .cannotComplete, answer: nil).failure == .timedOut)
        #expect(AttributeValues(names: names, result: .success, answer: nil).failure == .malformed)
        #expect(AttributeValues(names: names, result: .success, answer: ["only one"] as CFArray).failure == .malformed)
    }

    @Test("an answered batch keeps each attribute's error apart: a timeout and notImplemented are unread, noValue is absent")
    func attributeErrors() {
        let names = [kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute, kAXDescriptionAttribute, kAXChildrenAttribute,
                     kAXVisibleChildrenAttribute]
        let answer = ["Esporta" as NSString, Self.axError(.cannotComplete), Self.axError(.noValue),
                      Self.axError(.notImplemented), "not a list" as NSString, ["not an element"] as NSArray] as CFArray
        let values = AttributeValues(names: names, result: .success, answer: answer)
        #expect(values.failure == nil)
        #expect(values.string(kAXTitleAttribute) == "Esporta")
        #expect(values.unread == [kAXValueAttribute: .timedOut, kAXDescriptionAttribute: .failed(code: -25208)])
        #expect(values.string(kAXHelpAttribute) == nil && values.unread[kAXHelpAttribute] == nil, "noValue: absent")
        if case .failure(.malformed) = values.list(kAXChildrenAttribute) {} else { Issue.record("a list of another shape is malformed") }
        if case .failure(.malformed) = values.list(kAXVisibleChildrenAttribute) {} else { Issue.record("a list of no elements is malformed") }
        if case .success(let none) = values.list(kAXVisibleRowsAttribute) { #expect(none.isEmpty) } else { Issue.record("absent list") }
    }

    // MARK: The walk

    /// Elements are numbers; each answers what the test set, a timeout by default for a number not set.
    struct FakeElements: MacElementSource {
        var reads: [Int: Result<MacElementRead<Int>, MacReadFailure>]
        var actionNames: [Int: Result<[String], MacReadFailure>] = [:]
        var headers: [Int: Result<Int?, MacReadFailure>] = [:]

        func read(_ element: Int, timeout: Float) -> Result<MacElementRead<Int>, MacReadFailure> {
            reads[element] ?? .failure(.timedOut)
        }
        func actions(_ element: Int) -> Result<[String], MacReadFailure> { actionNames[element] ?? .success([]) }
        func header(_ element: Int) -> Result<Int?, MacReadFailure> { headers[element] ?? .success(nil) }
    }

    private static func node(_ role: String, _ title: String? = nil, children: [Int] = [], rows: [Int] = [],
                             unlisted: MacReadFailure? = nil, unread: [String: MacReadFailure] = [:])
        -> Result<MacElementRead<Int>, MacReadFailure> {
        .success(MacElementRead(node: MacTreeNode(role: role, title: title),
                                children: unlisted.map { .failure($0) } ?? .success(children),
                                visibleRows: rows, unread: unread))
    }

    private static func read(_ source: FakeElements) throws -> MacTreeRead {
        try MacTreeWalk.read(window: 0, index: 0, source: source, limits: .standard)
    }

    @Test("a child whose whole batch timed out is a placeholder at its slot: its siblings keep their paths, it is no visited node")
    func placeholder() throws {
        let read = try Self.read(FakeElements(reads: [
            0: Self.node("AXWindow", "Export", children: [1, 2, 3]),
            1: Self.node("AXButton", "Annulla"), 3: Self.node("AXButton", "OK"),
        ]))
        #expect(read.window.children.map(\.path) == [[0], [1], [2]])
        #expect(read.window.children.map(\.title) == ["Annulla", nil, "OK"])
        let lost = read.window.children[1]
        #expect(lost.role == "AXUnknown" && lost.frame == nil && lost.children.isEmpty)
        #expect(lost.unread == MacUnread(cause: .timedOut, element: true))
        #expect(read.nodesVisited == 3, "the window and the two buttons answered")
        #expect(read.unread == MacTreeRead.Unread(nodes: 1, elements: 1, cause: .timedOut))
    }

    @Test("an attribute, the children or the action names that did not answer mark their node; the rest of it is kept")
    func partialNodes() throws {
        let read = try Self.read(FakeElements(
            reads: [
                0: Self.node("AXWindow", "Export", children: [1, 2, 3, 4]),
                1: Self.node("AXUnknown", "Formato", unread: [kAXRoleAttribute: .timedOut]),
                2: Self.node("AXTextField", "Nome", unread: [kAXValueAttribute: .timedOut]),
                3: Self.node("AXGroup", "Opzioni", unlisted: .timedOut),
                4: Self.node("AXButton", "OK"),
            ],
            actionNames: [4: .failure(.failed(code: -25200))]
        ))
        let marks = read.window.children.map(\.unread)
        #expect(marks[0] == MacUnread(cause: .timedOut, attributes: [kAXRoleAttribute]))
        #expect(marks[1] == MacUnread(cause: .timedOut, attributes: [kAXValueAttribute]))
        #expect(marks[2] == MacUnread(cause: .timedOut, children: true))
        #expect(marks[3] == MacUnread(cause: .failed(code: -25200), actions: true))
        #expect(read.window.children[0].title == "Formato" && read.window.children[1].title == "Nome")
        #expect(read.unread == MacTreeRead.Unread(nodes: 4, branches: 1, attributes: 3, cause: .timedOut))
    }

    @Test("a branch not listed keeps its known siblings and their children")
    func knownSiblings() throws {
        let read = try Self.read(FakeElements(reads: [
            0: Self.node("AXWindow", "Export", children: [1, 2]),
            1: Self.node("AXGroup", "Persa", unlisted: .timedOut),
            2: Self.node("AXGroup", "Nota", children: [21, 22]),
            21: Self.node("AXButton", "Uno"), 22: Self.node("AXButton", "Due"),
        ]))
        #expect(read.window.children[1].children.map(\.title) == ["Uno", "Due"])
        #expect(read.window.children[1].children.map(\.path) == [[1, 0], [1, 1]])
        #expect(read.unread == MacTreeRead.Unread(nodes: 1, branches: 1, cause: .timedOut))
    }

    @Test("a node whose children and an attribute both failed is one node, one branch, one with attributes: never summed")
    func distinctNodes() throws {
        let read = try Self.read(FakeElements(reads: [
            0: Self.node("AXWindow", "Export", children: [1]),
            1: Self.node("AXGroup", "Opzioni", unlisted: .timedOut, unread: [kAXHelpAttribute: .timedOut]),
        ]))
        #expect(read.unread == MacTreeRead.Unread(nodes: 1, branches: 1, attributes: 1, cause: .timedOut))
    }

    @Test("a true empty and genuinely absent attributes are a complete read: no mark anywhere")
    func trueEmpty() throws {
        let read = try Self.read(FakeElements(reads: [
            0: Self.node("AXWindow", "Export", children: [1, 2]),
            1: Self.node("AXGroup", children: []), 2: Self.node("AXStaticText"),
        ]))
        #expect(!read.window.hasUnreadParts && read.unread.isEmpty && read.nodesVisited == 3)
    }

    @Test("a table's header that did not answer holds its place, so the rows keep the paths a full read gives them")
    func headerPlace() throws {
        let read = try Self.read(FakeElements(
            reads: [
                0: Self.node("AXWindow", "Mail", children: [1]),
                1: Self.node("AXTable", "Messaggi", children: [10, 11, 12], rows: [11, 12]),
                11: Self.node("AXRow", "Uno"), 12: Self.node("AXRow", "Due"),
            ],
            headers: [1: .failure(.timedOut)]
        ))
        let table = read.window.children[0]
        #expect(table.children.map(\.path) == [[0, 0], [0, 1], [0, 2]])
        #expect(table.children[0].unread == MacUnread(cause: .timedOut, element: true))
        #expect(table.children.dropFirst().map(\.title) == ["Uno", "Due"])
    }

    @Test("the window answering nothing, or not listing its children, is an error: never an empty complete window",
          arguments: [MacReadFailure.timedOut, .failed(code: -25200)])
    func windowUnreadable(failure: MacReadFailure) {
        #expect(throws: MacTreeFailure.windowUnreadable(index: 0, cause: failure)) {
            try Self.read(FakeElements(reads: [0: .failure(failure)]))
        }
        #expect(throws: MacTreeFailure.windowUnreadable(index: 0, cause: failure)) {
            try Self.read(FakeElements(reads: [0: Self.node("AXWindow", "Export", unlisted: failure)]))
        }
    }

    @Test("the window's title not answering makes the read partial, not an error")
    func windowTitleUnread() throws {
        let read = try Self.read(FakeElements(reads: [
            0: Self.node("AXWindow", children: [1], unread: [kAXTitleAttribute: .timedOut]),
            1: Self.node("AXButton", "OK"),
        ]))
        #expect(read.window.unread == MacUnread(cause: .timedOut, attributes: [kAXTitleAttribute]))
        #expect(read.window.children.map(\.title) == ["OK"])
    }
}
