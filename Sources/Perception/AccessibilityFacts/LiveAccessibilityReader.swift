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
/// once; anything else is a genuine absence and reads as nil. The per-app
/// messaging timeout bounds a pathological tree so one slow app cannot hang the caller.
public struct LiveAccessibilityReader: AccessibilityTreeReading {

    public typealias Node = AXUIElement

    private let applicationBundleID  : String?
    private let elementTimeoutSeconds: Float?
    private let valueGuard: (@Sendable (String) -> Bool)?
    private let copyAttributeValue: @Sendable (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError

    /// Creates a reader. An absent bundle ID uses only standard accessibility state attributes.
    /// `elementTimeoutSeconds`, when given, is set on every window and child the reader lists, so a walk
    /// bounds each message to the application and not only those sent through the application element.
    /// `valueGuard` opts into secure-field checks and rejects labels for which it returns true.
    /// When nil, values use only AXValue, without role, subrole or label reads.
    public init(
        applicationBundleID: String? = nil,
        elementTimeoutSeconds: Float? = nil,
        valueGuard: (@Sendable (String) -> Bool)? = nil,
        batchesAttributes: Bool = false
    ) {
        self.init(
            applicationBundleID: applicationBundleID,
            elementTimeoutSeconds: elementTimeoutSeconds,
            valueGuard: valueGuard,
            copyAttributeValue: AXUIElementCopyAttributeValue,
            copyAttributeValues: batchesAttributes ? Self.copyAttributeValues : nil
        )
    }

    /// `copyAttributeValues`, when given, answers a node's `batched` attributes in one message the first
    /// time any of them is asked for, and the reader keeps those answers for its lifetime: one walk.
    init(
        applicationBundleID: String? = nil,
        elementTimeoutSeconds: Float? = nil,
        valueGuard: (@Sendable (String) -> Bool)? = nil,
        copyAttributeValue: @escaping @Sendable (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError,
        copyAttributeValues: (@Sendable (AXUIElement, [String]) -> [String: Answer]?)? = nil
    ) {
        self.copyAttributeValue = copyAttributeValue
        self.valueGuard = valueGuard
        self.applicationBundleID   = applicationBundleID
        self.elementTimeoutSeconds = elementTimeoutSeconds
        self.copyAttributeValues   = copyAttributeValues
    }

    /// One attribute's answer: the error the application gave, and the value on success.
    typealias Answer = (error: AXError, value: CFTypeRef?)

    /// The attributes a walk reads of nearly every node, cheap for the application to answer: asked
    /// together, one message instead of eight (a 5,500-node Safari window: 310 ms instead of 860).
    static let batched = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                          kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute]

    private let copyAttributeValues: (@Sendable (AXUIElement, [String]) -> [String: Answer]?)?
    private let answers = Answers()

    /// The answers read in one message, by node, for the walk that owns this reader.
    // ponytail: unlocked, since a walk reads on one serial queue (`AccessibilityAugmenter.walkQueue`);
    // a lock if a batching reader is ever shared between threads.
    private final class Answers: @unchecked Sendable {
        var byNode: [AXUIElement: [String: Answer]] = [:]
    }

    /// Every attribute of `names` in one message, each with its own error; nil when the message itself
    /// failed, and the attributes are then read one by one as before.
    static let copyAttributeValues: @Sendable (AXUIElement, [String]) -> [String: Answer]? = { node, names in
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let list = values as [AnyObject]?, list.count == names.count else { return nil }
        var answers: [String: Answer] = [:]
        for (name, item) in zip(names, list) {
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(unsafeDowncast(item, to: AXValue.self)) == .axError {
                var error = AXError.success
                AXValueGetValue(unsafeDowncast(item, to: AXValue.self), .axError, &error)
                answers[name] = (error, nil)
            } else if CFGetTypeID(item) == CFNullGetTypeID() {
                answers[name] = (.noValue, nil)
            } else {
                answers[name] = (.success, item)
            }
        }
        return answers
    }

    public nonisolated func isSameNode(_ first: AXUIElement, _ second: AXUIElement) -> Bool {
        CFEqual(first, second)
    }

    public nonisolated func role(_ node: AXUIElement) -> String? { string(node, kAXRoleAttribute) }
    public nonisolated func subrole(_ node: AXUIElement) -> String? {
        valueGuard == nil ? string(node, kAXSubroleAttribute) : valueClassification(node, kAXSubroleAttribute)
    }

    public nonisolated var requiresValueClassification: Bool { valueGuard != nil }
    public nonisolated func title(_ node: AXUIElement) -> String? { string(node, kAXTitleAttribute) }
    public nonisolated func descriptionText(_ node: AXUIElement) -> String? { string(node, kAXDescriptionAttribute) }
    public nonisolated func identifier(_ node: AXUIElement) -> String? { string(node, kAXIdentifierAttribute) }
    public nonisolated func value(_ node: AXUIElement) -> String? {
        guard let valueGuard else { return string(node, kAXValueAttribute) }
        return AccessibilityValueReading.read(
            isReservedLabel: valueGuard,
            attribute: { valueClassification(node, $0) },
            value: { string(node, kAXValueAttribute) }
        )
    }

    public nonisolated func value(_ node: AXUIElement, role: String?, subrole: String?) -> String? {
        guard let valueGuard else { return string(node, kAXValueAttribute) }
        return AccessibilityValueReading.read(
            isReservedLabel: valueGuard,
            attribute: { name in
                switch name {
                    case kAXRoleAttribute: role
                    case kAXSubroleAttribute: subrole
                    default: string(node, name)
                }
            },
            value: { string(node, kAXValueAttribute) }
        )
    }

    public nonisolated func numericValue(_ node: AXUIElement, role: String?, subrole: String?) -> Int? {
        guard let valueGuard else { return (attribute(node, kAXValueAttribute) as? NSNumber)?.intValue }
        return AccessibilityValueReading.read(
            isReservedLabel: valueGuard,
            attribute: { name in
                switch name {
                    case kAXRoleAttribute: role
                    case kAXSubroleAttribute: subrole
                    default: string(node, name)
                }
            },
            value: { (attribute(node, kAXValueAttribute) as? NSNumber)?.intValue }
        )
    }

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

    public nonisolated func numericValue(_ node: AXUIElement) -> Int? {
        guard let valueGuard else { return (attribute(node, kAXValueAttribute) as? NSNumber)?.intValue }
        return AccessibilityValueReading.read(
            isReservedLabel: valueGuard,
            attribute: { valueClassification(node, $0) },
            value: { (attribute(node, kAXValueAttribute) as? NSNumber)?.intValue }
        )
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
            answer = ChildrenAnswer(copyAttributeValue(node, kAXChildrenAttribute as CFString, &reference),
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

    /// Unsupported subroles attest an ordinary field; a messaging failure does not. Preserve that
    /// distinction for value admission without changing the general attribute reader's nil contract.
    private nonisolated func valueClassification(_ node: AXUIElement, _ name: String) -> String? {
        guard name == "AXSubrole" else { return string(node, name) }
        var reference: CFTypeRef?
        switch copy(node, kAXSubroleAttribute, &reference) {
            case .success: return reference as? String
            case .attributeUnsupported, .noValue: return ""
            default: return nil
        }
    }

    private nonisolated func string(_ node: AXUIElement, _ name: String) -> String? { attribute(node, name) as? String }

    /// One attribute: from the node's batched answers when it is one of them, else asked alone. A batched
    /// answer that timed out is asked again alone, as a single message that timed out is retried.
    private nonisolated func copy(
        _ node     : AXUIElement,
        _ name     : String,
        _ reference: UnsafeMutablePointer<CFTypeRef?>
    ) -> AXError {
        if let copyAttributeValues, Self.batched.contains(name) {
            let batch = answers.byNode[node] ?? (copyAttributeValues(node, Self.batched) ?? [:])
            answers.byNode[node] = batch
            if let answer = batch[name], answer.error != .cannotComplete {
                reference.pointee = answer.value
                return answer.error
            }
        }
        return copyAttributeValue(node, name as CFString, reference)
    }

    private nonisolated func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        for _ in 0..<2 {
            var reference: CFTypeRef?
            switch copy(node, name, &reference) {
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
