import ApplicationServices
import Foundation
import SeatCore
@testable import SeatSession
import Testing

@MainActor
@Suite("Refusals and notes omit element values")
struct RefusalValueTests {

    typealias Element = RemoteContentActuationTests.Element

    static let document = String(repeating: "q7Zd2Pk9w4Lm", count: 7)
    static let fileName = "private-export-847291.txt"
    static let rowCount = "restricted-items-58321946"
    static var values: [String] { [document, fileName, rowCount] }

    private static func expectNoValues(_ lines: [String]) {
        for value in values {
            let characters = Array(value)
            for start in 0...(characters.count - 8) {
                let fragment = String(characters[start..<(start + 8)])
                #expect(lines.allSatisfy { !$0.contains(fragment) })
            }
        }
    }

    @Test("Text views, file name fields and counted rows omit their values",
          arguments: [kAXTextAreaRole, kAXTextFieldRole, kAXRowRole, kAXButtonRole], [1, 3])
    func nodeRefusals(role: String, count: Int) throws {
        #expect(Self.document.count == 84)
        let endpoint = try RemoteContentActuationTests.remoteEndpoint(surface: FakeGeometry.identity(windowNumber: 878))
        let value = role == kAXTextAreaRole ? Self.document
            : role == kAXTextFieldRole ? Self.fileName : Self.rowCount
        let node = Element(role, window: .windowless, processID: 7_001, value: value)
        var notes: [String] = []
        let actuator = RemoteContentActuator<Element>(
            path   : { _, _ in .success([node]) },
            role   : { $0.role },
            actions: { _ in [kAXPressAction] },
            value  : { $0.value },
            perform: { _, _ in
                Issue.record("A refused target must not be pressed")
                return .failure
            },
            write  : { _, write in
                #expect(role == kAXRowRole && count == 1 && write == .selected)
                return .success
            },
            labels : { [$0.value].compactMap { $0 } },
            note   : { notes.append($0) }
        )
        let result = actuator.actuate(
            RemoteContentActuationTests.click(count: count),
            endpoint : endpoint,
            expecting: String(repeating: "R", count: 48)
        )
        guard case .failure(let refusal) = result else {
            Issue.record("Expected a refusal")
            return
        }
        Self.expectNoValues([refusal.description] + notes)
        switch refusal {
            case .wrongElement(let requested, let foundRole):
                #expect(requested == String(repeating: "R", count: 48))
                #expect(foundRole == role)
                #expect(refusal.description.count <= 160)
            case .selectionNotVerified:
                #expect(role == kAXRowRole && count == 1)
            case .unsupportedRole:
                #expect(count == 3 && (role == kAXRowRole || role == kAXButtonRole))
            default:
                Issue.record("Unexpected refusal: \(refusal)")
        }
        if role == kAXButtonRole && count == 1 { #expect(!notes.isEmpty) }
    }

    @Test("Every refusal description omits node values")
    func allDescriptions() {
        let refusals: [RemoteContentActuationRefusal] = [
            .gestureUnmeasured, .pixelDropdown, .noElementAtPoint, .outsideRemoteContent,
            .unreadable, .fieldRequiresClick, .columnView, .webContent,
            .wrongElement(requested: Self.document, foundRole: kAXTextAreaRole),
            .unsupportedRole(kAXRowRole), .unsupportedRole(kAXButtonRole),
            .unsupportedRole(kAXTextAreaRole), .unsupportedRole(kAXUnknownRole),
            .opensMenu(kAXPopUpButtonRole), .selectionNotVerified(kAXRowRole),
            .selectionNotVerified(kAXListRole), .selectedNotOpened(code: nil),
            .selectedNotOpened(code: AXError.actionUnsupported.rawValue),
            .selectedNotOpened(code: AXError.failure.rawValue),
            .actionRefused(action: kAXPressAction, code: AXError.actionUnsupported.rawValue),
            .actionRefused(action: kAXPressAction, code: AXError.failure.rawValue)
        ]
        Self.expectNoValues(refusals.map(\.description))
    }

    @Test("The wrong element sentence stays bounded with a 48 character name and role")
    func wrongElementStaysBounded() {
        let refusal = RemoteContentActuationRefusal.wrongElement(
            requested: String(repeating: "R", count: 48),
            foundRole: String(repeating: "X", count: 48)
        )
        #expect(refusal.description.count <= 160)
    }

    @Test("State verification notes omit names and values",
          arguments: ["unreadable", "already on", "lost first", "lost second", "unchanged", "changed"])
    func stateNotes(state: String) throws {
        let endpoint = try RemoteContentActuationTests.remoteEndpoint(surface: FakeGeometry.identity(windowNumber: 878))
        let node = Element(kAXCheckBoxRole, window: .windowless, processID: 7_001, value: Self.document)
        let helper = Element(kAXButtonRole, window: .windowless, processID: 7_001, parent: node)
        var notes: [String] = []
        var reads = 0
        let actuator = RemoteContentActuator<Element>(
            path   : { _, _ in .success([node]) },
            role   : { element in
                if element == node && state == "already on" { return kAXRadioButtonRole }
                return element.role
            },
            actions: { _ in [kAXPressAction] },
            value  : { $0.value },
            perform: { _, _ in .success },
            write  : { _, _ in .success },
            parent : { $0.parent },
            children: { $0 == node ? [helper] : [] },
            label  : { _ in Self.fileName },
            toggleValue: { _ in
                reads += 1
                if state == "unreadable" || state == "lost first" && reads > 1
                    || state == "lost second" && reads > 2 { return nil }
                return state == "already on" || state == "changed" && reads > 1
            },
            note: { notes.append($0) }
        )
        _ = try actuator.actuate(
            RemoteContentActuationTests.click(count: 1),
            endpoint   : endpoint,
            prefersHost: true
        ).get()
        #expect(!notes.isEmpty)
        Self.expectNoValues(notes)
    }

    @Test("Replacing a mismatched control omits both app names from notes")
    func replacementNotes() throws {
        let pane = try AppleExtensionPressTests.pane(hostHasIt: false)
        pane.remote.title = Self.document
        let sibling = Element(
            kAXButtonRole,
            window   : pane.remote.window,
            processID: pane.remote.processID,
            parent   : pane.remote.parent,
            actions  : [kAXPressAction]
        )
        sibling.title = Self.fileName
        _ = try pane.actuator.actuate(
            RemoteContentActuationTests.click(count: 1),
            endpoint : pane.endpoint,
            expecting: Self.fileName
        ).get()
        #expect(sibling.performed == [kAXPressAction])
        #expect(!pane.notes.lines.isEmpty)
        Self.expectNoValues(pane.notes.lines)
    }
}
