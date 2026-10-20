import ApplicationServices
import CoreGraphics
import Foundation

/// The accessibility rung on the live tree. An address is resolved with the same child rules as the
/// read that produced it (visible children and rows, or every child), then checked against the role
/// and name the scene showed before anything is sent. The call's stop is checked right before each write
/// (`MacAccessibilityActing`): before the first one it throws `CancellationError` with nothing sent; after one
/// went out, it answers `uncertain`.
extension LiveMacTreeReader: MacAccessibilityActing {

    @concurrent
    public func perform(_ action: String, on element: MacElementAddress) async throws {
        let (target, _) = try resolve(element)
        guard actionNames(target).contains(action) else { throw MacTreeFailure.actionNotListed(action) }
        try Task.checkCancellation()
        try check(AXUIElementPerformAction(target, action as CFString), doing: action)
    }

    @concurrent
    public func select(_ element: MacElementAddress) async throws {
        let (target, parent) = try resolve(element)
        let containerRole = batch(parent, [kAXRoleAttribute]).string(kAXRoleAttribute)
        try Self.select(target, in: parent, containerRole: containerRole, through: LiveSelectionWriter())
    }

    /// Selects `target`: through its own `AXSelected` when it says that is settable, else through its container,
    /// `AXSelectedRows` on a table or an outline and `AXSelectedChildren` on a list (a Finder column item has no
    /// `AXSelected`, measured 15 Oct). The way is chosen before anything is written, from what the elements say they
    /// let set; once a write went, its answer is `failure(after:)`'s and nothing is written a second time (R06).
    /// Neither settable: `actionNotListed`, nothing written.
    static func select<Writer: SelectionWriting>(
        _ target      : Writer.Element,
        in parent     : Writer.Element,
        containerRole : String?,
        through writer: Writer
    ) throws {
        if writer.isSettable(target, kAXSelectedAttribute) {
            try Task.checkCancellation()
            if let failure = failure(after: writer.setSelected(target), doing: kAXSelectedAttribute) { throw failure }
            return
        }
        let attribute = containerRole == kAXTableRole || containerRole == kAXOutlineRole
            ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute
        guard writer.isSettable(parent, attribute) else {
            throw MacTreeFailure.actionNotListed("\(kAXSelectedAttribute), or its container's \(attribute)")
        }
        try Task.checkCancellation()
        let answer = writer.setSelection([target], of: parent, attribute: attribute)
        if let failure = failure(after: answer, doing: attribute) { throw failure }
    }

    @concurrent
    public func focus(_ element: MacElementAddress) async throws {
        let (target, _) = try resolve(element)
        let window = try window(element)
        try Self.focus(
            settingMain: { AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) },
            thenFocused: { AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        )
    }

    /// Focus's two writes, `AXMain` on the window then `AXFocused` on the element, each answering the accessibility
    /// error it got. They are two effects, not one: a stop before the first throws `CancellationError` with nothing
    /// written; a stop after `AXMain` went out leaves `AXFocused` unwritten and answers `uncertain`, since the window
    /// may now be main, and nothing is written again. An error after either write is `failure(after:)`'s (R06).
    static func focus(settingMain setMain: () -> AXError, thenFocused setFocused: () -> AXError) throws {
        try Task.checkCancellation()
        if let failure = failure(after: setMain(), doing: kAXMainAttribute) { throw failure }
        guard !Task.isCancelled else {
            throw MacTreeFailure.uncertain("\(kAXMainAttribute) went out, then the call was stopped before "
                + "\(kAXFocusedAttribute): the window may be main, the element is not focused")
        }
        if let failure = failure(after: setFocused(), doing: kAXFocusedAttribute) { throw failure }
    }

    @concurrent
    public func scroll(_ area: MacElementAddress, _ direction: MacScrollDirection) async throws -> String {
        let (target, _) = try resolve(area)
        let vertical = direction == .up || direction == .down
        // The scroll bar first: SwiftUI lists the page actions, answers -25205, scrolls anyway and the
        // wrong way (measured 15 Oct). A bar's value is set and read back exactly.
        guard let bar = element(target, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute) else {
            guard actionNames(target).contains(direction.pageAction) else { throw MacTreeFailure.actionNotListed(direction.pageAction) }
            try Task.checkCancellation()
            try check(AXUIElementPerformAction(target, direction.pageAction as CFString), doing: direction.pageAction)
            return direction.pageAction
        }
        let current = (batch(bar, [kAXValueAttribute]).values[kAXValueAttribute] as? NSNumber)?.doubleValue ?? 0
        // One page is the share of the content the area shows; the content is the area's first child
        // that is not a scroll bar. Without it, a quarter.
        let areaValues = batch(target, [kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
        let content = areaValues.elements(kAXChildrenAttribute)
            .first { batch($0, [kAXRoleAttribute]).string(kAXRoleAttribute) != kAXScrollBarRole }
            .flatMap { batch($0, [kAXPositionAttribute, kAXSizeAttribute]).frame }
        var page = 0.25
        if let shown = areaValues.frame, let content {
            let (seen, whole) = vertical ? (shown.height, content.height) : (shown.width, content.width)
            if whole > seen, whole > 0 { page = max(0.05, Double(seen / (whole - seen)) * 0.9) }
        }
        let forward = direction == .down || direction == .right
        let next = min(1, max(0, current + (forward ? page : -page)))
        try Task.checkCancellation()
        try check(AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, next as CFNumber), doing: "scroll bar AXValue")
        return "scroll bar AXValue \(String(format: "%.2f", current)) -> \(String(format: "%.2f", next))"
    }

    @concurrent
    public func readBack(_ element: MacElementAddress) async -> MacTreeNode? {
        guard let (target, _) = try? resolve(element, checksIdentity: false) else { return nil }
        let values = batch(target, Self.nodeAttributes)
        return MacTreeNode(
            path           : element.path,
            role           : values.string(kAXRoleAttribute) ?? "AXUnknown",
            subrole        : values.string(kAXSubroleAttribute),
            identifier     : values.string(kAXIdentifierAttribute),
            title          : values.string(kAXTitleAttribute),
            descriptionText: values.string(kAXDescriptionAttribute),
            help           : values.string(kAXHelpAttribute),
            placeholder    : values.string(kAXPlaceholderValueAttribute),
            value          : values.text(kAXValueAttribute),
            isEnabled      : values.bool(kAXEnabledAttribute),
            isSelected     : values.bool(kAXSelectedAttribute),
            isExpanded     : values.bool(kAXExpandedAttribute),
            isFocused      : values.bool(kAXFocusedAttribute),
            frame          : values.frame,
            actions        : actionNames(target)
        )
    }

    // MARK: Resolution

    private func window(_ element: MacElementAddress) throws -> AXUIElement {
        guard isTrusted else { throw MacTreeFailure.notTrusted }
        let application = AXUIElementCreateApplication(element.processID)
        AXUIElementSetMessagingTimeout(application, MacTreeLimits.standard.applicationTimeout)
        guard let windows = elements(application, kAXWindowsAttribute) else {
            throw MacTreeFailure.applicationUnreachable(element.processID)
        }
        let window = try Self.attestedWindow(in: windows, for: element)
        // As in a read: without it the window waits on the system's default, about 6 s, for the first
        // read of every resolution and for `AXMain`.
        AXUIElementSetMessagingTimeout(window, MacTreeLimits.standard.applicationTimeout)
        return window
    }

    /// The window at the address's index in `windows`, the app's `AXWindows` now, when it is the window the address
    /// was read in (`MacElementAddress.admits`). Another window there, such as a second document the app raised
    /// since the scene, is `staleTarget`: nothing is requested and the engine reads again. It compares identities only
    /// and sends nothing to the app, so every request (perform, select, focus, scroll, readBack) checks it first.
    static func attestedWindow(in windows: [AXUIElement], for element: MacElementAddress) throws -> AXUIElement {
        guard windows.indices.contains(element.windowIndex) else {
            throw MacTreeFailure.windowNotFound(index: element.windowIndex)
        }
        let window = windows[element.windowIndex]
        guard element.admits(MacWindowIdentity(window: window)) else {
            throw MacTreeFailure.staleTarget(path: element.path)
        }
        return window
    }

    /// The live element at the address and its parent, in the window the address was read in (`window(_:)`). With
    /// `checksIdentity`, a role or a name that differs from the address's is `staleTarget`; without it, the window is
    /// still checked.
    private func resolve(_ element: MacElementAddress, checksIdentity: Bool = true) throws -> (AXUIElement, AXUIElement) {
        var current = try window(element)
        var parent = current
        for step in element.path {
            let values = batch(current, Self.nodeAttributes)
            let children = element.visibleOnly
                ? visibleChildren(current, values: values) : values.elements(kAXChildrenAttribute).map(MacChild.element)
            guard children.indices.contains(step), case .element(let child) = children[step] else {
                throw MacTreeFailure.staleTarget(path: element.path)
            }
            parent = current
            current = child
            AXUIElementSetMessagingTimeout(current, MacTreeLimits.standard.elementTimeout)
        }
        guard checksIdentity else { return (current, parent) }
        let values = batch(current, Self.nodeAttributes)
        guard values.string(kAXRoleAttribute) == element.role else { throw MacTreeFailure.staleTarget(path: element.path) }
        if let name = element.name {
            let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
                .compactMap { values.string($0) } + [values.text(kAXValueAttribute)].compactMap { $0 }
            // A row is named by the texts it holds.
            guard names.contains(name) || (element.role == kAXRowRole && texts(below: current, depth: 3).contains(name))
            else { throw MacTreeFailure.staleTarget(path: element.path) }
        }
        return (current, parent)
    }

    /// The static texts' values under an element, a few levels down.
    private func texts(below element: AXUIElement, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        return (elements(element, kAXChildrenAttribute) ?? []).flatMap { child -> [String] in
            let values = batch(child, [kAXRoleAttribute, kAXValueAttribute])
            let own = values.string(kAXRoleAttribute) == kAXStaticTextRole ? [values.text(kAXValueAttribute)].compactMap { $0 } : []
            return own + texts(below: child, depth: depth - 1)
        }
    }

    /// What a request's answer means once the request reached the app: nothing on success; otherwise its effect is
    /// unknown, since an app may act and still answer an error (SwiftUI answers -25205 to a page scroll and scrolls),
    /// so it is uncertain and never replayed on another rung (R06). Only what is read before the request, the
    /// element's own list of actions, refuses a gesture as one that was not sent (`actionNotListed`).
    static func failure(after result: AXError, doing what: String) -> MacTreeFailure? {
        switch result {
            case .success       : nil
            case .cannotComplete: .uncertain("\(what): the app did not answer in time")
            default             : .uncertain("\(what): the app answered AXError \(result.rawValue) to a request it "
                                             + "received, so it may have acted")
        }
    }

    private func check(_ result: AXError, doing what: String) throws {
        if let failure = Self.failure(after: result, doing: what) { throw failure }
    }
}

/// SelectionWriting is what `select` writes through: whether an attribute is settable, read before any write, and the
/// writes themselves, each answering the accessibility error it got.
protocol SelectionWriting {
    associatedtype Element
    func isSettable(_ element: Element, _ attribute: String) -> Bool
    func setSelected(_ element: Element) -> AXError
    func setSelection(_ elements: [Element], of container: Element, attribute: String) -> AXError
}

/// LiveSelectionWriter is `SelectionWriting` on the live tree. An attribute whose settability cannot be read is taken
/// as not settable, so nothing is written to it.
struct LiveSelectionWriter: SelectionWriting {

    func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let read = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return read == .success && settable.boolValue
    }

    func setSelected(_ element: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    }

    func setSelection(_ elements: [AXUIElement], of container: AXUIElement, attribute: String) -> AXError {
        AXUIElementSetAttributeValue(container, attribute as CFString, elements as CFArray)
    }
}
