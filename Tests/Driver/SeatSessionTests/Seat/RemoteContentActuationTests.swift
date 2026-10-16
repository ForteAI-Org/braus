//
//  RemoteContentActuationTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import ApplicationServices
import CoreGraphics
import EngineCore
import Foundation
import SeatCore
import SeatInput
@testable import SeatDriving
@testable import SeatSession
import Testing

/// A click or a text on an out of process panel's content, acted on through
/// accessibility and never posted (ADR 0031).
///
/// The panel, its endpoint and the seat are `GestureEndpointRoutingTests`'s.
/// The accessibility tree is a set of elements this suite writes, read and
/// written through the shipping path proof and the shipping action mapping,
/// so what is on trial is everything but the AX calls themselves. Nothing here
/// says what a real panel does with them: that is the measurement in the ADR.
@MainActor
@Suite("Remote panel content actuated through accessibility")
struct RemoteContentActuationTests {

    /// One accessibility element, with what was done to it. Two are one element only when identical.
    final class Element: Equatable {
        static func == (lhs: Element, rhs: Element) -> Bool { lhs === rhs }

        let role     : String
        var actions  : [String]
        var value    : String?
        var window   : DialogEndpointResolver<Element>.WindowReading
        var processID: Int32
        var parent   : Element?
        var answers  = true
        var frame    : CGRect?
        var title    : String?
        var performed: [String] = []
        var writes   : [RemoteContentActuator<Element>.Write] = []
        var children : [Element] = []
        private var selection = NSRange(location: 0, length: 0)

        /// What an action answers, and whether an `AXSelected` write is read back as taken.
        var performAnswer        = AXError.success
        var onPerform            : ((String) -> Void)?
        /// A checkbox's, switch's or radio button's 0 or 1 `AXValue`.
        var toggle               : Bool?
        var writeAnswer          = AXError.success
        var ignoresSelectedWrite = false

        // A list of items: whether its selected children can be written, what they are, every
        // write, and what a write really does in the application.
        var textSettable = true
        var selectionSettable = false
        // A field's `AXValue`: a file's name in a list is never writable, a field one can edit is.
        var valueSettable     = false
        var selectedChildren : [Element]?
        var selectionWrites  : [[Element]] = []
        var onSelectChildren : (([Element]) -> Void)?
        var selectedFlag     : Bool?
        var defaultButton    : Element?

        // An outline or a table: whether its selected rows can be written, what they are, every
        // write, and what a write really does in the application.
        var rowsSettable = false
        var selectedRows : [Element]?
        var rowWrites    : [[Element]] = []
        var onSelectRows : (([Element]) -> Void)?

        init(
            _ role   : String,
            window   : DialogEndpointResolver<Element>.WindowReading,
            processID: Int32,
            parent   : Element? = nil,
            actions  : [String] = [],
            value    : String? = nil
        ) {
            self.role      = role
            self.window    = window
            self.processID = processID
            self.parent    = parent
            self.actions   = actions
            self.value     = value
            parent?.children.append(self)
        }

        func apply(_ write: RemoteContentActuator<Element>.Write) {
            writes.append(write)
            switch write {
                case .selected: if !ignoresSelectedWrite { selectedFlag = true }
                case .focused: break
                case .selectedTextRange(let location, let length):
                    selection = NSRange(location: location, length: length)
                case .selectedText(let text):
                    value = ((value ?? "") as NSString).replacingCharacters(in: selection, with: text)
                    selection = NSRange(location: selection.location + text.utf16.count, length: 0)
            }
        }
    }

    /// The shipping path proof and action mapping over the elements, with the
    /// hit test answering whatever `hit` names when it is asked, and `window`
    /// the `AXWindows` entry an ordinary window's own content climbs to.
    static func actuator(
        hitting hit: @escaping () -> Element?,
        window     : Element? = nil,
        settle     : @escaping () -> Void = {},
        note       : @escaping (String) -> Void = { _ in },
        searchWindowTree: Bool = false
    ) -> RemoteContentActuator<Element> {
        let windowNode: (Int) -> Element? = { number in
            guard let window, case .window(number) = window.window else { return nil }
            return window
        }
        let resolver = DialogEndpointResolver<Element>(
            nodeAtPoint  : { _ in hit() },
            focusedNode  : { nil },
            children     : { searchWindowTree ? .children($0.children) : .leaf },
            nodeFrame    : { $0.frame },
            nodeWindow   : { _ in nil },
            nodeProcess  : { $0.processID },
            identity     : { _ in nil },
            geometry     : { _, _ in nil },
            windowNode   : windowNode,
            parent       : { $0.parent },
            windowReading: { $0.window }
        )
        return RemoteContentActuator<Element>(
            path   : { point, endpoint in
                endpoint.relation == .remoteContent
                    ? resolver.remoteContentPath(at: point, of: endpoint)
                    : resolver.ownContentPath(at: point, of: endpoint, searchWindowTree: searchWindowTree)
            },
            role   : { $0.answers ? $0.role : nil },
            actions: { $0.actions },
            value  : { $0.value },
            perform: { element, action in
                element.performed.append(action)
                element.onPerform?(action)
                return element.performAnswer
            },
            write  : { element, write in element.apply(write); return element.writeAnswer },
            selectionIsSettable: { node, attribute in
                switch attribute {
                    case kAXSelectedRowsAttribute: node.rowsSettable
                    case kAXValueAttribute       : node.valueSettable
                    case kAXSelectedTextAttribute: node.textSettable
                    default                      : node.selectionSettable
                }
            },
            selection          : { node, attribute in
                attribute == kAXSelectedRowsAttribute ? node.selectedRows : node.selectedChildren
            },
            writeSelection     : { container, attribute, nodes in
                if attribute == kAXSelectedRowsAttribute {
                    container.rowWrites.append(nodes)
                    container.onSelectRows?(nodes)
                } else {
                    container.selectionWrites.append(nodes)
                    container.onSelectChildren?(nodes)
                }
                return .success
            },
            isSelected         : { $0.selectedFlag },
            parent             : { $0.parent },
            children           : { $0.children },
            defaultButton      : { $0.defaultButton },
            windowNode         : windowNode,
            frame              : { $0.frame },
            label              : { $0.title },
            toggleValue        : { $0.toggle },
            settle             : settle,
            note               : note
        )
    }

    /// A Save panel's content drawn in its sheet: a button with a caption, a
    /// name field, a slider, and a sidebar row with its text.
    struct Panel {
        let routing    : GestureEndpointRoutingTests.Panel
        let observation: SeatObservationReference
        let remote     : WindowIdentity
        let sheet      : Element
        let content    : Element
        let caption    : Element
        let button     : Element
        let field      : Element
        let slider     : Element
        let row        : Element
        let rowText    : Element
    }

    final class Hit { var element: Element? }

    static func panel(_ hit: Hit) async throws -> Panel {
        let routing     = try await GestureEndpointRoutingTests.panel()
        let observation = try await observedReference(routing.seat)
        let sheet       = try #require(routing.sheet.reference.identity)
        let geometry    = try GestureEndpointRoutingTests.remoteContent(of: routing)
        let remote      = try #require(geometry.window.identity)
        routing.discovery.answer = .success(try GestureEndpointRoutingTests.endpoint(
            geometry,
            relation      : .remoteContent,
            logicalSurface: sheet,
            generation    : observation.selectionGeneration,
            hostProcessID : routing.host.reference.processID,
            // A parallel run takes longer than a real endpoint lives.
            lifetimeNanoseconds: 60_000_000_000
        ))
        routing.discovery.identities[remote.windowNumber] = remote
        let actuator = Self.actuator { hit.element }
        routing.discovery.actuation = { actuator.actuate($0, endpoint: $1) }

        // Accessibility answers the host's PID for the content, as measured.
        let host = sheet.processID
        let named = DialogEndpointResolver<Element>.WindowReading.window(remote.windowNumber)
        let sheetNode = Element(kAXSheetRole, window: .window(sheet.windowNumber), processID: host)
        let content   = Element(kAXGroupRole, window: named, processID: host, parent: sheetNode)
        let button    = Element(kAXButtonRole, window: named, processID: host, parent: content,
                                actions: [kAXPressAction])
        let caption   = Element(kAXStaticTextRole, window: named, processID: host, parent: button)
        let field     = Element(kAXTextFieldRole, window: named, processID: host, parent: content,
                                value: "probe.txt")
        let slider    = Element("AXSlider", window: named, processID: host, parent: content,
                                actions: [kAXIncrementAction])
        let row       = Element(kAXRowRole, window: named, processID: host, parent: content,
                                actions: [RemoteContentActuator<Element>.openAction])
        let rowText   = Element(kAXStaticTextRole, window: .windowless, processID: host, parent: row)
        return Panel(
            routing: routing, observation: observation, remote: remote, sheet: sheetNode,
            content: content, caption: caption, button: button, field: field, slider: slider,
            row: row, rowText: rowText
        )
    }

    static func click(_ panel: Panel, count: Int = 1, button: SeatCore.MouseButton = .left) -> InputCommand {
        .click(
            InputLocation(
                screenPoint       : GestureEndpointRoutingTests.insideSheet(panel.routing),
                windowPointFromTop: CGPoint(x: 1, y: 1)
            ),
            button: button,
            count : count
        )
    }

    // MARK: 1. A mapped element is acted on, and nothing is posted

    @Test("a click on a control's caption presses the control and posts no event")
    func aClickPressesTheControlUnderIt() async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        hit.element = panel.caption

        let turn    = try await panel.routing.seat.acquire()
        let receipt = try await panel.routing.seat.send(
            Self.click(panel), observation: panel.observation, turn: turn
        )

        #expect(panel.button.performed == [kAXPressAction])
        #expect(panel.caption.performed.isEmpty && panel.content.performed.isEmpty)
        #expect(panel.routing.sender.sent.isEmpty, "no event reaches the service or the host")
        #expect(receipt.eventCount == 0)
        #expect(receipt.route.poster == .accessibilityAction)
        #expect(receipt.route.routedEventCount == 0)
        #expect(receipt.route.windowNumber == panel.remote.windowNumber)
        #expect(receipt.trace != nil)
        try panel.routing.seat.confirm(receipt, .unknown)
        try panel.routing.seat.release(turn)
    }

    // MARK: 2. An element no click is mapped for refuses

    @Test("a click on an element no click is mapped for refuses by its role and posts nothing")
    func anUnmappedRoleRefuses() async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        hit.element = panel.slider

        let turn = try await panel.routing.seat.acquire()
        await #expect(throws: RemoteContentActuationRefusal.unsupportedRole("AXSlider")) {
            try await panel.routing.seat.send(Self.click(panel), observation: panel.observation, turn: turn)
        }
        #expect(panel.slider.performed.isEmpty && panel.slider.writes.isEmpty)
        #expect(panel.routing.sender.sent.isEmpty)
        try panel.routing.seat.release(turn)
    }

    // MARK: 3. A hit the path does not prove refuses

    @Test("a hit whose path leaves the attested panel content refuses and acts on nothing",
          arguments: [false, true])
    func aHitOutsideTheSurfaceRefuses(anotherProcess: Bool) async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        // A pressable control under the point, inside another window or another process.
        let stray = Element(
            kAXButtonRole,
            window   : anotherProcess ? .window(panel.remote.windowNumber) : .window(9_999),
            processID: anotherProcess ? 31_337 : panel.sheet.processID,
            parent   : panel.content,
            actions  : [kAXPressAction]
        )
        hit.element = stray

        let turn = try await panel.routing.seat.acquire()
        await #expect(throws: RemoteContentActuationRefusal.outsideRemoteContent) {
            try await panel.routing.seat.send(Self.click(panel), observation: panel.observation, turn: turn)
        }
        #expect(stray.performed.isEmpty)
        #expect(panel.routing.sender.sent.isEmpty)
        try panel.routing.seat.release(turn)
    }

    // MARK: Rows and the controls that open menus

    @Test("a click on a file's name field in its row selects the row, and a double click opens the file")
    func aFileRowIsSelectedAndOpened() async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        // Measured on Resolve's Open panel: the name is a text field inside the row's cell.
        let named = DialogEndpointResolver<Element>.WindowReading.window(panel.remote.windowNumber)
        let host  = panel.sheet.processID
        let row   = Element(kAXRowRole, window: named, processID: host, parent: panel.content)
        let cell  = Element(kAXCellRole, window: named, processID: host, parent: row)
        let name  = Element(kAXTextFieldRole, window: named, processID: host, parent: cell,
                            actions: [RemoteContentActuator<Element>.openAction, kAXShowMenuAction, kAXConfirmAction],
                            value: "test_carla_bw_2x.zip")
        let kind  = Element(kAXStaticTextRole, window: named, processID: host, parent: cell, value: "ZIP archive")

        let turn = try await panel.routing.seat.acquire()
        for element in [name, kind] {
            hit.element = element
            let click = try await panel.routing.seat.send(
                Self.click(panel), observation: try await observedReference(panel.routing.seat), turn: turn
            )
            try panel.routing.seat.confirm(click, .unknown)
        }
        #expect(row.writes == [.selected, .selected])
        #expect(panel.content.writes.isEmpty, "no focus is written into a remote panel's content")
        #expect(name.writes.isEmpty, "no caret goes into a file's name")
        #expect(panel.routing.seat.remoteTextField == nil, "a row's field is never remembered for text")

        hit.element = name
        let opened = try await panel.routing.seat.send(
            Self.click(panel, count: 2), observation: try await observedReference(panel.routing.seat), turn: turn
        )
        #expect(name.performed == [RemoteContentActuator<Element>.openAction], "the innermost opener opens")
        #expect(row.performed.isEmpty)
        #expect(panel.routing.sender.sent.isEmpty)
        try panel.routing.seat.confirm(opened, .unknown)
        try panel.routing.seat.release(turn)
    }

    @Test("a click on a popup or a menu button refuses and tells the agent to use select",
          arguments: [kAXPopUpButtonRole, kAXMenuButtonRole])
    func aMenuOpenerRefuses(role: String) async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        let named = DialogEndpointResolver<Element>.WindowReading.window(panel.remote.windowNumber)
        let popup = Element(role, window: named, processID: panel.sheet.processID, parent: panel.content,
                            actions: [kAXPressAction, kAXShowMenuAction])
        hit.element = Element(kAXStaticTextRole, window: named, processID: panel.sheet.processID, parent: popup)

        let turn = try await panel.routing.seat.acquire()
        await #expect(throws: RemoteContentActuationRefusal.opensMenu(role)) {
            try await panel.routing.seat.send(Self.click(panel), observation: panel.observation, turn: turn)
        }
        #expect(popup.performed.isEmpty)
        #expect(RemoteContentActuationRefusal.opensMenu(role).description.contains("Use select"))
        #expect(RemoteContentActuationRefusal.opensMenu(role).description
            == ActionPolicy.menuOpeningRefusal(role: role), "the engine refuses its own press in the same words")
        #expect(panel.routing.sender.sent.isEmpty)
        try panel.routing.seat.release(turn)
    }

    // MARK: The panel a sheet draws

    @Test("a sheet's remote content is found under its host's window entry, drawn inside but not over it")
    func aSheetUnderItsHostNamesItsRemoteContent() throws {
        let host    = FakeGeometry.identity(windowNumber: 9_334)
        let sheet   = FakeGeometry.identity(windowNumber: 9_410)
        let remote  = FakeGeometry.identity(processID: 54_379, windowNumber: 9_411)
        var frames  = [9_334: CGRect(x: 2499, y: 1458, width: 586, height: 488),
                       9_410: CGRect(x: 2597, y: 1480, width: 390, height: 218),
                       9_411: CGRect(x: 2597, y: 1500, width: 390, height: 198)]
        let identities = [9_334: host, 9_410: sheet, 9_411: remote]
        // Accessibility lists the document window; the sheet is its child, the content below.
        let hostNode    = Element(kAXWindowRole, window: .window(9_334), processID: host.processID)
        let sheetNode   = Element(kAXSheetRole, window: .window(9_410), processID: host.processID, parent: hostNode)
        let contentNode = Element(kAXGroupRole, window: .window(9_411), processID: host.processID, parent: sheetNode)
        let children: [ObjectIdentifier: [Element]] = [
            ObjectIdentifier(hostNode): [sheetNode], ObjectIdentifier(sheetNode): [contentNode],
        ]
        let resolver = DialogEndpointResolver<Element>(
            nodeAtPoint: { _ in nil },
            focusedNode: { nil },
            children   : { children[ObjectIdentifier($0)].map { .children($0) } ?? .leaf },
            nodeFrame  : { _ in nil },
            nodeWindow : { if case .window(let number) = $0.window { number } else { nil } },
            nodeProcess: { $0.processID },
            identity   : { identities[$0] },
            geometry   : { number, _ in
                guard let identity = identities[number], let frame = frames[number] else { return nil }
                return WindowGeometryObservation(
                    window: WindowReference(identity: identity, frame: frame), scaleFactor: 2,
                    version: GeometryObservationVersion(observerGeneration: 0, sequence: 1)
                )
            },
            windowNode : { $0 == 9_334 ? hostNode : nil }
        )
        let chain = DialogEndpointResolver<Element>.SurfaceChain(
            host: host, surface: sheet, surfaceFrame: try #require(frames[9_410])
        )
        #expect(resolver.foreignContentWindow(within: chain) == 9_411)

        // Drawn past the sheet, it is not the sheet's content.
        frames[9_411] = CGRect(x: 2400, y: 1500, width: 390, height: 198)
        #expect(resolver.foreignContentWindow(within: chain) == nil)
    }

    @Test("a standalone panel names one foreign window under every child of its window node; an ordinary one does not")
    func aStandalonePanelsContentWindow() throws {
        // Preview's Open panel at launch (14/10/2026): one child, a split group naming the service's window.
        let panel   = FakeGeometry.identity(processID: 74_803, windowNumber: 111_504)
        let content = FakeGeometry.identity(processID: 74_816, windowNumber: 111_505)
        let own     = FakeGeometry.identity(processID: 74_803, windowNumber: 111_510)
        let windowNode = Element(kAXWindowRole, window: .window(111_504), processID: panel.processID)
        var kids: [ObjectIdentifier: DialogEndpointResolver<Element>.ChildReading] = [:]
        var identities = [111_504: panel, 111_505: content, 111_510: own]
        func resolver() -> DialogEndpointResolver<Element> {
            DialogEndpointResolver<Element>(
                nodeAtPoint: { _ in nil },
                focusedNode: { nil },
                children   : { kids[ObjectIdentifier($0)] ?? .leaf },
                nodeFrame  : { _ in nil },
                nodeWindow : { if case .window(let number) = $0.window { number } else { nil } },
                nodeProcess: { $0.processID },
                identity   : { identities[$0] },
                geometry   : { _, _ in nil },
                windowNode : { $0 == 111_504 ? windowNode : nil }
            )
        }
        let chain = DialogEndpointResolver<Element>.SurfaceChain(
            host: panel, surface: panel, surfaceFrame: CGRect(x: 0, y: 0, width: 880, height: 448)
        )
        let split = Element(kAXSplitGroupRole, window: .window(111_505), processID: panel.processID)
        kids[ObjectIdentifier(windowNode)] = .children([split])
        #expect(resolver().remotePanelContentWindow(within: chain) == .panel(contentWindow: 111_505))

        // A child of the window itself: an ordinary window.
        let toolbar = Element(kAXToolbarRole, window: .window(111_504), processID: panel.processID)
        kids[ObjectIdentifier(windowNode)] = .children([split, toolbar])
        #expect(resolver().remotePanelContentWindow(within: chain) == .notPanel)

        // A window of the application's own: not another process's content.
        let accessory = Element(kAXGroupRole, window: .window(111_510), processID: panel.processID)
        kids[ObjectIdentifier(windowNode)] = .children([accessory])
        #expect(resolver().remotePanelContentWindow(within: chain) == .notPanel)

        // Nothing read says nothing either way, and neither does a panel still being born.
        kids[ObjectIdentifier(windowNode)] = .unreadable
        #expect(resolver().remotePanelContentWindow(within: chain) == .unreadable)
        kids[ObjectIdentifier(windowNode)] = .children([])
        #expect(resolver().remotePanelContentWindow(within: chain) == .unreadable)
        let unnamed = Element(kAXGroupRole, window: .windowless, processID: panel.processID)
        kids[ObjectIdentifier(windowNode)] = .children([unnamed])
        #expect(resolver().remotePanelContentWindow(within: chain) == .unreadable)
        kids[ObjectIdentifier(windowNode)] = .children([split])
        identities[111_505] = nil
        #expect(resolver().remotePanelContentWindow(within: chain) == .unreadable)
    }

    @Test("a point on a sheet wider than its host is kept for the seat, inside the picture's region only")
    func aPointOnAWideSheetIsRouted() throws {
        // Measured on 05/10/2026: TextEdit's expanded Save sheet, its sidebar left of the document window.
        let host = try #require(WindowGeometryObservation(
            window     : FakeGeometry.reference(frame: CGRect(x: 2499, y: 1458, width: 586, height: 488)),
            scaleFactor: 2,
            version    : GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        ))
        let region   = CGRect(x: 2194, y: 1458, width: 891, height: 488)
        let downloads = CGPoint(x: 2412.4885, y: 1746.164)

        let location = try #require(SeatActuator.location(of: downloads, in: host, region: region))
        #expect(location.screenPoint == downloads)
        #expect(location.observedGeometry == host)
        #expect(SeatActuator.location(of: downloads, in: host, region: nil) == nil,
                "a picture of one window still refuses a point outside it")
        #expect(SeatActuator.location(of: CGPoint(x: 2100, y: 1500), in: host, region: region) == nil)
    }

    @Test("a refusal the seat raised before any event reaches the engine as a gesture not sent; one that may have acted does not")
    func refusalsBeforeAnyEventAreNotSent() throws {
        let surface = WindowIdentity(process: ProcessIdentity(processID: 85414, serialNumberHigh: 0, serialNumberLow: 1),
                                     windowNumber: 111000, ownerConnectionID: 7)
        let unreadable = try #require(SeatActuator.unsent(InputEndpointRefusal.subtreeUnreadable(surface: surface)))
        #expect(unreadable.reason == "endpoint_refused")
        #expect(!unreadable.sentence.contains("WindowIdentity"), "the model reads words, never a type")
        let remote = try #require(SeatActuator.unsent(RemoteContentActuationRefusal.unreadable))
        #expect(remote.reason == "remote_content_refused")
        #expect(SeatActuator.unsent(RemoteContentActuationRefusal.selectedNotOpened(code: -25205)) == nil,
                "a refusal after an action that may have taken effect stays a delivery whose effect is unknown")
        #expect(SeatActuator.unsent(SeatDrivingFailure.pointOutsideTarget(CGPoint(x: 1, y: 1)))?.reason == "point_outside_window")
        #expect(SeatActuator.unsent(SeatDrivingFailure.notAdopted) == nil)
        // A sheet that changed size after its scene (Preview's Save As, 14/10/2026): the preflight's stop.
        let resized = try #require(SeatActuator.unsent(SeatInterruption(issues: [.geometryChanged], beforeAnyEvent: true)))
        #expect(resized.reason == "seat_preflight")
        #expect(resized.sentence.hasPrefix("The window moved or changed size") && resized.sentence.contains("Observe again")
            && !resized.sentence.contains("SeatIssue"), "\(resized.sentence)")
        #expect(SeatActuator.unsent(SeatInterruption(issues: [.geometryChanged])) == nil,
                "a stop that may follow an event stays a delivery whose effect is unknown")
        let after = try #require(SeatActuator.interrupted(SeatInterruption(issues: [.ambiguousEffect])))
        #expect(after.description.contains("may have taken effect") && !after.description.contains("SeatIssue"))
        #expect(SeatActuator.interrupted(SeatDrivingFailure.notAdopted) == nil)
        // A selection is several Commands: a stop before one of them is worded, never called "nothing sent".
        let selection = "\(SeatDropdownSelector.worded(SeatInterruption(issues: [.geometryChanged], beforeAnyEvent: true)))"
        #expect(selection.hasPrefix("The window moved or changed size") && selection.contains("may have gone out")
            && !selection.contains("SeatIssue") && !selection.contains("nothing was sent"), "\(selection)")
        #expect(SeatDropdownSelector.worded(SeatDrivingFailure.notAdopted) as? SeatDrivingFailure == .notAdopted)
    }

    // MARK: 4. Text reaches a remembered field through accessibility

    /// The engine's replace in a remote panel is a triple click and then `.type`, which the seat
    /// actuator sends as `.text`; a long or composed payload goes as `.insertText`.
    @Test("the engine's replace, a triple click and then text, reaches AXSelectedText and posts no key",
          arguments: [InputCommand.text("name.txt"), .insertText("name.txt")])
    func textAfterARememberedFieldSetsTheSelectedText(text: InputCommand) async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        hit.element = panel.field

        let turn  = try await panel.routing.seat.acquire()
        let click = try await panel.routing.seat.send(
            Self.click(panel, count: 3), observation: panel.observation, turn: turn
        )
        #expect(panel.field.writes == [.selectedTextRange(location: 0, length: 9)])
        try panel.routing.seat.confirm(click, .unknown)

        let typed = try await panel.routing.seat.send(
            text,
            observation: try await observedReference(panel.routing.seat),
            turn       : turn
        )
        #expect(panel.field.writes.last == .selectedText("name.txt"))
        #expect(panel.field.value == "name.txt")
        #expect(panel.routing.sender.sent.isEmpty, "no key reaches the service or the host")
        #expect(panel.routing.discovery.keyboardResolutions == 0, "the remembered field is the recipient")
        #expect(typed.route.poster == .accessibilityAction)
        #expect(typed.route.windowNumber == panel.remote.windowNumber)
        #expect(typed.textMeasure == text.textMeasure)
        try panel.routing.seat.confirm(typed, .unknown)
        try panel.routing.seat.release(turn)
    }

    @Test("a field that stopped answering is forgotten, and its text takes the key route")
    func aSilentFieldIsForgotten() async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        hit.element = panel.field

        let turn  = try await panel.routing.seat.acquire()
        let click = try await panel.routing.seat.send(Self.click(panel), observation: panel.observation, turn: turn)
        #expect(panel.field.writes == [.selectedTextRange(location: 9, length: 0)])
        try panel.routing.seat.confirm(click, .unknown)

        panel.field.answers = false
        panel.routing.discovery.keyboardAnswer = .failure(.subtreeUnreadable(surface: panel.observation.surface))
        await #expect(throws: InputEndpointRefusal.self) {
            try await panel.routing.seat.send(
                .insertText("x"), observation: try await observedReference(panel.routing.seat), turn: turn
            )
        }
        #expect(panel.routing.discovery.keyboardResolutions >= 1, "today's keyboard discovery was asked")
        #expect(panel.field.writes.count == 1)
        try panel.routing.seat.release(turn)
    }

    // MARK: 5. A remote popup's menu belongs to the panel service

    @Test("a popup of a remote panel finds the service's menu and presses the item named")
    func aRemotePopupMenuIsTheServices() async throws {
        let hit     = Hit()
        let panel   = try await Self.panel(hit)
        let routing = panel.routing
        routing.discovery.foreignContentWindow = panel.remote.windowNumber
        #expect(routing.seat.holdsRemoteFilePanel)

        let menuWindow = FakeGeometry.reference(
            frame       : CGRect(x: 2000, y: 700, width: 180, height: 90),
            processID   : panel.remote.processID,
            windowNumber: 880
        )
        let desktop = RemoteMenuChoiceTests.Node(kAXMenuItemRole, title: "\u{2068}Desktop\u{2069} \u{2014} iCloud",
                                                 frame: CGRect(x: 2004, y: 720, width: 170, height: 20))
        let menuNode = RemoteMenuChoiceTests.Node(kAXMenuRole, children: [
            RemoteMenuChoiceTests.Node(kAXMenuItemRole, title: "Downloads",
                                       frame: CGRect(x: 2004, y: 700, width: 170, height: 20)),
            desktop
        ])
        let tree = RemoteMenuChoiceTests.Node("AXApplication", children: [menuNode])

        let turn    = try await routing.seat.acquire()
        let receipt = try await routing.seat.useNativePopupMenu(of: routing.sheet, turn: turn, opening: {
            routing.sensing.menusOfOtherProcesses[panel.remote.processID] = [menuWindow]
        }) { menu in
            #expect(menu.window.processID == panel.remote.processID)
            // What the selector runs: the item of that title, pressed through accessibility.
            let outcome = try RemoteMenuChoiceTests.choice.choose(
                "desktop \u{2014} icloud", in: menu.frame, under: [tree]
            )
            if desktop.performed == [kAXPressAction] { routing.sensing.menusOfOtherProcesses = [:] }
            return outcome == .chosen
        }

        #expect(desktop.performed == [kAXPressAction])
        #expect(menuNode.performed.isEmpty, "a chosen item closes its menu; nothing is cancelled")
        #expect(receipt.menu.window.windowNumber == 880)
        #expect(receipt.selectionRequested)
        #expect(receipt.closedBy == .chosenItem)
        #expect(routing.sender.sent.isEmpty, "the popup opened and chose without an event")
        #expect(routing.sender.preparationCycles.isEmpty)
        try routing.seat.release(turn)
    }

    @Test("a remote popup without the item cancels its menu through accessibility, and the seat sees it go")
    func aMissedItemCancelsTheServicesMenu() async throws {
        let hit     = Hit()
        let panel   = try await Self.panel(hit)
        let routing = panel.routing
        routing.discovery.foreignContentWindow = panel.remote.windowNumber
        let menuWindow = FakeGeometry.reference(
            frame       : RemoteMenuChoiceTests.menuFrame,
            processID   : panel.remote.processID,
            windowNumber: 881
        )
        let (tree, menuNode, _) = RemoteMenuChoiceTests.whereMenu()
        let choice = RemoteMenuChoice<RemoteMenuChoiceTests.Node>(
            role     : { $0.role },
            title    : { $0.title },
            isEnabled: { $0.isEnabled },
            frame    : { $0.frame },
            children : { $0.children },
            perform  : { node, action in
                node.performed.append(action)
                // The service's menu window goes when its menu is cancelled, as measured.
                if action == kAXCancelAction { routing.sensing.menusOfOtherProcesses = [:] }
                return .success
            }
        )
        var listing: String?

        let turn    = try await routing.seat.acquire()
        let receipt = try await routing.seat.useNativePopupMenu(of: routing.sheet, turn: turn, opening: {
            routing.sensing.menusOfOtherProcesses[panel.remote.processID] = [menuWindow]
        }) { menu in
            let outcome = try choice.choose("iCloud Drive", in: menu.frame, under: [tree])
            guard case .missing(let found) = outcome else { return true }
            listing = found
            return false
        }

        #expect(menuNode.performed == [kAXCancelAction])
        #expect(receipt.closedBy == .dismissedItself)
        #expect(listing?.contains("iCloud Drive (twice)") == true)
        #expect(!receipt.selectionRequested)
        #expect(routing.sender.preparationCycles.isEmpty && routing.sender.sent.isEmpty,
                "no host lever is pulled on the service's menu")
        try routing.seat.release(turn)
    }

    @Test("a pixel dropdown is refused while a remote panel is held, before any click")
    func aPixelDropdownIsRefusedInARemotePanel() async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        panel.routing.discovery.foreignContentWindow = panel.remote.windowNumber

        let turn = try await panel.routing.seat.acquire()
        await #expect(throws: RemoteContentActuationRefusal.pixelDropdown) {
            try await panel.routing.seat.useDropdownMenu(
                openedAt: ContextMenuTests.openAt, of: panel.routing.sheet, turn: turn, keyInterval: .zero
            ) { _ in [36] }
        }
        #expect(panel.routing.sender.sent.isEmpty)
        try panel.routing.seat.release(turn)
    }

    // MARK: An open panel's icon view

    /// The icon view of an open panel as measured on 06/10/2026: the host's `AXList 'icon view'`,
    /// whose selected children alone are settable, the service's inner list, the item group with
    /// nothing settable, and the image offering AXOpen. Only `[group]` written to the outer list
    /// selects the file; every other write answers 0 and changes nothing.
    struct IconView {
        let outer: Element
        let inner: Element
        let group: Element
        let image: Element
    }

    static func iconView(under parent: Element, host: Int32, service: Int32, window: Int) -> IconView {
        let named = DialogEndpointResolver<Element>.WindowReading.window(window)
        let outer = Element(kAXListRole, window: named, processID: host, parent: parent)
        outer.selectionSettable = true
        outer.selectedChildren  = []
        let inner = Element(kAXListRole, window: named, processID: service, parent: outer)
        inner.selectedChildren = []
        let group = Element(kAXGroupRole, window: named, processID: service, parent: inner)
        let image = Element(kAXImageRole, window: named, processID: service, parent: group,
                            actions: [RemoteContentActuator<Element>.openAction, kAXShowMenuAction])
        image.selectedFlag = false
        outer.onSelectChildren = { children in
            guard children == [group] else { return }
            outer.selectedChildren = [group]
            image.selectedFlag     = true
        }
        return IconView(outer: outer, inner: inner, group: group, image: image)
    }

    @Test("a click on a file in an icon view selects it through the list's selected children, posting nothing")
    func anIconIsSelectedThroughItsList() async throws {
        let hit   = Hit()
        let panel = try await Self.panel(hit)
        let icons = Self.iconView(under: panel.content, host: panel.sheet.processID,
                                  service: panel.remote.processID, window: panel.remote.windowNumber)
        hit.element = icons.image

        let turn    = try await panel.routing.seat.acquire()
        let receipt = try await panel.routing.seat.send(
            Self.click(panel), observation: panel.observation, turn: turn
        )
        #expect(icons.outer.selectionWrites == [[icons.group]], "the item group, the list's nearest item, first")
        #expect(icons.outer.selectedChildren == [icons.group])
        #expect(icons.inner.selectionWrites.isEmpty, "the inner list's selection is not settable")
        #expect(icons.group.writes.isEmpty && icons.image.writes.isEmpty, "no AXSelected write, measured to do nothing")
        #expect(icons.image.performed.isEmpty, "no AXOpen on a single click")
        #expect(panel.routing.sender.sent.isEmpty)
        #expect(receipt.route.poster == .accessibilityAction)
        try panel.routing.seat.confirm(receipt, .unknown)
        try panel.routing.seat.release(turn)
    }

    @Test("a double click on a file in an icon view selects it and presses the default button, else opens it",
          arguments: [true, false])
    func anIconIsOpened(hasDefaultButton: Bool) throws {
        let surface  = FakeGeometry.identity(windowNumber: 878)
        let endpoint = try Self.remoteEndpoint(surface: surface)
        let sheet    = Element(kAXSheetRole, window: .window(878), processID: surface.processID)
        let content  = Element(kAXGroupRole, window: .window(879), processID: surface.processID, parent: sheet)
        let icons    = Self.iconView(under: content, host: surface.processID, service: 7_001, window: 879)
        let open     = Element(kAXButtonRole, window: .window(879), processID: surface.processID, parent: content,
                               actions: [kAXPressAction])
        if hasDefaultButton { sheet.defaultButton = open }

        let outcome = Self.actuator { icons.image }.actuate(Self.click(count: 2), endpoint: endpoint)
        #expect(try outcome.get().action == (hasDefaultButton ? kAXPressAction : "AXOpen"))
        #expect(icons.outer.selectedChildren == [icons.group], "selected before it is opened")
        #expect(open.performed == (hasDefaultButton ? [kAXPressAction] : []))
        #expect(icons.image.performed == (hasDefaultButton ? [] : ["AXOpen"]),
                "AXOpen on the image activated the host once, so the default button comes first")
    }

    @Test("a write that answers 0 and selects nothing is passed by, and none that verifies refuses")
    func anUnverifiedWriteIsPassedBy() throws {
        let surface  = FakeGeometry.identity(windowNumber: 878)
        let endpoint = try Self.remoteEndpoint(surface: surface)
        let sheet    = Element(kAXSheetRole, window: .window(878), processID: surface.processID)
        let content  = Element(kAXGroupRole, window: .window(879), processID: surface.processID, parent: sheet)
        let icons    = Self.iconView(under: content, host: surface.processID, service: 7_001, window: 879)
        // A wrapper between the inner list and the item: written first, it answers 0 and selects nothing.
        let wrapper  = Element(kAXGroupRole, window: .window(879), processID: 7_001, parent: icons.inner)
        icons.group.parent = wrapper

        #expect(try Self.actuator { icons.image }.actuate(Self.click(count: 1), endpoint: endpoint).get()
            .action == kAXSelectedChildrenAttribute)
        #expect(icons.outer.selectionWrites == [[wrapper], [icons.group]])

        // Nothing the list accepts: the click refuses, and nothing is pressed or opened.
        icons.outer.onSelectChildren = { _ in }
        icons.outer.selectedChildren = []
        icons.image.selectedFlag     = false
        #expect(throws: RemoteContentActuationRefusal.selectionNotVerified(kAXImageRole)) {
            try Self.actuator { icons.image }.actuate(Self.click(count: 2), endpoint: endpoint).get()
        }
        #expect(icons.image.performed.isEmpty)
    }

    @Test("a click in a column view refuses and says to switch to list view")
    func aColumnViewRefuses() throws {
        let surface  = FakeGeometry.identity(windowNumber: 878)
        let endpoint = try Self.remoteEndpoint(surface: surface)
        let named    = DialogEndpointResolver<Element>.WindowReading.window(879)
        let sheet    = Element(kAXSheetRole, window: .window(878), processID: surface.processID)
        let browser  = Element(kAXBrowserRole, window: named, processID: surface.processID, parent: sheet)
        let column   = Element(kAXListRole, window: named, processID: surface.processID, parent: browser)
        let row      = Element(kAXRowRole, window: named, processID: surface.processID, parent: column)
        let text     = Element(kAXStaticTextRole, window: named, processID: surface.processID, parent: row)

        #expect(throws: RemoteContentActuationRefusal.columnView) {
            try Self.actuator { text }.actuate(Self.click(count: 1), endpoint: endpoint).get()
        }
        #expect(row.writes.isEmpty)
        #expect(RemoteContentActuationRefusal.columnView.description.contains("list view"))
    }

    static func remoteEndpoint(surface: WindowIdentity) throws -> ResolvedInputEndpoint {
        let geometry = try #require(WindowGeometryObservation(
            window: FakeGeometry.reference(
                frame: CGRect(x: 2000, y: 400, width: 400, height: 300), processID: 7_001, windowNumber: 879
            ),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        ))
        return try GestureEndpointRoutingTests.endpoint(
            geometry, relation: .remoteContent, logicalSurface: surface, generation: 1,
            hostProcessID: surface.processID, lifetimeNanoseconds: 60_000_000_000
        )
    }

    static func click(count: Int) -> InputCommand {
        .click(InputLocation(screenPoint: CGPoint(x: 2100, y: 500), windowPointFromTop: .zero), count: count)
    }

    // MARK: Finder's windows take their clicks through accessibility

    /// A seat holding one ordinary window, of an application that takes its clicks through
    /// accessibility or not, with Finder's sidebar as accessibility shows it: the window, its
    /// sidebar outline, the Downloads row, its cell and its text.
    ///
    /// Measured on 06/10/2026 on a Finder window in the background: the row offers only
    /// AXShowDefaultUI and AXShowAlternateUI, and its `AXSelected` written answers 0 and selects
    /// without navigating, while `[row]` written to the outline's `AXSelectedRows` navigates. The
    /// window element's value stands for the folder the window shows.
    struct Finder {
        let seat     : AgentSeat
        let sender   : FakeSender
        let discovery: GestureEndpointRoutingTests.Discovery
        let window   : AdoptedWindow
        let element  : Element
        let outline  : Element
        let row      : Element
        let text     : Element
        let hit      : Hit
    }

    static func finder(
        clicksThroughAccessibility: Bool, marker: Int64, searchWindowTree: Bool = false
    ) async throws -> Finder {
        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let discovery = GestureEndpointRoutingTests.Discovery()
        discovery.clicksThroughAccessibility = clicksThroughAccessibility
        discovery.postsDeclinedClicks        = !searchWindowTree
        let seat = makeSeat(
            sensing  : sensing,
            sender   : sender,
            marker   : marker,
            reader   : ControlledSurfaceReader(sensing: sensing),
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: discovery.discovery
        )
        let window   = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let identity = try #require(window.reference.identity)
        discovery.identities[identity.windowNumber] = identity

        let own      = DialogEndpointResolver<Element>.WindowReading.window(identity.windowNumber)
        let windowEl = Element(kAXWindowRole, window: own, processID: identity.processID, value: "Recents")
        let outline  = Element(kAXOutlineRole, window: own, processID: identity.processID, parent: windowEl)
        let row      = Element(kAXRowRole, window: own, processID: identity.processID, parent: outline,
                               actions: ["AXShowDefaultUI", "AXShowAlternateUI"])
        let cell     = Element(kAXCellRole, window: .windowless, processID: identity.processID, parent: row)
        let text     = Element(kAXStaticTextRole, window: .windowless, processID: identity.processID, parent: cell,
                               value: "Downloads")
        outline.rowsSettable = true
        outline.selectedRows = []
        outline.onSelectRows = { [unowned outline] rows in
            outline.selectedRows = rows
            if rows == [row] { windowEl.value = "Downloads" }
        }
        let hit      = Hit()
        hit.element  = text
        let actuator = Self.actuator(hitting: { hit.element }, window: windowEl, searchWindowTree: searchWindowTree)
        discovery.actuation = { actuator.actuate($0, endpoint: $1) }
        return Finder(seat: seat, sender: sender, discovery: discovery, window: window, element: windowEl,
                      outline: outline, row: row, text: text, hit: hit)
    }

    static func send(
        _ count : Int,
        to finder: Finder,
        turn    : Turn
    ) async throws -> InputReceipt {
        try await finder.seat.send(
            .click(Self.point(in: finder.window), count: count),
            observation: try await observedReference(finder.seat),
            turn       : turn
        )
    }

    static func point(in window: AdoptedWindow) -> InputLocation {
        let frame = window.reference.frame
        return InputLocation(
            screenPoint       : CGPoint(x: frame.minX + 40, y: frame.minY + 200),
            windowPointFromTop: CGPoint(x: 40, y: 200)
        )
    }

    @Test("a click on a Finder sidebar row selects it through its outline's selected rows and posts nothing")
    func aFinderSidebarRowIsSelected() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_401)
        let turn   = try await finder.seat.acquire()
        let receipt = try await finder.seat.send(
            .click(Self.point(in: finder.window)), observation: try await observedReference(finder.seat), turn: turn
        )
        #expect(finder.outline.rowWrites == [[finder.row]], "the outline's selected rows, which navigate")
        #expect(finder.row.writes.isEmpty, "no AXSelected on the row, measured to select without navigating")
        #expect(finder.element.value == "Downloads")
        #expect(finder.outline.writes == [.focused], "the list takes the focus a click gives, for a key such as /")
        #expect(finder.sender.sent.isEmpty, "the first click on an inactive window is not posted to be eaten")
        #expect(receipt.route.poster == .accessibilityAction)
        #expect(receipt.route.windowNumber == finder.window.id)
        try finder.seat.confirm(receipt, .unknown)

        try finder.seat.release(turn)
    }

    // MARK: Apple native windows: accessibility first, a posted click as the fallback

    /// A control drawn directly in the window, which the hit test answers.
    private static func control(
        _ role   : String,
        in finder: Finder,
        actions  : [String],
        value    : String? = nil
    ) -> Element {
        let control = Element(
            role,
            window   : finder.element.window,
            processID: finder.element.processID,
            parent   : finder.element,
            actions  : actions,
            value    : value
        )
        finder.hit.element = control
        return control
    }

    /// Sends one click, then closes the Turn as the seat's owner does. Nothing is thrown by a click
    /// that was declined and posted, and the posting is what the receipt's route says.
    private static func click(_ finder: Finder) async throws -> (receipt: InputReceipt, posted: Bool) {
        let turn    = try await finder.seat.acquire()
        let receipt = try await Self.send(1, to: finder, turn: turn)
        try finder.seat.confirm(receipt, .unknown)
        try finder.seat.release(turn)
        return (receipt, receipt.route.poster == .publicProcess)
    }

    @Test("a control that offers AXPress is pressed through accessibility and no click is posted")
    func aControlOfferingPressIsPressed() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_410)
        let button = Self.control(kAXButtonRole, in: finder, actions: [kAXPressAction])
        let result = try await Self.click(finder)
        #expect(button.performed == [kAXPressAction])
        #expect(!result.posted && finder.sender.sent.isEmpty)
        #expect(result.receipt.route.poster == .accessibilityAction)
    }

    @Test("a press that succeeded and changed nothing is never also clicked")
    func aPressWithoutEffectIsNotClicked() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_411)
        // The press answers success and the window stays as it was: the seat cannot know, and does not look.
        let button = Self.control(kAXButtonRole, in: finder, actions: [kAXPressAction])
        button.performAnswer = .success
        let result = try await Self.click(finder)
        #expect(button.performed == [kAXPressAction], "pressed once")
        #expect(finder.sender.sent.isEmpty, "and not clicked on top of it")
        #expect(!result.posted)
    }

    @Test("a control without AXPress, or a role no action maps, is clicked as before")
    func aControlWithoutPressIsClicked() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_412)
        let button = Self.control(kAXButtonRole, in: finder, actions: [kAXShowMenuAction])
        let result = try await Self.click(finder)
        #expect(button.performed.isEmpty, "AXPress is not asked of an element that does not offer it")
        #expect(result.posted && finder.sender.sent.count == 1)

        let image = Self.control(kAXImageRole, in: finder, actions: [])
        let again = try await Self.click(finder)
        #expect(image.performed.isEmpty)
        #expect(again.posted && finder.sender.sent.count == 2)
    }

    @Test("empty space in a list, which accessibility declined before acting, is clicked")
    func emptySpaceIsClicked() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_402)
        finder.hit.element = finder.outline
        let result = try await Self.click(finder)
        #expect(finder.outline.writes.isEmpty && finder.outline.rowWrites.isEmpty)
        #expect(result.posted && finder.sender.sent.count == 1)
    }

    @Test("accessibility that reports the action unsupported did nothing, so the click is posted")
    func anUnsupportedPressIsClicked() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_413)
        let button = Self.control(kAXButtonRole, in: finder, actions: [kAXPressAction])
        button.performAnswer = .actionUnsupported
        let result = try await Self.click(finder)
        #expect(button.performed == [kAXPressAction])
        #expect(result.posted && finder.sender.sent.count == 1)
    }

    @Test("any other answer to a press may have acted, so it refuses and posts nothing")
    func aRefusedPressIsNotClicked() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_414)
        let button = Self.control(kAXButtonRole, in: finder, actions: [kAXPressAction])
        button.performAnswer = .failure
        let turn = try await finder.seat.acquire()
        await #expect(throws: RemoteContentActuationRefusal.actionRefused(
            action: kAXPressAction, code: AXError.failure.rawValue
        )) { try await Self.send(1, to: finder, turn: turn) }
        #expect(finder.sender.sent.isEmpty)
        try finder.seat.release(turn)
    }

    @Test("an element under a web area keeps the posted click")
    func webContentIsClicked() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_415)
        let page   = Element(
            RemoteContentActuator<Element>.webAreaRole,
            window   : .windowless,
            processID: finder.element.processID,
            parent   : finder.element
        )
        let link = Element(
            kAXButtonRole,
            window   : .windowless,
            processID: finder.element.processID,
            parent   : page,
            actions  : [kAXPressAction]
        )
        finder.hit.element = link
        let result = try await Self.click(finder)
        #expect(link.performed.isEmpty)
        #expect(result.posted && finder.sender.sent.count == 1)
    }

    @Test("a text field whose selected range cannot be written is clicked, and one that can takes the caret",
          arguments: [false, true])
    func aTextFieldNeedsAWritableRange(settable: Bool) async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: settable ? 3_417 : 3_416)
        let field  = Self.control(kAXTextFieldRole, in: finder, actions: [], value: "abc")
        field.selectionSettable = settable
        let result = try await Self.click(finder)
        #expect(field.writes == (settable ? [.selectedTextRange(location: 3, length: 0)] : []))
        #expect(result.posted == !settable)
    }

    @Test("a field drawn in a row takes the caret when it can be edited, and a name that cannot still selects the row",
          arguments: [true, false])
    func aFieldInARowTakesTheCaret(editable: Bool) async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: editable ? 3_430 : 3_431)
        let cell   = Element(kAXCellRole, window: .windowless, processID: finder.element.processID, parent: finder.row)
        let field  = Element(kAXTextFieldRole, window: .windowless, processID: finder.element.processID,
                             parent: cell, value: "Buy milk")
        // Its range can be written either way: only a field one can edit also has a writable value.
        field.selectionSettable = true
        field.valueSettable     = editable
        finder.hit.element      = field

        let result = try await Self.click(finder)
        #expect(!result.posted && finder.sender.sent.isEmpty)
        if editable {
            #expect(field.writes == [.selectedTextRange(location: 8, length: 0)], "the caret, at the end of the text")
            #expect(finder.outline.rowWrites.isEmpty && finder.row.writes.isEmpty, "the row is not selected")
            #expect(finder.seat.remoteTextField != nil, "and its text goes through the same field")
        } else {
            #expect(field.writes.isEmpty, "no caret goes into a file's name")
            #expect(finder.outline.rowWrites == [[finder.row]])
            #expect(finder.seat.remoteTextField == nil)
        }
    }

    @Test("a control drawn on a field in its row is pressed, and the field is left alone")
    func aControlOnTheFieldIsPressed() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_432)
        let cell   = Element(kAXCellRole, window: .windowless, processID: finder.element.processID, parent: finder.row)
        let field  = Element(kAXTextFieldRole, window: .windowless, processID: finder.element.processID,
                             parent: cell, value: "x")
        let button = Element(kAXButtonRole, window: .windowless, processID: finder.element.processID,
                             parent: field, actions: [kAXPressAction])
        field.selectionSettable = true
        field.valueSettable     = true
        finder.hit.element      = button

        let result = try await Self.click(finder)
        #expect(button.performed == [kAXPressAction] && field.writes.isEmpty)
        #expect(!result.posted)
    }

    @Test("a field selection refuses another name or text that is not writable", arguments: [false, true])
    func fieldLabelIsChecked(editable: Bool) async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_439)
        let field = Self.control(kAXTextFieldRole, in: finder, actions: [], value: "original")
        field.title = editable ? "Other field" : "File Name"
        field.selectionSettable = true
        field.textSettable = editable
        let actuator = Self.actuator(hitting: { field }, window: finder.element)
        let identity = try #require(finder.window.reference.identity)
        let geometry = try #require(WindowGeometryObservation(
            window: finder.window.reference, scaleFactor: 1,
            version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        ))
        let endpoint = try GestureEndpointRoutingTests.endpoint(
            geometry, relation: .logicalSurface, logicalSurface: identity,
            generation: 1, hostProcessID: identity.processID
        )
        let result = actuator.actuate(
            .click(Self.point(in: finder.window), count: 3), endpoint: endpoint, expecting: "File Name"
        )
        let refusal: RemoteContentActuationRefusal = editable
            ? .wrongElement(requested: "File Name", found: "Other field") : .fieldRequiresClick
        #expect(throws: refusal) {
            try result.get()
        }
        #expect(field.writes.isEmpty)
        #expect(field.value == "original")
    }

    @Test("text after an accessibility click on an ordinary window's field is set through AXSelectedText")
    func textAfterAnOrdinaryFieldClickIsSetThroughAccessibility() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_433)
        let field  = Self.control(kAXTextFieldRole, in: finder, actions: [], value: "abc")
        field.selectionSettable = true
        let turn  = try await finder.seat.acquire()
        let click = try await Self.send(1, to: finder, turn: turn)
        try finder.seat.confirm(click, .unknown)

        let typed = try await finder.seat.send(
            .text("def"), observation: try await observedReference(finder.seat), turn: turn
        )
        #expect(field.writes.last == .selectedText("def"))
        #expect(field.value == "abcdef")
        #expect(finder.sender.sent.isEmpty, "no key is posted")
        #expect(typed.route.poster == .accessibilityAction)
        try finder.seat.confirm(typed, .unknown)

        // Any key in between, even the engine's end of field, makes the next text a posted one.
        let again = try await finder.seat.send(
            .click(Self.point(in: finder.window)), observation: try await observedReference(finder.seat), turn: turn
        )
        try finder.seat.confirm(again, .unknown)
        let key = try await finder.seat.send(
            Shortcut(.virtualKey(CGKeyCode(125)), holding: .command),
            observation: try await observedReference(finder.seat),
            turn       : turn
        )
        try finder.seat.confirm(key, .unknown)
        #expect(finder.seat.remoteTextField == nil, "a key forgets the field: the engine must not send one")
        try finder.seat.release(turn)
    }

    @Test("a row nothing can select is clicked, and one whose list write took but did not read back is not")
    func aRowNothingSelectsIsClicked() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_418)
        finder.outline.rowsSettable = false
        // The row's own AXSelected is the unsupported write of an element that has none.
        finder.row.writeAnswer = .attributeUnsupported
        finder.hit.element     = finder.row
        let result = try await Self.click(finder)
        #expect(result.posted && finder.sender.sent.count == 1)

        // The list took the write and nothing read back, then the row's own write failed: acted.
        let again = try await Self.finder(clicksThroughAccessibility: true, marker: 3_419)
        again.outline.onSelectRows = { _ in }
        again.row.writeAnswer      = .attributeUnsupported
        again.hit.element          = again.row
        let turn = try await again.seat.acquire()
        await #expect(throws: RemoteContentActuationRefusal.self) { try await Self.send(1, to: again, turn: turn) }
        #expect(again.sender.sent.isEmpty)
        try again.seat.release(turn)
    }

    @Test("the engine's actuator reports how a click went out, and forgets it once confirmed",
          arguments: [true, false])
    func theActuatorReportsTheRoute(offersPress: Bool) async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: offersPress ? 3_420 : 3_421)
        _ = Self.control(kAXButtonRole, in: finder, actions: offersPress ? [kAXPressAction] : [])
        _ = try await observedReference(finder.seat)
        let target   = SeatTarget(borrowing: SeatHost(), seat: finder.seat)
        let actuator = SeatActuator(target: target)
        let pid      = finder.window.reference.processID
        _ = try await target.observe()
        let frame = finder.window.reference.frame
        try await actuator.perform(.click(at: CGPoint(x: frame.minX + 40, y: frame.minY + 200)), in: pid)
        #expect(await actuator.lastDeliveryRoute(in: pid) == (offersPress ? .accessibility : .posted))
        #expect(finder.sender.sent.isEmpty == offersPress)
        await actuator.confirm(.unknown, in: pid)
        #expect(await actuator.lastDeliveryRoute(in: pid) == .posted)
        await target.stop()
    }

    @Test("a row whose list's selected rows cannot be written or do not read back is selected by its own AXSelected",
          arguments: [false, true])
    func aRowFallsBackToItsOwnSelection(listIsSettable: Bool) async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: listIsSettable ? 3_406 : 3_407)
        finder.outline.rowsSettable = listIsSettable
        // The write answers 0 and changes nothing.
        finder.outline.onSelectRows = { _ in }
        let turn    = try await finder.seat.acquire()
        let receipt = try await Self.send(1, to: finder, turn: turn)
        #expect(finder.outline.rowWrites == (listIsSettable ? [[finder.row]] : []))
        #expect(finder.row.writes == [.selected], "the row's own selection, read back")
        #expect(finder.element.value == "Recents", "selected, not navigated: the scene says which")
        #expect(finder.sender.sent.isEmpty)
        try finder.seat.confirm(receipt, .unknown)

        // Neither selection reads back: the click refuses, and nothing is posted.
        finder.row.ignoresSelectedWrite = true
        finder.row.selectedFlag         = nil
        await #expect(throws: RemoteContentActuationRefusal.selectionNotVerified(kAXRowRole)) {
            try await Self.send(1, to: finder, turn: turn)
        }
        #expect(!RemoteContentActuationRefusal.selectionNotVerified(kAXRowRole).description.contains("list view"),
                "a row is already in a list: its sentence does not send the worker to list view")
        #expect(finder.sender.sent.isEmpty)
        try finder.seat.release(turn)
    }

    @Test("a double click on a Finder sidebar row selects it, and says when it was not opened")
    func aSidebarRowDoubleClickSaysItWasNotOpened() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_408)
        let turn   = try await finder.seat.acquire()
        // Nothing offers AXOpen: the row's actions are AXShowDefaultUI and AXShowAlternateUI.
        await #expect(throws: RemoteContentActuationRefusal.selectedNotOpened(code: nil)) {
            try await Self.send(2, to: finder, turn: turn)
        }
        #expect(finder.element.value == "Downloads", "the sidebar navigates on its selection")
        #expect(RemoteContentActuationRefusal.selectedNotOpened(code: nil).mayHaveTakenEffect)

        // An element offering AXOpen that answers it unsupported.
        finder.text.actions       = [RemoteContentActuator<Element>.openAction]
        finder.text.performAnswer = .actionUnsupported
        let unsupported = RemoteContentActuationRefusal.selectedNotOpened(code: AXError.actionUnsupported.rawValue)
        await #expect(throws: unsupported) { try await Self.send(2, to: finder, turn: turn) }
        #expect(finder.text.performed == [RemoteContentActuator<Element>.openAction])
        #expect(unsupported.description.contains("not supported"))
        #expect(finder.sender.sent.isEmpty)
        try finder.seat.release(turn)
    }

    @Test("a double click on a file's kind in a Finder list selects its row and opens it through its name field")
    func aFileRowOpensThroughItsName() async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: 3_409)
        let pid    = finder.element.processID
        let list   = Element(kAXOutlineRole, window: finder.element.window, processID: pid, parent: finder.element)
        list.rowsSettable = true
        list.selectedRows = []
        list.onSelectRows = { [unowned list] rows in list.selectedRows = rows }
        let row      = Element(kAXRowRole, window: .windowless, processID: pid, parent: list,
                               actions: ["AXShowDefaultUI", "AXShowAlternateUI"])
        let nameCell = Element(kAXCellRole, window: .windowless, processID: pid, parent: row)
        let name     = Element(kAXTextFieldRole, window: .windowless, processID: pid, parent: nameCell,
                               actions: [RemoteContentActuator<Element>.openAction, kAXShowMenuAction],
                               value: "carla_video_bw")
        let kindCell = Element(kAXCellRole, window: .windowless, processID: pid, parent: row)
        let kind     = Element(kAXStaticTextRole, window: .windowless, processID: pid, parent: kindCell,
                               value: "QT movie")
        finder.hit.element = kind

        let turn    = try await finder.seat.acquire()
        let receipt = try await Self.send(2, to: finder, turn: turn)
        #expect(list.rowWrites == [[row]])
        #expect(name.performed == [RemoteContentActuator<Element>.openAction], "the row's name field opens it")
        #expect(row.performed.isEmpty && kind.performed.isEmpty)
        #expect(finder.sender.sent.isEmpty)
        try finder.seat.confirm(receipt, .unknown)
        try finder.seat.release(turn)
    }

    @Test("an action answered unsupported did nothing, and any other answer may have acted")
    func refusalCodesArePrecise() {
        let unsupported = RemoteContentActuationRefusal.actionRefused(
            action: "AXOpen", code: AXError.actionUnsupported.rawValue
        )
        #expect(!unsupported.mayHaveTakenEffect)
        #expect(unsupported.description.contains("not supported"))
        // Finder answered AXOpen with -25205 on 06/10/2026, and its window then showed Downloads.
        let answered = RemoteContentActuationRefusal.actionRefused(
            action: "AXOpen", code: AXError.attributeUnsupported.rawValue
        )
        #expect(answered.mayHaveTakenEffect)
        #expect(answered.description.contains("may have taken effect"))
    }

    @Test("in Finder a scroll and a drag keep their posted route", arguments: [false, true])
    func finderScrollAndDragStillPost(drag: Bool) async throws {
        let finder = try await Self.finder(clicksThroughAccessibility: true, marker: drag ? 3_403 : 3_404)
        let start  = Self.point(in: finder.window)
        let end    = InputLocation(
            screenPoint       : CGPoint(x: start.screenPoint.x + 30, y: start.screenPoint.y + 30),
            windowPointFromTop: CGPoint(x: 70, y: 230)
        )
        let command: InputCommand = drag ? .drag(points: [start, end]) : .scroll(start, deltaY: -3)
        let turn    = try await finder.seat.acquire()
        let receipt = try await finder.seat.send(
            command, observation: try await observedReference(finder.seat), turn: turn
        )
        #expect(finder.sender.sent.map(\.command) == [command])
        #expect(finder.discovery.actuated.isEmpty)
        #expect(receipt.route.poster == .publicProcess)
        try finder.seat.confirm(receipt, .unknown)
        try finder.seat.release(turn)
    }

    @Test("Pro Tools presses the observed control once through the seat, including an AX timeout",
          arguments: [AXError.success, .cannotComplete])
    func proToolsClickUsesTheSeat(answer: AXError) async throws {
        let target = try await Self.finder(
            clicksThroughAccessibility: EndpointDiscovery.windowTreeClickedApplications.contains("com.avid.ProTools"),
            marker                    : answer == .success ? 3_420 : 3_421
        )
        let button = Element(
            kAXButtonRole,
            window   : target.element.window,
            processID: target.element.processID,
            parent   : target.element,
            actions  : [kAXPressAction],
            value    : "Mute"
        )
        button.performAnswer = answer
        target.hit.element = button
        let turn = try await target.seat.acquire()
        let observation = try await observedReference(target.seat)
        let command = InputCommand.click(Self.point(in: target.window))
        let receipt = try await target.seat.send(
            command,
            observation: observation,
            turn       : turn,
            platform   : QtPlatform()
        )
        #expect(button.performed == [kAXPressAction])
        #expect(target.sender.sent.isEmpty)
        #expect(receipt.eventCount == 0)
        #expect(receipt.route.poster == .accessibilityAction)
        await #expect(throws: (any Error).self) {
            try await target.seat.send(command, observation: observation, turn: turn, platform: QtPlatform())
        }
        #expect(button.performed == [kAXPressAction], "an uncertain reply never replays the press")
        try target.seat.confirm(receipt, .unknown)
        try target.seat.release(turn)
    }

    @Test("Pro Tools resolves a track control from its window when the app hit test hides the tracks",
          arguments: ["valid", "ambiguous", "foreignProcess", "foreignWindow", "outside", "wrongParent", "cycle"])
    func proToolsWindowTree(fault: String) async throws {
        let target = try await Self.finder(
            clicksThroughAccessibility: true, marker: 3_430, searchWindowTree: true
        )
        let root = target.element
        let frame = target.window.reference.frame
        root.frame = frame
        root.children = []
        let track = Element(kAXGroupRole, window: root.window, processID: root.processID, parent: root)
        track.frame = CGRect(x: frame.minX + 10, y: frame.minY + 120, width: 80, height: 300)
        let button = Element(kAXButtonRole, window: root.window, processID: root.processID, parent: track,
                             actions: [kAXPressAction], value: "Mute")
        button.frame = CGRect(x: frame.minX + 30, y: frame.minY + 190, width: 20, height: 20)
        let peer = Element(kAXGroupRole, window: root.window, processID: root.processID, parent: root)
        peer.frame = track.frame?.offsetBy(dx: 100, dy: 0)
        let peerButton = Element(kAXButtonRole, window: root.window, processID: root.processID, parent: peer,
                                 actions: [kAXPressAction], value: "Mute")
        peerButton.frame = button.frame?.offsetBy(dx: 100, dy: 0)
        let surrogate = Element(kAXScrollAreaRole, window: root.window, processID: root.processID)
        surrogate.parent = root
        surrogate.frame = frame
        target.hit.element = surrogate
        switch fault {
            case "ambiguous": peer.frame = track.frame
            case "foreignProcess": button.processID += 1
            case "foreignWindow": button.window = .window(target.window.id + 1)
            case "outside": root.frame = frame.offsetBy(dx: 5_000, dy: 0)
            case "wrongParent": button.parent = root
            case "cycle": track.children = [track]
            default: break
        }
        let turn = try await target.seat.acquire()
        if fault == "valid" {
            let receipt = try await Self.send(1, to: target, turn: turn)
            #expect(button.performed == [kAXPressAction])
            #expect(receipt.route.poster == .accessibilityAction && receipt.eventCount == 0)
            try target.seat.confirm(receipt, .unknown)
        } else {
            await #expect(throws: (any Error).self) { try await Self.send(1, to: target, turn: turn) }
            #expect(button.performed.isEmpty)
        }
        #expect(peerButton.performed.isEmpty && surrogate.performed.isEmpty)
        #expect(target.sender.sent.isEmpty)
        try target.seat.release(turn)
    }

    @Test("a click on another application's AppKit window is still posted")
    func anotherAppKitWindowStillPosts() async throws {
        let other = try await Self.finder(clicksThroughAccessibility: false, marker: 3_405)
        let click = InputCommand.click(Self.point(in: other.window))
        let turn    = try await other.seat.acquire()
        let receipt = try await other.seat.send(click, observation: try await observedReference(other.seat), turn: turn)
        #expect(other.sender.sent.map(\.command) == [click])
        #expect(other.row.writes.isEmpty && other.discovery.actuated.isEmpty)
        try other.seat.confirm(receipt, .unknown)
        try other.seat.release(turn)
    }

    // MARK: 6. An ordinary window keeps its events

    @Test("a click on an ordinary window still posts its events, and nothing is actuated")
    func anOrdinaryWindowStillPosts() async throws {
        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let discovery = GestureEndpointRoutingTests.Discovery()
        let seat      = makeSeat(
            sensing  : sensing,
            sender   : sender,
            marker   : 3_101,
            reader   : ControlledSurfaceReader(sensing: sensing),
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: discovery.discovery
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let observation = try await observedReference(seat)
        let frame       = window.reference.frame
        let click       = InputCommand.click(InputLocation(
            screenPoint       : CGPoint(x: frame.midX, y: frame.midY),
            windowPointFromTop: CGPoint(x: frame.width / 2, y: frame.height / 2)
        ))

        let turn    = try await seat.acquire()
        let receipt = try await seat.send(click, observation: observation, turn: turn)

        #expect(sender.sent.map(\.command) == [click])
        #expect(sender.addressed.last?.window.identity == window.reference.identity)
        #expect(receipt.route.poster == .publicProcess)
        #expect(receipt.eventCount == 2)
        #expect(discovery.actuated.isEmpty)
        try seat.confirm(receipt, .unknown)
        try seat.release(turn)
    }

    // MARK: The click vocabulary on its own

    @Test("each click maps to its action, and what has none refuses")
    func theClickVocabulary() throws {
        let surface = FakeGeometry.identity(windowNumber: 878)
        let geometry = try #require(WindowGeometryObservation(
            window: FakeGeometry.reference(
                frame: CGRect(x: 2000, y: 400, width: 400, height: 300),
                processID: 7_001, windowNumber: 879
            ),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        ))
        let endpoint = try GestureEndpointRoutingTests.endpoint(
            geometry, relation: .remoteContent, logicalSurface: surface, generation: 1,
            hostProcessID: surface.processID, lifetimeNanoseconds: 60_000_000_000
        )
        let named = DialogEndpointResolver<Element>.WindowReading.window(879)
        let sheet = Element(kAXSheetRole, window: .window(878), processID: surface.processID)
        let content = Element(kAXGroupRole, window: named, processID: surface.processID, parent: sheet,
                              actions: [kAXShowMenuAction])
        let row = Element(kAXRowRole, window: named, processID: surface.processID, parent: content)
        let cell = Element(kAXCellRole, window: named, processID: surface.processID, parent: row,
                           actions: [RemoteContentActuator<Element>.openAction])
        let field = Element(kAXTextFieldRole, window: named, processID: surface.processID, parent: content,
                            value: "ab")
        var target: Element?
        let actuator = Self.actuator { target }
        func click(_ count: Int, _ button: SeatCore.MouseButton = .left) -> InputCommand {
            .click(InputLocation(screenPoint: CGPoint(x: 2100, y: 500), windowPointFromTop: .zero),
                   button: button, count: count)
        }

        target = cell
        #expect(try actuator.actuate(click(1), endpoint: endpoint).get().action == kAXSelectedAttribute)
        #expect(row.writes == [.selected])
        #expect(try actuator.actuate(click(2), endpoint: endpoint).get().action == "AXSelected, then AXOpen")
        #expect(row.writes == [.selected, .selected], "a double click selects the row first")
        #expect(cell.performed == ["AXOpen"], "the row's own entry under the point opens")
        #expect(throws: RemoteContentActuationRefusal.unsupportedRole(kAXRowRole)) {
            try actuator.actuate(click(3), endpoint: endpoint).get()
        }
        // Go to Folder's suggestion rows, 14/10/2026: type_text's triple click on a row read as a label.
        let rowRefusal = RemoteContentActuationRefusal.unsupportedRole(kAXRowRole).description
        #expect(rowRefusal.contains("list row") && rowRefusal.contains("insert_text")
            && !rowRefusal.contains("Nothing clickable"), "a row is clickable: its refusal says what it takes")
        // A search button typed into, Preview's Export sheet, 14/10/2026; and a text field clicked twice.
        let buttonRefusal = RemoteContentActuationRefusal.unsupportedRole(kAXButtonRole).description
        #expect(buttonRefusal.contains("single click") && buttonRefusal.contains("insert_text")
            && !buttonRefusal.contains("Nothing clickable"), "\(buttonRefusal)")
        let fieldRefusal = RemoteContentActuationRefusal.unsupportedRole(kAXTextFieldRole).description
        #expect(fieldRefusal.contains("three to select") && !fieldRefusal.contains("Nothing clickable"), "\(fieldRefusal)")
        #expect(RemoteContentActuationRefusal.unsupportedRole("AXSlider").description.contains("Nothing clickable"))
        #expect(try actuator.actuate(click(1, .right), endpoint: endpoint).get().action == kAXShowMenuAction)
        #expect(content.performed == [kAXShowMenuAction])

        // A control drawn inside a row, such as a folder's disclosure triangle, is still pressed.
        let triangle = Element(kAXDisclosureTriangleRole, window: named, processID: surface.processID,
                               parent: row, actions: [kAXPressAction])
        target = triangle
        #expect(try actuator.actuate(click(1), endpoint: endpoint).get().action == kAXPressAction)
        #expect(triangle.performed == [kAXPressAction])
        #expect(row.writes == [.selected, .selected], "the triangle's press selects nothing")

        target = field
        #expect(throws: RemoteContentActuationRefusal.unsupportedRole(kAXTextFieldRole)) {
            try actuator.actuate(click(2), endpoint: endpoint).get()
        }
        #expect(try actuator.actuate(click(1), endpoint: endpoint).get().textField != nil)
        #expect(field.writes == [.selectedTextRange(location: 2, length: 0)])
        field.value = nil
        #expect(throws: RemoteContentActuationRefusal.unreadable, "a caret needs the value's length") {
            try actuator.actuate(click(3), endpoint: endpoint).get()
        }

        let drag = InputCommand.drag(points: [
            InputLocation(screenPoint: CGPoint(x: 2100, y: 500), windowPointFromTop: .zero),
            InputLocation(screenPoint: CGPoint(x: 2110, y: 510), windowPointFromTop: .zero),
        ])
        #expect(throws: RemoteContentActuationRefusal.gestureUnmeasured) {
            try actuator.actuate(drag, endpoint: endpoint).get()
        }
    }

    @Test("a windowless path is proved only for an endpoint attested from the surface's subtree")
    func aWindowlessPathNeedsSubtreeEvidence() throws {
        let surface = FakeGeometry.identity(windowNumber: 878)
        let geometry = try #require(WindowGeometryObservation(
            window: FakeGeometry.reference(
                frame: CGRect(x: 2000, y: 400, width: 400, height: 300),
                processID: 7_001, windowNumber: 879
            ),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        ))
        let sheet = Element(kAXSheetRole, window: .window(878), processID: surface.processID)
        let field = Element(kAXTextFieldRole, window: .windowless, processID: surface.processID, parent: sheet,
                            value: "")
        let actuator = Self.actuator { field }
        let click = InputCommand.click(InputLocation(screenPoint: CGPoint(x: 2100, y: 500), windowPointFromTop: .zero))

        for evidence in [InputEndpointEvidence.accessibilityNodeIdentity, .remoteContentOfSurface] {
            let now = DispatchTime.now().uptimeNanoseconds
            let endpoint = try #require(ResolvedInputEndpoint(
                kind: .pointer, geometry: geometry, evidence: evidence, relation: .remoteContent,
                logicalSurface: surface, accessibilityProcessID: surface.processID,
                selectionGeneration: 1, resolvedAtNanoseconds: now, expiresAtNanoseconds: now + 60_000_000_000
            ))
            let outcome = actuator.actuate(click, endpoint: endpoint)
            if evidence == .remoteContentOfSurface {
                #expect(try outcome.get().role == kAXTextFieldRole)
            } else {
                #expect(throws: RemoteContentActuationRefusal.outsideRemoteContent) { try outcome.get() }
            }
        }
    }
}
