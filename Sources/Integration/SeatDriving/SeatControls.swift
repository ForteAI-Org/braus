//
//  SeatControls.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AccessibilityActions
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

    private let accessibility = AccessibilityController()

    public init() {}

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
