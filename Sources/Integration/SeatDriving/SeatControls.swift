//
//  SeatControls.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AccessibilityActions
import AccessibilityFacts
import ApplicationServices
import AppKit
import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// SeatControls is `ControlPressing` for an adopted window: presses and value reads go through the
/// accessibility tree by label and value, which do not depend on where the window is. A
/// Pro Tools click is delegated to the Seat's window-scoped path because track labels repeat. The
/// geometric read, a toggle's state under a point, is refused, because after the window server moved
/// the window the application's child frames still name its old place.
public struct SeatControls: ControlPressing {

    private let accessibility: AccessibilityController

    private let copyAttributeValue: @Sendable (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError

    public init() {
        accessibility = AccessibilityController()
        copyAttributeValue = AXUIElementCopyAttributeValue
    }

    package init(
        budget: AccessibilityController.WalkBudget = .standard,
        copyAttributeValue: @escaping @Sendable (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError
    ) {
        self.accessibility = AccessibilityController(budget: budget)
        self.copyAttributeValue = copyAttributeValue
    }

    /// Reads focus classification without requesting the field's value or labels.
    public func focusedField(in processID: pid_t) async -> FocusedField {
        await Self.readFocusedField(in: processID, budget: accessibility.budget, copy: copyAttributeValue)
    }

    @concurrent
    private static func readFocusedField(
        in processID: pid_t,
        budget: AccessibilityController.WalkBudget,
        copy: @Sendable (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError
    ) async -> FocusedField {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget.deadline)
        func canRead() -> Bool { !Task.isCancelled && clock.now < deadline }
        guard processID > 0, budget.elements > 0, canRead() else { return .unknown }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, budget.applicationTimeout)
        var focused: CFTypeRef?
        guard copy(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), canRead() else { return .unknown }
        // The CF type was checked above; AX handles stay on this executor throughout the read.
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, budget.elementTimeout)
        func attribute(_ name: String) -> (AXError, CFTypeRef?) {
            guard canRead() else { return (.cannotComplete, nil) }
            var value: CFTypeRef?
            let error = copy(field, name as CFString, &value)
            return (error, value)
        }
        let (roleError, roleValue) = attribute(kAXRoleAttribute)
        let (subroleError, subroleValue) = attribute(kAXSubroleAttribute)
        let role = roleError == .success ? roleValue as? String : nil
        let subrole = subroleError == .success ? subroleValue as? String : nil
        guard canRead() else { return .unknown }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .secure(TargetIdentity(NativeAccessibilityIdentity.token(for: field)))
        }
        guard let role,
              subrole != nil || subroleError == .attributeUnsupported || subroleError == .noValue
        else { return .unknown }
        let ordinaryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        if !ordinaryRoles.contains(role) {
            let (error, editable) = attribute("AXEditable")
            guard error == .success, let editable, CFGetTypeID(editable) == CFBooleanGetTypeID(),
                  CFEqual(editable, kCFBooleanTrue), canRead() else { return .unknown }
        }
        return .ordinary(TargetIdentity(NativeAccessibilityIdentity.token(for: field)))
    }

    /// Only a unique scene ID can bind a native field. Pixel-only elements attest no identity.
    package static func identities(in scene: SceneSnapshot) -> [String: TargetIdentity] {
        let grouped = Dictionary(grouping: scene.elements, by: \.id)
        return grouped.compactMapValues { elements in
            guard elements.count == 1, let element = elements.first,
                  let token = element.nativeIdentity else { return nil }
            return TargetIdentity(token)
        }
    }

    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        // Pro Tools repeats labels across tracks. Its seat resolves the observed window and point.
        let usesSeat = await MainActor.run {
            NSRunningApplication(processIdentifier: processID)?.bundleIdentifier == "com.avid.ProTools"
        }
        guard !usesSeat else { return false }
        return await accessibility.pressControl(labelled: label, in: processID)
    }

    public func menuItemNavigation(
        titled title: String,
        within menuFrame: CGRect,
        in processID: pid_t
    ) async -> MenuItemNavigation? {
        await accessibility.menuItemNavigation(titled: title, within: menuFrame, in: processID)
    }

    /// A menu is a window opened where it stands, so its items' frames are read against its own.
    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        await accessibility.pressMenuItem(titled: title, within: menuFrame, in: processID)
    }

    public func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
        await accessibility.controlValue(matchingAny: labels, in: processID)
    }

    public func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? {
        nil
    }

    /// A label names no place, so the application's own answer holds wherever the window is.
    public func toggleState(labelled label: String, in processID: pid_t) async -> ControlState? {
        await accessibility.toggleState(labelled: label, in: processID)
    }

    /// Focus is the application's own answer and names no place, so it holds wherever the window is.
    public func focusedFieldValue(in processID: pid_t) async -> String? {
        await accessibility.focusedFieldValue(in: processID)
    }
}
