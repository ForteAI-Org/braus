import ApplicationServices
import CoreGraphics
import Foundation

/// LiveMacTreeReader fills `MacTreeReading` with the accessibility API: one batched request per
/// element (`AXUIElementCopyMultipleAttributeValues`) instead of one per attribute, visible rows
/// only, breadth first so a cut tree still holds every section's top.
///
/// Rules of the walk:
/// - tables and outlines contribute their header and their `AXVisibleRows`, lists and others their
///   `AXVisibleChildren` when they report some, not every row the model holds;
/// - an element whose frame lies wholly outside the window, or outside the scroll area that holds it,
///   is not recorded and not followed;
/// - action names are asked only of roles that can carry one (static text and pure containers are
///   skipped), the one extra request per element;
/// - a secure text field's value is dropped as soon as it is read (the system returns bullets, but
///   nothing of it is kept).
///
/// Never activates, raises or focuses anything: it only reads.
public struct LiveMacTreeReader: MacTreeReading {

    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    @concurrent
    public func windows(of processID: pid_t) async throws -> [MacWindowSummary] {
        guard isTrusted else { throw MacTreeFailure.notTrusted }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, MacTreeLimits.standard.applicationTimeout)
        guard let windows = elements(application, kAXWindowsAttribute) else {
            throw MacTreeFailure.applicationUnreachable(processID)
        }
        let focused = element(application, kAXFocusedWindowAttribute)
        return windows.enumerated().map { index, window in
            let values = batch(window, Self.windowAttributes)
            return MacWindowSummary(
                index      : index,
                role       : values.string(kAXRoleAttribute) ?? "AXUnknown",
                subrole    : values.string(kAXSubroleAttribute),
                title      : values.string(kAXTitleAttribute),
                frame      : values.frame,
                isMain     : values.bool(kAXMainAttribute) ?? false,
                isFocused  : focused.map { CFEqual($0, window) } ?? false,
                isMinimized: values.bool(kAXMinimizedAttribute) ?? false,
                document   : values.string(kAXDocumentAttribute)
            )
        }
    }

    @concurrent
    public func read(windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) async throws -> MacTreeRead {
        guard isTrusted else { throw MacTreeFailure.notTrusted }
        // Before the lookup of the application and its windows, so their cost counts against the read's budget.
        let started = ContinuousClock.now
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, limits.applicationTimeout)
        guard let windows = elements(application, kAXWindowsAttribute) else {
            throw MacTreeFailure.applicationUnreachable(processID)
        }
        guard windows.indices.contains(index) else { throw MacTreeFailure.windowNotFound(index: index) }
        var read = try MacTreeWalk.read(window: windows[index], index: index, source: LiveMacElements(reader: self),
                                        limits: limits, started: started)
        // The identity of the very element walked, so acting checks the window this tree came from.
        read.windowIdentity = MacWindowIdentity(window: windows[index])
        return read
    }

    // MARK: Reading one element

    static let nodeAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXSelectedAttribute, kAXExpandedAttribute, kAXFocusedAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXVisibleChildrenAttribute,
        kAXVisibleRowsAttribute,
    ]

    static let windowAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMainAttribute, kAXMinimizedAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXDocumentAttribute,
    ]

    /// The child lists of `nodeAttributes`: whether the walk lost children is said by the list it follows
    /// (`MacChildList`), not by each of them.
    static let listAttributes: Set<String> = [kAXChildrenAttribute, kAXVisibleChildrenAttribute, kAXVisibleRowsAttribute]

    /// Roles that never list an action worth a request: text and containers. Scroll areas are asked:
    /// they list the page scrolls.
    static let passiveRoles: Set<String> = [
        "AXStaticText", "AXGroup", "AXSplitGroup", "AXLayoutArea", "AXUnknown",
        "AXSplitter", "AXWindow", "AXSheet",
    ]

    /// An element's children as the walk follows them, with a table's or an outline's rows replaced by
    /// the visible ones, and any other element's by its visible children when it reports some.
    func visibleChildren(_ element: AXUIElement, values: AttributeValues) -> [MacChild<AXUIElement>] {
        MacChildList.followed(
            visibleOnly    : true,
            children       : values.list(kAXChildrenAttribute),
            visibleChildren: (try? values.list(kAXVisibleChildrenAttribute).get()) ?? [],
            visibleRows    : (try? values.list(kAXVisibleRowsAttribute).get()) ?? [],
            header         : { readElement(element, kAXHeaderAttribute) }
        ).children
    }

    /// One request for `names`. The request's own failure, a malformed answer, and each attribute that
    /// did not answer are kept apart from the values (`MacReadFailure`).
    func batch(_ element: AXUIElement, _ names: [String]) -> AttributeValues {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values
        )
        return AttributeValues(names: names, result: result, answer: values)
    }

    func actionNames(_ element: AXUIElement) -> [String] { (try? readActionNames(element).get()) ?? [] }

    /// The element's action names; none when it genuinely has none, the failure when the request did not
    /// answer.
    func readActionNames(_ element: AXUIElement) -> Result<[String], MacReadFailure> {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        guard result == .success else {
            switch MacReadFailure.ofAttribute(result) {
                case .absent             : return .success([])
                case .unread(let failure): return .failure(failure)
            }
        }
        guard let names else { return .success([]) }
        guard let listed = names as? [String] else { return .failure(.malformed) }
        return .success(listed)
    }

    func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &reference) == .success else { return nil }
        return reference as? [AXUIElement]
    }

    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        (try? readElement(element, name).get()) ?? nil
    }

    /// One attribute naming an element: nil when it is absent, the failure when it did not answer.
    func readElement(_ element: AXUIElement, _ name: String) -> Result<AXUIElement?, MacReadFailure> {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &reference)
        guard result == .success else {
            switch MacReadFailure.ofAttribute(result) {
                case .absent             : return .success(nil)
                case .unread(let failure): return .failure(failure)
            }
        }
        guard let reference else { return .success(nil) }
        guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return .failure(.malformed) }
        return .success(unsafeDowncast(reference, to: AXUIElement.self))
    }
}

/// LiveMacElements is the walk's source over the accessibility API: one batched request per element, with
/// the messaging timeout set on the element first.
struct LiveMacElements: MacElementSource {

    let reader: LiveMacTreeReader

    func read(_ element: AXUIElement, timeout: Float) -> Result<MacElementRead<AXUIElement>, MacReadFailure> {
        AXUIElementSetMessagingTimeout(element, timeout)
        let values = reader.batch(element, LiveMacTreeReader.nodeAttributes)
        if let failure = values.failure { return .failure(failure) }
        let node = MacTreeNode(
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
            frame          : values.frame
        )
        return .success(MacElementRead(
            node           : node,
            children       : values.list(kAXChildrenAttribute),
            visibleChildren: (try? values.list(kAXVisibleChildrenAttribute).get()) ?? [],
            visibleRows    : (try? values.list(kAXVisibleRowsAttribute).get()) ?? [],
            unread         : values.unread.filter { !LiveMacTreeReader.listAttributes.contains($0.key) }
        ))
    }

    func actions(_ element: AXUIElement) -> Result<[String], MacReadFailure> { reader.readActionNames(element) }

    func header(_ element: AXUIElement) -> Result<AXUIElement?, MacReadFailure> {
        reader.readElement(element, kAXHeaderAttribute)
    }
}

extension MacReadFailure {

    /// MacAttributeAnswer is what a failed answer to one attribute says: the attribute is genuinely absent,
    /// or it was not read.
    enum MacAttributeAnswer: Equatable {
        case absent
        case unread(MacReadFailure)
    }

    /// Why a whole request did not succeed. Every failure of a request is a read that did not succeed: a
    /// request that answered nothing says nothing of the element, even `noValue` or `notImplemented`.
    static func ofRequest(_ result: AXError) -> MacReadFailure {
        switch result {
            case .cannotComplete: .timedOut
            case .success       : .malformed
            default             : .failed(code: result.rawValue)
        }
    }

    /// What a failed answer to one attribute, or to the action names, says: absent only for `noValue` and
    /// `attributeUnsupported`. `notImplemented` and `invalidUIElement` prove no absence, so they are reads
    /// that did not succeed, as is any other code.
    static func ofAttribute(_ result: AXError) -> MacAttributeAnswer {
        switch result {
            case .noValue, .attributeUnsupported: .absent
            default                             : .unread(ofRequest(result))
        }
    }
}

/// The answers of one batched request, by attribute name, with what did not answer kept apart.
struct AttributeValues {

    let values: [String: AnyObject]
    /// The attributes that did not answer, and why; a genuinely absent attribute is in neither map.
    let unread: [String: MacReadFailure]
    /// Why the request itself did not succeed; nil when it answered.
    let failure: MacReadFailure?

    init(values: [String: AnyObject], unread: [String: MacReadFailure] = [:], failure: MacReadFailure? = nil) {
        self.values  = values
        self.unread  = unread
        self.failure = failure
    }

    /// The answer of `AXUIElementCopyMultipleAttributeValues` for `names`, classified: the request's failure,
    /// an answer of another shape (`malformed`), or each value apart from each attribute's error, an
    /// `AXValue` of type `axError` holding its code.
    init(names: [String], result: AXError, answer: CFArray?) {
        guard result == .success else {
            self.init(values: [:], failure: MacReadFailure.ofRequest(result))
            return
        }
        guard let array = answer as? [AnyObject], array.count == names.count else {
            self.init(values: [:], failure: .malformed)
            return
        }
        var byName: [String: AnyObject] = [:]
        var unread: [String: MacReadFailure] = [:]
        for (name, value) in zip(names, array) {
            guard let code = Self.errorCode(value) else {
                byName[name] = value
                continue
            }
            if case .unread(let failure) = MacReadFailure.ofAttribute(code) { unread[name] = failure }
        }
        self.init(values: byName, unread: unread)
    }

    func string(_ name: String) -> String? {
        guard let text = values[name] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A value as text: strings as they are, numbers (a checkbox's 0 or 1, a slider) as digits.
    func text(_ name: String) -> String? {
        switch values[name] {
            case let text as String  : text
            case let number as NSNumber: number.stringValue
            default                  : nil
        }
    }

    func bool(_ name: String) -> Bool? { (values[name] as? NSNumber)?.boolValue }

    func elements(_ name: String) -> [AXUIElement] { (try? list(name).get()) ?? [] }

    /// A list of elements: empty when the attribute is absent, the failure when it did not answer or
    /// answered something else than a list of elements.
    func list(_ name: String) -> Result<[AXUIElement], MacReadFailure> {
        if let failure = unread[name] { return .failure(failure) }
        guard let value = values[name] else { return .success([]) }
        // A cast to a CF type checks nothing: each element's type id is.
        guard let items = value as? [AnyObject], items.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            return .failure(.malformed)
        }
        return .success(items.map { unsafeDowncast($0, to: AXUIElement.self) })
    }

    var frame: CGRect? {
        guard let position = axValue(kAXPositionAttribute), let size = axValue(kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private func axValue(_ name: String) -> AXValue? {
        guard let value = values[name], CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    /// The code of an attribute's error in a batched answer, nil for a value.
    private static func errorCode(_ value: AnyObject) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else { return nil }
        var code = AXError.success
        return AXValueGetValue(axValue, .axError, &code) ? code : .failure
    }
}
