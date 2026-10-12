//
//  AgentSeat+WindowClosure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import AppKit
import ApplicationServices
import SeatCore
import WindowPlacement

extension AgentSeat {

    /// What closing the window the seat targets would do to its application, read now, or nil when
    /// the seat holds no target. See `WindowClosureFacts` for the rule.
    ///
    /// It reads, and writes nothing: the window list, the window server's visible windows, the
    /// application's main window and the target's cancel and close buttons, each with a short
    /// accessibility timeout. A read that fails leaves its fact unknown, which the rule counts as
    /// the dangerous answer.
    public var windowClosureFacts: WindowClosureFacts? {
        guard let target = session.currentTarget?.window.reference else { return nil }
        // A document never qualifies, and the role is held in memory: no accessibility read for it.
        let role = surfaceRole(ofWindow: target.windowNumber)
        if role == .document {
            return WindowClosureFacts(
                role                    : role,
                accessibilityWindowCount: nil,
                onScreenWindowCount     : nil,
                hasMainWindow           : nil,
                hasCancelButton         : nil,
                isRegularApplication    : nil
            )
        }
        let processID = target.processID
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, Self.closureReadTimeout)

        let windows = Self.elements(of: application, kAXWindowsAttribute)
        let numbers = windows?.map { WindowRelocator.windowNumber(of: $0) }
        let targetElement = zip(windows ?? [], numbers ?? []).first { $0.1 == target.windowNumber }?.0
        // A target that is not in `AXWindows` (a sheet) is one more window than the list holds.
        var listedCount: Int?
        if let windows, let numbers {
            if targetElement != nil {
                listedCount = windows.count
            } else if !numbers.contains(where: { $0 == nil }) {
                listedCount = windows.count + 1
            }
        }
        if let targetElement { AXUIElementSetMessagingTimeout(targetElement, Self.closureReadTimeout) }

        let cancel = targetElement.map { Self.button($0, kAXCancelButtonAttribute) }
        let close  = targetElement.map { Self.button($0, kAXCloseButtonAttribute) }
        return WindowClosureFacts(
            role                    : role,
            accessibilityWindowCount: listedCount,
            onScreenWindowCount     : WindowClosureFacts.countedWindows(
                in: sensing.windowSurfaces(ownedBy: [processID])
            ),
            hasMainWindow           : Self.presence(of: application, kAXMainWindowAttribute),
            hasCancelButton         : cancel?.exists,
            isRegularApplication    : NSRunningApplication(processIdentifier: processID)
                .map { $0.activationPolicy == .regular },
            controlFrames           : [cancel?.frame, close?.frame].compactMap { $0 }
        )
    }

    private static let closureReadTimeout: Float = 0.35

    private static func elements(of element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? [AXUIElement]
    }

    /// Whether `element` has an element under `name`: true for a value, false for no value or an
    /// attribute the element lacks, nil for any other error (a timeout, a vanished element).
    private static func presence(of element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .success                         : return true
            case .noValue, .attributeUnsupported  : return false
            default                               : return nil
        }
    }

    /// One of a window's buttons: whether it exists (nil when unreadable) and where it is.
    private static func button(
        _ window: AXUIElement,
        _ name  : String
    ) -> (exists: Bool?, frame: CGRect?) {

        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(window, name as CFString, &value) {
            case .success:
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (true, nil) }
                let button = unsafeDowncast(value, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(button, closureReadTimeout)
                return (true, frame(of: button))
            case .noValue, .attributeUnsupported: return (false, nil)
            default                             : return (nil, nil)
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size    : CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
