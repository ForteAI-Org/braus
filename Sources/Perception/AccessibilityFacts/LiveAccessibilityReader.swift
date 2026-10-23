//
//  LiveAccessibilityReader.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import PerceptionCore

/// LiveAccessibilityReader fills `AccessibilityTreeReading` over the system's `AXUIElement` handles.
///
/// Retains only the application bundle ID used to interpret native button values. Not tied to an
/// actor: the caller picks the thread, and the C API blocks it until the application answers, so a
/// caller that must stay responsive reads off the main actor. The handles are not Sendable: keep each
/// in the task that read it. A `.cannotComplete` answer (a messaging timeout) is transient and retried
/// once. Optional accessors answer nil for other unavailable results; nativeControlFacts retains
/// each result's status and type instead. The per-app
/// messaging timeout bounds a pathological tree so one slow app cannot hang the caller.
public struct LiveAccessibilityReader: AccessibilityTreeReading {

    public typealias Node = AXUIElement

    private let applicationBundleID  : String?
    private let elementTimeoutSeconds: Float?

    /// Creates a reader. An absent bundle ID uses only standard accessibility state attributes.
    /// `elementTimeoutSeconds`, when given, is set on every window and child the reader lists, so a walk
    /// bounds each message to the application and not only those sent through the application element.
    public init(applicationBundleID: String? = nil, elementTimeoutSeconds: Float? = nil) {
        self.applicationBundleID   = applicationBundleID
        self.elementTimeoutSeconds = elementTimeoutSeconds
    }

    public nonisolated func isSameNode(_ first: AXUIElement, _ second: AXUIElement) -> Bool {
        CFEqual(first, second)
    }

    public nonisolated func role(_ node: AXUIElement) -> String? { string(node, kAXRoleAttribute) }
    public nonisolated func subrole(_ node: AXUIElement) -> String? { string(node, kAXSubroleAttribute) }
    public nonisolated func title(_ node: AXUIElement) -> String? { string(node, kAXTitleAttribute) }
    public nonisolated func descriptionText(_ node: AXUIElement) -> String? { string(node, kAXDescriptionAttribute) }
    public nonisolated func identifier(_ node: AXUIElement) -> String? { string(node, kAXIdentifierAttribute) }
    public nonisolated func value(_ node: AXUIElement) -> String? { string(node, kAXValueAttribute) }

    public nonisolated func selectedRange(_ node: AXUIElement) -> NSRange? {
        guard let value = axValue(attribute(node, kAXSelectedTextRangeAttribute)),
              AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    public nonisolated func isFocused(_ node: AXUIElement) -> Bool? {
        attribute(node, kAXFocusedAttribute) as? Bool
    }

    public nonisolated func isSelected(_ node: AXUIElement) -> Bool? {
        attribute(node, kAXSelectedAttribute) as? Bool
    }

    public nonisolated func buttonState(_ node: AXUIElement, value: String?) -> ControlState? {
        NativeButtonState.read(
            bundleID  : applicationBundleID,
            identifier: applicationBundleID == "com.avid.ProTools" ? identifier(node) : nil,
            value     : value,
            isSelected: isSelected(node)
        )
    }

    public nonisolated func nativeControlFacts(
        _ node: AXUIElement, isPastDeadline: @Sendable () -> Bool
    ) -> NativeControlFacts? {
        var owner: pid_t = 0
        let ownerProcessID = !isPastDeadline() && AXUIElementGetPid(node, &owner) == .success ? owner : nil
        return NativeControlFacts(
            role: nativeAttribute(node, kAXRoleAttribute, isPastDeadline: isPastDeadline),
            subrole: nativeAttribute(node, kAXSubroleAttribute, isPastDeadline: isPastDeadline),
            value: nativeAttribute(node, kAXValueAttribute, isPastDeadline: isPastDeadline),
            selected: nativeAttribute(node, kAXSelectedAttribute, isPastDeadline: isPastDeadline),
            ownerProcessID: ownerProcessID
        )
    }

    private nonisolated func nativeAttribute(
        _ node: AXUIElement, _ name: String, isPastDeadline: @Sendable () -> Bool
    ) -> NativeAttributeReading {
        for attempt in 0..<2 {
            guard !isPastDeadline() else { return attempt == 0 ? .notRead : .timedOut }
            var reference: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(node, name as CFString, &reference)
            if result == .cannotComplete, attempt == 0 { continue }
            return Self.nativeReading(result, reference: reference)
        }
        return .timedOut
    }

    /// Preserves the native result and scalar type, including successful empty text.
    nonisolated static func nativeReading(_ result: AXError, reference: CFTypeRef?) -> NativeAttributeReading {
        switch result {
            case .noValue: return .noValue
            case .attributeUnsupported: return .unsupported
            case .cannotComplete: return .timedOut
            case .success: break
            default: return .failed(code: Int(result.rawValue))
        }
        guard let reference else { return .emptyReply }
        let type = CFGetTypeID(reference)
        if type == CFBooleanGetTypeID(), let boolean = reference as? Bool {
            return .value(.boolean(boolean))
        }
        if type == CFNumberGetTypeID(), let number = reference as? NSNumber {
            return .value(.number(representation: number.stringValue))
        }
        if type == CFStringGetTypeID(), let string = reference as? String {
            return .value(.string(string))
        }
        return .value(.other(typeID: UInt64(type)))
    }

    public nonisolated func numericValue(_ node: AXUIElement) -> Int? {
        Self.numericStateValue(attribute(node, kAXValueAttribute))
    }

    /// Decodes only native boolean or numeric state values, without parsing text or truncating fractions.
    /// Role qualification belongs to the caller: a numeric value alone does not make a node a toggle.
    nonisolated static func numericStateValue(_ reference: CFTypeRef?) -> Int? {
        guard let reference else { return nil }
        let typeID = CFGetTypeID(reference)
        guard typeID == CFBooleanGetTypeID() || typeID == CFNumberGetTypeID(),
              let number = reference as? NSNumber, number.doubleValue.isFinite else { return nil }
        for value in 0...2 where number.compare(NSNumber(value: value)) == .orderedSame {
            return value
        }
        return nil
    }

    public nonisolated func isEnabled(_ node: AXUIElement) -> Bool? { attribute(node, kAXEnabledAttribute) as? Bool }

    public nonisolated func actions(_ node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public nonisolated func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = axValue(attribute(node, kAXPositionAttribute)),
              let size = axValue(attribute(node, kAXSizeAttribute)) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    public nonisolated func children(_ node: AXUIElement) -> [AXUIElement] {
        timed((attribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
    }

    /// The children, `[]` for a leaf, nil when they could not be read: a timeout after the one retry, or
    /// any failure that proves no absence (`ChildrenAnswer`).
    public nonisolated func readChildren(_ node: AXUIElement) -> [AXUIElement]? {
        var answer = ChildrenAnswer.retry
        for _ in 0..<2 {
            var reference: CFTypeRef?
            answer = ChildrenAnswer(AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &reference),
                                    reference)
            guard answer == .retry else { break }
        }
        switch answer {
            case .listed(let children): return timed(children)
            case .retry, .unread       : return nil
        }
    }

    /// ChildrenAnswer is what one read of a node's children says. Only `noValue` and `attributeUnsupported`
    /// are a genuine absence, a leaf. A timeout is worth one retry. `notImplemented`, `invalidUIElement`,
    /// any other code, and a value that is no list of elements are reads that did not succeed: the node
    /// may have children nobody listed.
    enum ChildrenAnswer: Equatable {
        case listed([AXUIElement])
        case retry
        case unread

        init(_ result: AXError, _ reference: CFTypeRef?) {
            switch result {
                case .success:
                    // A cast to a CF type checks nothing: each element's type id is.
                    guard let items = reference as? [AnyObject],
                          items.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
                    else { self = .unread; return }
                    self = .listed(items.map { unsafeDowncast($0, to: AXUIElement.self) })
                case .noValue, .attributeUnsupported: self = .listed([])
                case .cannotComplete                : self = .retry
                default                             : self = .unread
            }
        }
    }

    // MARK: Application and windows

    public nonisolated func application(processID: pid_t) -> AXUIElement { AXUIElementCreateApplication(processID) }

    /// The focused window, else the first window the app lists, else nil for an app with no tree.
    public nonisolated func mainWindow(of application: AXUIElement) -> AXUIElement? {
        element(attribute(application, kAXFocusedWindowAttribute))
            ?? windows(of: application).first(where: { role($0) == "AXWindow" })
    }

    /// The app's windows from `kAXWindowsAttribute`, falling back to the app element's children for
    /// the apps that list them only there.
    public nonisolated func windows(of application: AXUIElement) -> [AXUIElement] {
        let listed = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return listed.isEmpty ? children(application) : timed(listed)
    }

    /// Selects the captured window, including a sheet exposed as a child of another window.
    /// Focus is not a geometry fallback: a background capture may name a different surface.
    public nonisolated func window(
        of application: AXUIElement, matching frame: CGRect,
        isCapturedWindow: (AXUIElement) -> Bool = { _ in true }
    ) -> AXUIElement? {
        let listed = windows(of: application)
        var candidates = listed
        for window in listed {
            candidates.append(contentsOf: children(window).filter { role($0) == "AXSheet" })
        }
        return AccessibilityWindowMatching.window(
            among: candidates, capturedFrame: frame, reader: self, isCapturedWindow: isCapturedWindow
        )
    }

    /// Caps each message to this element's process so a hung app bounds the cost of a read.
    public nonisolated func setMessagingTimeout(_ node: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(node, seconds)
    }

    private nonisolated func timed(_ nodes: [AXUIElement]) -> [AXUIElement] {
        if let elementTimeoutSeconds {
            for node in nodes { AXUIElementSetMessagingTimeout(node, elementTimeoutSeconds) }
        }
        return nodes
    }

    // MARK: Attribute reads

    private nonisolated func string(_ node: AXUIElement, _ name: String) -> String? { attribute(node, name) as? String }

    private nonisolated func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        for _ in 0..<2 {
            var reference: CFTypeRef?
            switch AXUIElementCopyAttributeValue(node, name as CFString, &reference) {
                case .success       : return reference
                case .cannotComplete: continue
                default             : return nil
            }
        }
        return nil
    }

    private nonisolated func element(_ reference: CFTypeRef?) -> AXUIElement? {
        guard let reference, CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
        // The type id check above is the precondition; a Swift cast cannot see through a CF type here.
        return unsafeDowncast(reference, to: AXUIElement.self)
    }

    private nonisolated func axValue(_ reference: CFTypeRef?) -> AXValue? {
        guard let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        // Same precondition as `element`: the CF type id was checked one line up.
        return unsafeDowncast(reference, to: AXValue.self)
    }
}
