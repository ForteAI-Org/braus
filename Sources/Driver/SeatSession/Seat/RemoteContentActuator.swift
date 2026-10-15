//
//  RemoteContentActuator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import os
import SeatCore

/// RemoteContentActuator acts on one click addressed to an out of process
/// panel's content through accessibility, so no event reaches the panel
/// service and the host application is never activated (ADR 0031).
///
/// Measured on 05/10/2026 on 27: a routed click into a file panel's content
/// activated its host in 75 to 525 ms, and a click on a sidebar row of the
/// inactive panel was eaten, while the accessibility actions below did the same
/// work with the host left in the background, three of three each.
///
/// The element is the one the host application's hit test answers at the
/// Command's point, proved by `DialogEndpointResolver.remoteContentPath`, or for
/// an ordinary window of an Apple native application, by `ownContentPath`
/// against the window itself. The click reaches the nearest element of that
/// path a click is mapped for; every other Command refuses. Nothing falls back
/// to posting here: for an ordinary window the seat posts the click itself when
/// the refusal says nothing was done (`wasDeclinedBeforeActing`).
///
/// It is generic over the node type so the mapping is proved without a panel
/// on the screen, as the resolver is.
nonisolated package struct RemoteContentActuator<Node: Equatable> {

    /// One attribute write the actuator makes.
    package enum Write: Equatable {
        case selected
        case focused
        case selectedTextRange(location: Int, length: Int)
        case selectedText(String)
    }

    /// The views a row belongs to: their selected rows select it, and in an ordinary window a
    /// pointer click gives them the focus.
    package static var rowContainerRoles: Set<String> {
        [kAXOutlineRole, kAXTableRole, kAXBrowserRole]
    }

    /// The roles a single click presses.
    package static var pressedRoles: Set<String> {
        [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXDisclosureTriangleRole, kAXMenuItemRole]
    }

    /// The roles whose press opens a menu window the panel service owns, which
    /// nothing in the seat follows: a click on them refuses, `select` uses them.
    package static var menuOpeningRoles: Set<String> {
        [kAXPopUpButtonRole, kAXMenuButtonRole]
    }

    /// The role of a web page's content, which the SDK names no constant for.
    package static var webAreaRole: String { "AXWebArea" }

    /// The action a file entry offers to be opened, which the SDK names no
    /// constant for.
    package static var openAction: String { "AXOpen" }

    /// The roles a click leaves a caret or a selection in.
    package static var textRoles: Set<String> {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    }

    /// The containers a grid of items is selected through, by their selected children.
    package static var itemListRoles: Set<String> {
        [kAXListRole, "AXCollection"]
    }

    /// Set for the one click of an ordinary window being acted on: a control is then used only
    /// when it offers the action, and a click it cannot take refuses before anything is done, so
    /// the seat may post it instead. A panel's remote content has no such fallback.
    private var isOrdinaryWindow = false

    /// Set for an Apple extension's click: the window number of the host surface whose own tree is
    /// searched for the pressed control first, and a `cannotComplete` answer is not a delivery.
    private var hostSurfaceNumber: Int?

    /// The label of the control the caller aimed at, which a press refuses to replace by another.
    private var requestedLabel: String?

    let path   : (CGPoint, ResolvedInputEndpoint) -> Result<[Node], RemoteContentActuationRefusal>
    let role   : (Node) -> String?
    let actions: (Node) -> [String]
    let value  : (Node) -> String?
    let perform: (Node, String) -> AXError
    let write  : (Node, Write) -> AXError

    /// The selection a container holds under one attribute, `AXSelectedChildren` of a list of items
    /// or `AXSelectedRows` of an outline or a table: whether it can be written, what it holds, and
    /// the write. `selectionIsSettable` answers for any attribute, a field's range or value too.
    let selectionIsSettable: (Node, String) -> Bool
    let selection          : (Node, String) -> [Node]?
    let writeSelection     : (Node, String, [Node]) -> AXError

    /// An element's own `AXSelected`, nil when it does not answer.
    let isSelected: (Node) -> Bool?

    /// The element above, the elements below, and the default button a window or a panel names.
    let parent       : (Node) -> Node?
    let children     : (Node) -> [Node]
    let defaultButton: (Node) -> Node?

    /// What finds a control again in the host's own tree: the host's window entry by number, an
    /// element's frame in screen points, and its title or description.
    let windowNode: (Int) -> Node?
    let frame     : (Node) -> CGRect?
    let label     : (Node) -> String?

    /// Every name an element answers to: its title, description and value, as the scene may name it.
    let labels    : (Node) -> [String]

    /// A checkbox's, switch's or radio button's own 0 or 1 `AXValue`, nil when it is neither.
    let toggleValue: (Node) -> Bool?

    /// Waits for an application to show what a press did, before it is read again.
    let settle: () -> Void

    /// Receives one line for every press, with the AXError it answered.
    let note: (String) -> Void

    package init(
        path   : @escaping (CGPoint, ResolvedInputEndpoint) -> Result<[Node], RemoteContentActuationRefusal>,
        role   : @escaping (Node) -> String?,
        actions: @escaping (Node) -> [String],
        value  : @escaping (Node) -> String?,
        perform: @escaping (Node, String) -> AXError,
        write  : @escaping (Node, Write) -> AXError,
        selectionIsSettable: @escaping (Node, String) -> Bool = { _, _ in false },
        selection          : @escaping (Node, String) -> [Node]? = { _, _ in nil },
        writeSelection     : @escaping (Node, String, [Node]) -> AXError = { _, _, _ in .attributeUnsupported },
        isSelected         : @escaping (Node) -> Bool? = { _ in nil },
        parent             : @escaping (Node) -> Node? = { _ in nil },
        children           : @escaping (Node) -> [Node] = { _ in [] },
        defaultButton      : @escaping (Node) -> Node? = { _ in nil },
        windowNode         : @escaping (Int) -> Node? = { _ in nil },
        frame              : @escaping (Node) -> CGRect? = { _ in nil },
        label              : @escaping (Node) -> String? = { _ in nil },
        labels             : ((Node) -> [String])? = nil,
        toggleValue        : @escaping (Node) -> Bool? = { _ in nil },
        settle             : @escaping () -> Void = {},
        note               : @escaping (String) -> Void = { _ in }
    ) {
        self.path    = path
        self.role    = role
        self.actions = actions
        self.value   = value
        self.perform = perform
        self.write   = write
        self.selectionIsSettable = selectionIsSettable
        self.selection           = selection
        self.writeSelection      = writeSelection
        self.isSelected          = isSelected
        self.parent              = parent
        self.children            = children
        self.defaultButton       = defaultButton
        self.windowNode          = windowNode
        self.frame               = frame
        self.label               = label
        self.labels              = labels ?? { label($0).map { [$0] } ?? [] }
        self.toggleValue         = toggleValue
        self.settle              = settle
        self.note                = note
    }

    /// Acts on `command` at the element under its point, and does nothing when
    /// it refuses.
    ///
    /// Inside a row, measured as a file list's name field, its text and its
    /// icon, a left click selects the row and two select it and open it through
    /// the element offering AXOpen; only a control drawn in the row is pressed.
    /// Outside one, a click presses a control or leaves a caret at the end of a
    /// field, and three select the field's whole value. A popup or a menu button
    /// refuses. A right click shows the nearest element's menu.
    ///
    /// With `prefersHost`, for an Apple extension's content, a press goes to the same control in the
    /// host's own tree when it is there (`hostCounterpart`), and `cannotComplete` is no delivery.
    ///
    /// With `label`, the control the caller aimed at, a click presses only an element of that name: when
    /// the hit one is named otherwise the same group's element of the requested name is pressed, and
    /// none refuses (`wrongElement`).
    func actuate(
        _ command  : InputCommand,
        endpoint   : ResolvedInputEndpoint,
        prefersHost: Bool = false,
        expecting label: String? = nil
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        var scoped = self
        scoped.requestedLabel = label.flatMap { Self.normalized($0).isEmpty ? nil : $0 }
        scoped.isOrdinaryWindow = endpoint.relation == .logicalSurface
        scoped.hostSurfaceNumber = prefersHost && endpoint.relation == .remoteContent
            ? endpoint.logicalSurface.windowNumber : nil
        return scoped.actuateScoped(command, endpoint: endpoint)
    }

    private func actuateScoped(
        _ command: InputCommand,
        endpoint : ResolvedInputEndpoint
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {

        guard case .click(let location, let button, let count) = command else {
            return .failure(.gestureUnmeasured)
        }
        let nodes: [Node]
        switch path(location.screenPoint, endpoint) {
            case .success(let found): nodes = found
            case .failure(let refusal): return .failure(refusal)
        }
        guard !nodes.isEmpty else { return .failure(.noElementAtPoint) }
        let roles = nodes.map { role($0) ?? kAXUnknownRole }
        // A page keeps its posted click: its elements are not measured to take accessibility actions.
        if isOrdinaryWindow, roles.contains(Self.webAreaRole) { return .failure(.webContent) }

        if button == .right {
            guard count == 1, let menu = nodes.first(where: { actions($0).contains(kAXShowMenuAction) })
            else { return .failure(.unsupportedRole(roles[0])) }
            return press(menu, kAXShowMenuAction)
        }
        // Column view's selection was never measured; list view's rows were.
        if roles.contains(kAXBrowserRole) { return .failure(.columnView) }
        // A row bounds what the click reaches: the row, or a control drawn in it.
        let row     = roles.firstIndex(of: kAXRowRole)
        let reached = 0..<(row.map { $0 + 1 } ?? roles.count)
        let control = reached.first {
            Self.pressedRoles.contains(roles[$0]) || Self.menuOpeningRoles.contains(roles[$0])
        }
        if let control, Self.menuOpeningRoles.contains(roles[control]) {
            return .failure(.opensMenu(roles[control]))
        }
        if let row {
            // An editable field drawn in the row takes the caret, where a click used to select the row only.
            if let field = editableField(in: nodes, roles: roles, before: row), control.map({ field < $0 }) ?? true {
                switch count {
                    case 1    : return select(in: nodes[field], role: roles[field], wholeValue: false)
                    case 3... : return select(in: nodes[field], role: roles[field], wholeValue: true)
                    default   : return .failure(.unsupportedRole(roles[field]))
                }
            }
            if count == 1, let control { return pressTarget(nodes[control]) }
            guard count <= 2 else { return .failure(.unsupportedRole(kAXRowRole)) }
            var selected: String
            switch selectRow(at: row, of: nodes) {
                case .success(let attribute): selected = attribute
                case .failure(let refusal): return .failure(refusal)
            }
            // In an ordinary window a click also focuses the row's list, which a key such as
            // Finder's / then reaches; its answer is reported, never retried.
            if endpoint.relation == .logicalSurface,
               let list = nodes[(row + 1)...].first(where: { Self.rowContainerRoles.contains(role($0) ?? "") }) {
                selected += write(list, .focused) == .success ? ", its list focused" : ", its list not focused"
            }
            guard count == 2 else {
                return .success(RemoteContentActuation(action: selected, role: kAXRowRole, textField: nil))
            }
            return open(row: nodes[row], under: nodes[...row], selected: selected)
        }
        let mapped = Self.pressedRoles.union(Self.textRoles)
        // An item of a grid, outside any row or control, is selected through its list.
        if control == nil, let list = nodes.indices.first(where: {
            Self.itemListRoles.contains(roles[$0]) && selectionIsSettable(nodes[$0], kAXSelectedChildrenAttribute)
        }), !roles[..<list].contains(where: mapped.contains) {
            return item(in: nodes, list: list, roles: roles, count: count)
        }
        guard let index = roles.firstIndex(where: mapped.contains) else {
            return .failure(.unsupportedRole(roles[0]))
        }
        switch count {
            case 1 where Self.pressedRoles.contains(roles[index]):
                return pressTarget(nodes[index])
            case 1 where Self.textRoles.contains(roles[index]):
                return select(in: nodes[index], role: roles[index], wholeValue: false)
            case 3... where Self.textRoles.contains(roles[index]):
                return select(in: nodes[index], role: roles[index], wholeValue: true)
            default:
                return .failure(.unsupportedRole(roles[index]))
        }
    }

    /// The nearest text element above `row` whose caret and value can both be written: a field that
    /// takes text in place. A file's name in a list can have a writable range and never a value.
    private func editableField(in nodes: [Node], roles: [String], before row: Int) -> Int? {
        (0..<row).first {
            Self.textRoles.contains(roles[$0])
                && selectionIsSettable(nodes[$0], kAXSelectedTextRangeAttribute)
                && selectionIsSettable(nodes[$0], kAXValueAttribute)
        }
    }

    /// Selects the item under the point through the list's selected children, and on a double click
    /// presses the default button, or opens the item where none is named.
    ///
    /// Measured on 06/10/2026 in an open panel's icon view: only `AXSelectedChildren` on the outer
    /// list, holding the item group, selected the file; writing the group's or the image's
    /// `AXSelected`, the inner list's selected children or the image in the outer list answered 0
    /// and changed nothing. So each candidate, the list's nearest descendant first, is written and
    /// read back, and only a verified selection counts. AXOpen on the image completed the panel but
    /// activated the host, which is why the default button comes first.
    private func item(
        in nodes: [Node],
        list    : Int,
        roles   : [String],
        count   : Int
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        guard count <= 2 else { return .failure(.unsupportedRole(roles[0])) }
        let candidates = (0..<list).reversed().filter { !Self.itemListRoles.contains(roles[$0]) }
        // A hit already selected proves nothing: only a change read back does.
        let wasSelected = isSelected(nodes[0]) == true
        guard let chosen = candidates.first(where: { index in
            writeSelection(nodes[list], kAXSelectedChildrenAttribute, [nodes[index]]) == .success
                && (selection(nodes[list], kAXSelectedChildrenAttribute) == [nodes[index]]
                    || !wasSelected && isSelected(nodes[0]) == true)
        }) else { return .failure(.selectionNotVerified(roles[0])) }
        let selected = RemoteContentActuation(
            action   : kAXSelectedChildrenAttribute,
            role     : roles[chosen],
            textField: nil
        )
        guard count == 2 else { return .success(selected) }

        var above = nodes[list...].map { $0 }
        if let top = nodes.last, let surface = parent(top) { above.append(surface) }
        if let button = above.lazy.compactMap(defaultButton).first {
            return press(button, kAXPressAction)
        }
        guard let opener = nodes[..<list].first(where: { actions($0).contains(Self.openAction) }) else {
            return .failure(.unsupportedRole(roles[0]))
        }
        return press(opener, Self.openAction)
    }

    /// Selects the row at `row` of the path and answers the attribute that did it, only once a
    /// selection is read back.
    ///
    /// Measured on 06/10/2026 on Finder's sidebar, Finder in the background: `AXSelected` on the row
    /// answered 0 and selected it without navigating, while `[row]` written to the sidebar outline's
    /// `AXSelectedRows` navigated, two of two. So the nearest outline or table above the row whose
    /// selected rows are settable is written first, and the row's own `AXSelected`, which navigated
    /// in a file panel's sidebar three of three, is the fallback, read back on the row or the list.
    private func selectRow(
        at row  : Int,
        of nodes: [Node]
    ) -> Result<String, RemoteContentActuationRefusal> {
        let target = nodes[row]
        let list   = nodes[(row + 1)...].first {
            Self.rowContainerRoles.contains(role($0) ?? "") && selectionIsSettable($0, kAXSelectedRowsAttribute)
        }
        func listHoldsRow() -> Bool { list.map { selection($0, kAXSelectedRowsAttribute) == [target] } ?? false }
        let listWritten = list.map { writeSelection($0, kAXSelectedRowsAttribute, [target]) == .success } ?? false
        if listWritten, listHoldsRow() { return .success(kAXSelectedRowsAttribute) }
        let code = write(target, .selected)
        guard code == .success else {
            // An ordinary window's row that nothing could write did nothing: its click is posted.
            if isOrdinaryWindow, !listWritten, code == .attributeUnsupported || code == .actionUnsupported {
                return .failure(.unsupportedRole(kAXRowRole))
            }
            return .failure(.actionRefused(action: kAXSelectedAttribute, code: code.rawValue))
        }
        guard isSelected(target) == true || listHoldsRow() else { return .failure(.selectionNotVerified(kAXRowRole)) }
        return .success(kAXSelectedAttribute)
    }

    /// Opens what a double click on a selected row opens: AXOpen on the innermost element of the
    /// path offering it, the row last, else on the nearest of the row's descendants offering it,
    /// three levels down at most. Finder's file list offers it on the name field, wherever in the
    /// row the click landed; its sidebar rows offer only AXShowDefaultUI and AXShowAlternateUI, and
    /// navigate on the selection alone. A miss or a refused AXOpen keeps the selection it follows.
    private func open(
        row     : Node,
        under path: ArraySlice<Node>,
        selected: String
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        func opens(_ node: Node) -> Bool { actions(node).contains(Self.openAction) }
        var opener = path.first(where: opens)
        var level  = children(row)
        for _ in 0..<3 where opener == nil && !level.isEmpty {
            opener = level.first(where: opens)
            level  = Array(level.flatMap(children).prefix(64))
        }
        guard let opener else { return .failure(.selectedNotOpened(code: nil)) }
        let code = perform(opener, Self.openAction)
        guard code == .success || code == .cannotComplete else {
            return .failure(.selectedNotOpened(code: code.rawValue))
        }
        return .success(RemoteContentActuation(
            action   : selected + ", then " + Self.openAction,
            role     : role(opener) ?? kAXUnknownRole,
            textField: nil
        ))
    }

    /// Presses the control a click reached, once it is the one the caller aimed at: an element named
    /// otherwise is replaced by its group's element of the requested name, and with none nothing is
    /// pressed. An element with no name of its own cannot be told apart and is pressed.
    private func pressTarget(_ node: Node) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        guard let wanted = requestedLabel, case let names = labels(node), !names.isEmpty,
              !names.contains(where: { Self.sameLabel($0, wanted) })
        else { return press(node, kAXPressAction) }
        let found = names[0]
        guard let other = named(wanted, besides: node) else {
            note("the element at that point is '\(found)', not '\(wanted)': nothing was pressed")
            return .failure(.wrongElement(requested: wanted, found: found))
        }
        note("the element at that point is '\(found)', so '\(wanted)' is pressed instead")
        return press(other, kAXPressAction)
    }

    /// The element of the requested name that offers AXPress: one of the hit element's siblings, else
    /// for an extension one in the host window's tree near it.
    private func named(_ wanted: String, besides node: Node) -> Node? {
        func fits(_ candidate: Node) -> Bool {
            candidate != node && actions(candidate).contains(kAXPressAction)
                && labels(candidate).contains { Self.sameLabel($0, wanted) }
        }
        if let siblings = parent(node).map(children), let match = siblings.first(where: fits) { return match }
        return hostSurfaceNumber == nil ? nil : search(near: node, where: fits)
    }

    /// Whether two names are one, as the scene writes it: trimmed, without the state prefix some
    /// toolkits add or a " #N" ordinal, and ignoring case and accents.
    static func sameLabel(_ left: String, _ right: String) -> Bool { normalized(left) == normalized(right) }

    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Shown. ", "Hidden. ", "Selected. ", "Active. ", "Inactive. "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if let hash = text.range(of: " #", options: .backwards), !text[hash.upperBound...].isEmpty,
           text[hash.upperBound...].allSatisfy(\.isNumber) {
            text = String(text[..<hash.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Performs one action on the node, or for an Apple extension's press on the same control in the
    /// host's tree, never on both, and logs what the application answered.
    ///
    /// A panel's default button closes the panel before answering, -25204, so that answer is a
    /// delivery there, verified by the panel disappearing. An extension's control has no such
    /// reason: its -25204 may have done nothing, so it refuses as an action of unknown effect.
    private func press(
        _ node  : Node,
        _ action: String
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        // An ordinary window's element that does not offer the action is not asked for it.
        if isOrdinaryWindow, !actions(node).contains(action) {
            return .failure(.unsupportedRole(role(node) ?? kAXUnknownRole))
        }
        let host   = action == kAXPressAction ? hostCounterpart(of: node, action: action) : nil
        let target = host ?? node
        let before = hostSurfaceNumber != nil && action == kAXPressAction ? readableState(of: target) : nil
        let code   = perform(target, action)
        note("\(action) on \(role(target) ?? kAXUnknownRole) in the \(host == nil ? "path's" : "host's") tree "
            + "answered AXError \(code.rawValue) (\(code))")
        let delivered = code == .success || code == .cannotComplete && hostSurfaceNumber == nil
        guard delivered else {
            return .failure(.actionRefused(action: action, code: code.rawValue))
        }
        var actuation = RemoteContentActuation(
            action   : host == nil ? action : action + " in the host's tree",
            role     : role(target) ?? kAXUnknownRole,
            textField: nil
        )
        if code == .success, hostSurfaceNumber != nil, action == kAXPressAction {
            verify(target, before: before, &actuation)
        }
        return .success(actuation)
    }

    /// An extension's press that answered success is read back when the control shows a state.
    /// Unchanged, it is pressed once through its child or its parent, and when that changes nothing
    /// either the actuation asks for one posted click. A control with no readable state, before or
    /// after, is never pressed or clicked again: nothing proves the press did not work.
    private func verify(_ target: Node, before: Bool?, _ actuation: inout RemoteContentActuation) {
        let name   = label(target) ?? role(target) ?? kAXUnknownRole
        let isFlip = role(target) == kAXCheckBoxRole
        // A segment already on cannot show a press, where a switch can always flip.
        guard let before, isFlip || !before else {
            note("AXPress on '\(name)' answered success and its state is "
                + "\(before.map { $0 ? "on" : "off" } ?? "not readable"): nothing proves it was ignored")
            return
        }
        // Nil when the control stopped answering, which proves nothing either way.
        func changed() -> Bool? {
            settle()
            return readableState(of: target).map { isFlip ? $0 != before : $0 }
        }
        guard let first = changed() else { return note("'\(name)' no longer answers its state after AXPress") }
        guard !first else { return }

        let child  = children(target).first { actions($0).contains(kAXPressAction) }
        let other  = child ?? parent(target).flatMap { actions($0).contains(kAXPressAction) ? $0 : nil }
        let helper = child == nil ? "parent" : "child"
        if let other {
            let code = perform(other, kAXPressAction)
            note("AXPress on '\(name)' left its state unchanged, so AXPress on its \(helper) answered "
                + "AXError \(code.rawValue) (\(code))")
            guard let second = changed() else { return note("'\(name)' no longer answers its state") }
            if second {
                actuation = RemoteContentActuation(
                    action   : "\(kAXPressAction) on its \(helper)",
                    role     : role(other) ?? kAXUnknownRole,
                    textField: nil
                )
                return
            }
        }
        note("'\(name)' still shows the same state after accessibility, so one click is posted on the host window")
        actuation.needsPostedClick = true
    }

    /// The state a control shows, nil when it shows none or no longer answers: a checkbox's, switch's
    /// or radio button's 0 or 1 value, else its `AXSelected`, else off for a segment of a selector
    /// whose selected segment answers (`isSegment`).
    private func readableState(of node: Node) -> Bool? {
        guard let kind = role(node) else { return nil }
        if kind == kAXCheckBoxRole || kind == kAXRadioButtonRole, let on = toggleValue(node) { return on }
        return isSelected(node) ?? (isSegment(node) ? false : nil)
    }

    /// True for a button in a run of contiguous buttons that offer AXPress, in one parent with no
    /// other element between them, when one button of the run answers `AXSelected`: a segmented
    /// selector, where an unselected segment answers nothing. A lone button or one separated by
    /// other elements shows no state.
    private func isSegment(_ node: Node) -> Bool {
        func member(_ candidate: Node) -> Bool {
            role(candidate) == kAXButtonRole && actions(candidate).contains(kAXPressAction)
        }
        guard member(node), let siblings = parent(node).map(children), let at = siblings.firstIndex(of: node)
        else { return false }
        var first = at
        var last  = at
        while first > 0, member(siblings[first - 1]) { first -= 1 }
        while last + 1 < siblings.count, member(siblings[last + 1]) { last += 1 }
        return siblings[first...last].contains { isSelected($0) != nil }
    }

    /// The control in the host's own tree that is the one `node` shows: the first element, nearest
    /// the host window first, of the same role and label, offering the action, whose frame is within
    /// 2 points of the node's on every side. The node is the one asked for by then (`pressTarget`), so
    /// its copy carries the asked name too. Nil when the host has none, or is not asked. Content hosted
    /// in a window is reached through the host's tree as the same elements, so there none is found
    /// and the node itself is pressed.
    private func hostCounterpart(of node: Node, action: String) -> Node? {
        guard let target = frame(node) else { return nil }
        let wanted = role(node)
        let name   = label(node)
        return search(near: node) { candidate in
            candidate != node && role(candidate) == wanted && label(candidate) == name
                && actions(candidate).contains(action)
                && frame(candidate).map {
                    abs($0.minX - target.minX) <= 2 && abs($0.minY - target.minY) <= 2
                        && abs($0.width - target.width) <= 2 && abs($0.height - target.height) <= 2
                } ?? false
        }
    }

    /// The first element of the host window's tree, nearest the window first, that `fits`. Only
    /// branches whose frame holds the node's centre are entered, and at most 512 elements are read.
    private func search(near node: Node, where fits: (Node) -> Bool) -> Node? {
        guard let number = hostSurfaceNumber, let root = windowNode(number), let target = frame(node) else {
            return nil
        }
        let centre = CGPoint(x: target.midX, y: target.midY)
        var level   = [root]
        var visited = 0
        while !level.isEmpty, visited < 512 {
            var below: [Node] = []
            for candidate in level {
                visited += 1
                if fits(candidate) { return candidate }
                below += children(candidate).filter { frame($0)?.insetBy(dx: -1, dy: -1).contains(centre) ?? true }
            }
            level = below
        }
        return nil
    }

    /// Leaves a caret at the end of the field's value, or selects all of it.
    /// A value that cannot be read refuses, since its length is the caret.
    private func select(
        in node   : Node,
        role      : String,
        wholeValue: Bool
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        if isOrdinaryWindow, !selectionIsSettable(node, kAXSelectedTextRangeAttribute) {
            return .failure(.unsupportedRole(role))
        }
        guard let current = value(node) else { return .failure(.unreadable) }
        let length = current.utf16.count
        let code   = write(node, .selectedTextRange(location: wholeValue ? 0 : length, length: wholeValue ? length : 0))
        guard code == .success else {
            return .failure(.actionRefused(action: kAXSelectedTextRangeAttribute, code: code.rawValue))
        }
        let field = RemoteContentActuation.TextField(
            isAnswering: { self.role(node) != nil },
            replaceSelection: { text in
                let code = self.write(node, .selectedText(text))
                guard code == .success else {
                    return .failure(.actionRefused(action: kAXSelectedTextAttribute, code: code.rawValue))
                }
                return .success(self.value(node))
            }
        )
        return .success(RemoteContentActuation(
            action   : kAXSelectedTextRangeAttribute,
            role     : role,
            textField: field
        ))
    }
}

// MARK: - The shipping actuator

private let remoteContentLog = Logger(subsystem: "dev.forte.AgentSeatKit", category: "RemoteContentActuator")

extension RemoteContentActuator where Node == AXUIElement {

    /// How long one action or write may wait for its answer. Longer than a
    /// read's, because the host forwards it to the panel service.
    private static var effectTimeout: Float { 0.5 }

    /// The actuator the seat runs, over the assigned application's own
    /// accessibility tree: the remote elements answer there, with true screen
    /// coordinates.
    package static func accessibility(assignedProcessID: Int32) -> RemoteContentActuator<AXUIElement> {
        let resolver = DialogEndpointResolver<AXUIElement>.accessibility(assignedProcessID: assignedProcessID)
        func attribute<Value>(_ node: AXUIElement, _ name: String) -> Value? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
            return value as? Value
        }
        return RemoteContentActuator(
            path   : { point, endpoint in
                endpoint.relation == .remoteContent
                    ? resolver.remoteContentPath(at: point, of: endpoint)
                    : resolver.ownContentPath(at: point, of: endpoint)
            },
            role   : { attribute($0, kAXRoleAttribute) },
            actions: { node in
                var names: CFArray?
                guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
                return names as? [String] ?? []
            },
            value  : { attribute($0, kAXValueAttribute) },
            perform: { node, action in
                AXUIElementSetMessagingTimeout(node, effectTimeout)
                return AXUIElementPerformAction(node, action as CFString)
            },
            write  : { node, write in
                AXUIElementSetMessagingTimeout(node, effectTimeout)
                switch write {
                    case .selected:
                        return AXUIElementSetAttributeValue(node, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                    case .focused:
                        return AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    case .selectedTextRange(let location, let length):
                        var range = CFRange(location: location, length: length)
                        guard let value = AXValueCreate(.cfRange, &range) else { return .failure }
                        return AXUIElementSetAttributeValue(node, kAXSelectedTextRangeAttribute as CFString, value)
                    case .selectedText(let text):
                        return AXUIElementSetAttributeValue(
                            node,
                            kAXSelectedTextAttribute as CFString,
                            text as CFString
                        )
                }
            },
            selectionIsSettable: { node, name in
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(node, name as CFString, &settable) == .success
                    && settable.boolValue
            },
            selection     : { attribute($0, $1) },
            writeSelection: { container, name, nodes in
                AXUIElementSetMessagingTimeout(container, effectTimeout)
                return AXUIElementSetAttributeValue(container, name as CFString, nodes as CFArray)
            },
            isSelected      : { (attribute($0, kAXSelectedAttribute) as NSNumber?)?.boolValue },
            parent          : { node in
                guard let parent: AXUIElement = attribute(node, kAXParentAttribute) else { return nil }
                AXUIElementSetMessagingTimeout(parent, BoundedAccessibilityRead.fastTimeout)
                return parent
            },
            children        : { node in
                let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
                children.forEach { AXUIElementSetMessagingTimeout($0, BoundedAccessibilityRead.fastTimeout) }
                return children
            },
            defaultButton   : { attribute($0, kAXDefaultButtonAttribute) },
            windowNode      : { resolver.windowNode($0) },
            frame           : { resolver.nodeFrame($0) },
            label           : { node in
                [kAXTitleAttribute, kAXDescriptionAttribute]
                    .lazy.compactMap { attribute(node, $0) as String? }.first { !$0.isEmpty }
            },
            labels          : { node in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .compactMap { attribute(node, $0) as String? }.filter { !$0.isEmpty }
            },
            toggleValue     : { node in
                guard let number: NSNumber = attribute(node, kAXValueAttribute), [0, 1].contains(number.intValue)
                else { return nil }
                return number.boolValue
            },
            // An extension answers its new state after a short round trip.
            settle          : { Thread.sleep(forTimeInterval: 0.2) },
            note            : { line in remoteContentLog.notice("\(line, privacy: .public)") }
        )
    }
}
