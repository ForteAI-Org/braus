//
//  ControlPressing.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// ControlPressing acts on and reads a window's controls by name rather than by coordinate, where
/// the application exposes them: opening a dropdown with its own press action, reading a combo
/// box's current value, reading a toggle's state under a point, reading the focused field's text.
///
/// Every answer is about the current moment. A conformer that cannot see the tree answers false or
/// nil; it never guesses. `pressControl` opens a CLOSED list only: pressing an open one closes it,
/// and an option row often shares the control's current text.
public protocol ControlPressing: Sendable {

    /// Presses the combo box or pop-up button whose value or title is `label`. True when a control
    /// was found and accepted the press.
    func pressControl(labelled label: String, in processID: pid_t) async -> Bool

    /// The current value of the one control whose value, normalized, is among `labels`; nil when none
    /// or more than one qualifies.
    func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String?

    /// The state of the stateful control under a global point, when the application reports one.
    func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState?

    /// The state of the one checkbox or radio button whose title or description is `label`; nil
    /// when none or more than one qualifies. It names no place, so it holds wherever the window is.
    func toggleState(labelled label: String, in processID: pid_t) async -> ControlState?

    /// The value of the text field or text area that holds the keyboard focus in the application; nil
    /// when none does or the application does not say. What typed text is verified by.
    func focusedFieldValue(in processID: pid_t) async -> String?

    /// Reads the painted item's submenu and keyboard position. Nil means no native menu could be
    /// read; a readable menu without a unique enabled match answers `hasMatchingItem` false.
    func menuItemNavigation(
        titled title: String,
        within menuFrame: CGRect,
        in processID: pid_t
    ) async -> MenuItemNavigation?

    /// The field that holds the keyboard focus, with the identity its provider attests and whether it is
    /// secure, never its value; `unknown` when the conformer cannot say. What a bound text's last check before
    /// its keys reads.
    func focusedField(in processID: pid_t) async -> FocusedField

    /// Presses the one enabled menu item titled `title` painted inside `menuFrame`, an open native
    /// menu. True when a press was made, even one the application refused, because it may have
    /// acted; false when no such item exists, and only then may the keyboard choose instead.
    func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool

    /// Chooses `item`, an element of the open menu painted inside `menuFrame` as the scene showed it, and says
    /// what that did (`MenuItemPress`). A conformer that knows the menu's items by more than their title (an
    /// option's node and index) chooses by those; the default presses the item by its title.
    func chooseMenuItem(_ item: SceneElement, within menuFrame: CGRect, in processID: pid_t) async -> MenuItemPress
}

/// MenuItemPress is the receipt of choosing an item of an open menu: whether anything went out, and what the
/// conformer could read of the choice afterwards.
public enum MenuItemPress: Sendable, Equatable {
    /// The conformer has no such menu or item: nothing was sent, and another way may be tried.
    case notHandled
    /// The item is there but cannot be chosen safely (replaced, reordered, disabled, ambiguous): nothing was
    /// sent, and no other way may be tried.
    case refused(String)
    /// The choice was applied; `readBack` is what was read of it after settling.
    case sent(MenuChoiceReadBack)
    /// The choice went out but its answer did not come back (a timeout, a disconnection, a cancellation): its
    /// effect is possible, unknown.
    case possiblySent(String)
}

/// MenuChoiceReadBack is what a conformer read of a choice it applied, after the page or the application
/// settled.
public enum MenuChoiceReadBack: Sendable, Equatable {
    /// The control reads the chosen item.
    case confirmed(expected: String, observed: String)
    /// The control reads another item: the choice did not hold.
    case contradicted(expected: String, observed: String?)
    /// The control could not be read in time.
    case unread(expected: String, reason: String)
    /// The conformer reads nothing back: only the menu's closing can be judged.
    case unattested
}

extension ControlPressing {

    /// A conformer that cannot read a toggle by its label answers nothing; the scene decides.
    public func toggleState(labelled label: String, in processID: pid_t) async -> ControlState? {
        nil
    }

    public func menuItemNavigation(
        titled title: String,
        within menuFrame: CGRect,
        in processID: pid_t
    ) async -> MenuItemNavigation? {
        nil
    }

    /// A conformer that does not attest the focus says so: a bound text then stops before its keys.
    public func focusedField(in processID: pid_t) async -> FocusedField {
        .unknown
    }

    /// A conformer that cannot read menu items presses none; the keyboard chooses.
    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        false
    }

    /// A menu item chosen by its title, as before: a press is an applied choice nothing reads back, and no
    /// press leaves the engine its other ways.
    public func chooseMenuItem(_ item: SceneElement, within menuFrame: CGRect, in processID: pid_t) async -> MenuItemPress {
        await pressMenuItem(titled: item.label, within: menuFrame, in: processID) ? .sent(.unattested) : .notHandled
    }
}

/// MenuItemNavigation describes a readable native menu and whether it has one enabled matching item.
/// A missing match forbids a typed fallback. A row counts enabled, named items from the top;
/// nil refuses keyboard navigation when their geometry is ambiguous. The child frame is only
/// an ownership hint until the window census confirms a new popup at that frame.
public struct MenuItemNavigation: Sendable, Equatable {
    public let hasMatchingItem: Bool
    public let hasSubmenu: Bool
    /// The painted native menu contains a unique no-send leaf and output/bus submenus.
    public let isAudioSendMenu: Bool
    public let row: Int?
    public let submenuFrame: CGRect?

    public init(hasSubmenu: Bool, row: Int?, submenuFrame: CGRect?, hasMatchingItem: Bool = true,
                isAudioSendMenu: Bool = false) {
        self.isAudioSendMenu = isAudioSendMenu
        self.hasMatchingItem = hasMatchingItem
        self.hasSubmenu = hasSubmenu
        self.row = row
        self.submenuFrame = submenuFrame
    }
}
