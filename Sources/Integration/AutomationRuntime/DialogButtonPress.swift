//
//  DialogButtonPress.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AppKit
import ApplicationServices
import EngineCore
import PerceptionCore
import WindowPlacement

/// DialogButtonPress presses one button of the application's current dialog or alert by its
/// title, through accessibility. It is the explicit route for a button the seat cannot deliver
/// a click to, and never a fallback a click takes on its own.
///
/// Measured on 30/09/2026 with Photoshop: the "already exists, replace it?" alert over its Save
/// panel was drawn by the panel service at the position Photoshop last reported, which Photoshop
/// had not updated after the seat moved the panel. Every click and key to it was refused with
/// `geometryUnavailable`, and its Cancel and Replace showed as text. Both were `AXButton`s of
/// Photoshop with `AXPress`, and pressing Cancel closed the alert.
///
/// The scope searched is the dialogs the seat holds when it holds any, and the application's
/// focused window only when it holds none: a button of a window behind a dialog is not what the
/// person sees answering. Measured on 30/09/2026 with Photoshop, right after File > Close opened
/// its "Save changes?" alert: the focused window was still the document, so `Save` was looked
/// for among the document's buttons.
@MainActor
public enum DialogButtonPress {

    /// How long a press waits for a dialog to come to the front when the seat holds none. Measured
    /// on 30/09/2026 with Photoshop: right after File > Close the document was still the focused window.
    public static let dialogWait: Duration = .milliseconds(500)

    /// How often the focused window is read again during `dialogWait`.
    static let dialogPoll: Duration = .milliseconds(50)

    /// One open dialog as accessibility reads it, for a sentence that names it.
    public struct OpenDialog: Equatable, Sendable {
        public let title  : String
        public let role   : String
        public let buttons: [String]

        /// A modal `AXDialog`, which the window list offers to `open_session` by its title.
        public let isListed: Bool

        public init(
            title   : String,
            role    : String,
            buttons : [String],
            isListed: Bool
        ) {
            self.title    = title
            self.role     = role
            self.buttons  = buttons
            self.isListed = isListed
        }
    }

    /// One button as the search reads it.
    public struct Button<Element> {
        public let title    : String
        public let isEnabled: Bool
        public let element  : Element

        /// The button is its window's `AXCancelButton` or `AXCloseButton`, whatever its title.
        public let closesItsWindow: Bool

        public init(
            title          : String,
            isEnabled      : Bool,
            element        : Element,
            closesItsWindow: Bool = false
        ) {
            self.title           = title
            self.isEnabled       = isEnabled
            self.element         = element
            self.closesItsWindow = closesItsWindow
        }
    }

    /// What one title names among the buttons read.
    public enum Resolution<Element> {
        case press(Element, title: String)
        case outcome(ActOutcome)
    }

    /// The choice, over any list: exactly one enabled button with the title, compared like menu
    /// titles, and nothing destructive unless the person allowed it. `closingRefusal` is asked only
    /// for a button that closes its window, and refuses it with its sentence when it gives one.
    /// `inDialog` false says the buttons are of a window in front that is no dialog.
    public static func resolve<Element>(
        _ title          : String,
        among buttons    : [Button<Element>],
        allowsDestructive: Bool,
        inDialog         : Bool = true,
        closingRefusal   : ((String) -> String?)? = nil
    ) -> Resolution<Element> {

        let shown   = buttons.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")
        let wanted  = ActionPolicy.normalizedLabel(title)
        let matches = buttons.filter { ActionPolicy.normalizedLabel($0.title) == wanted }
        let place   = inDialog ? "the dialog in front" : "the window in front"
        guard let only = matches.first else {
            let listing = shown.isEmpty ? "It has no buttons accessibility can read." : "Its buttons: \(shown)."
            let missing = inDialog
                ? "No button '\(title)' in the dialog in front. "
                : "No dialog is open, and the window in front has no button '\(title)'. "
            return .outcome(ActOutcome(.honestMiss, missing + listing))
        }
        guard matches.count == 1 else {
            return .outcome(ActOutcome(.ambiguous, "\(matches.count) buttons are titled '\(title)' in \(place)."))
        }
        if only.closesItsWindow || ActionPolicy.isWindowClosingLabel(only.title),
           let sentence = closingRefusal?("Pressing '\(only.title)'") {
            return .outcome(ActOutcome(.refused, sentence))
        }
        // A native dialog's button is pressed through the scene, which cannot read an irreversible effect back.
        if ActionPolicy.isDestructive(label: only.title) {
            switch IrreversiblePolicy.decision(allowed: allowsDestructive, readBack: .cannotConfirm) {
                case .allowed:
                    break
                case .needsConsent:
                    return .outcome(ActOutcome(.refused, "'\(only.title)' reads as destructive, and the person has not "
                        + "allowed it: not authorized in this session."))
                case .cannotReadBack:
                    return .outcome(ActOutcome(.refused, IrreversiblePolicy.readBackRefusal("'\(only.title)'")))
            }
        }
        guard only.isEnabled else {
            return .outcome(ActOutcome(.refused, "'\(only.title)' is disabled right now."))
        }
        return .press(only.element, title: only.title)
    }

    /// The windows one press searches: the dialogs the seat holds, by Window ID, when it holds
    /// any, and the application's focused window only when it holds none. It is a scope and not a
    /// fallback, so a held dialog accessibility cannot find is left out, never replaced.
    public static func scope<Window>(
        dialogs      : [Int],
        window       : (Int) -> Window?,
        focusedWindow: () -> Window?
    ) -> [Window] {
        dialogs.isEmpty ? (focusedWindow().map { [$0] } ?? []) : dialogs.compactMap(window)
    }

    /// Reads `read` until it gives a window `isDialog` accepts, every `dialogPoll` for at most
    /// `dialogWait`, then asks `elsewhere` for a dialog the focus is not on (ADR 0016: the focus can
    /// stay on the blocked document): the dialog found, or the last window read and no dialog.
    package static func awaitingDialog<Window>(
        read     : () -> Window?,
        isDialog : (Window) -> Bool,
        elsewhere: () -> Window?,
        sleep    : (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> (window: Window?, isDialog: Bool) {
        var window = read()
        for _ in 0..<Int(dialogWait / dialogPoll) {
            if let window, isDialog(window) { return (window, true) }
            try await sleep(dialogPoll)
            window = read()
        }
        if let window, isDialog(window) { return (window, true) }
        if let dialog = elsewhere() { return (dialog, true) }
        return (window, false)
    }

    /// The dialog `processID` has open, the focused one first, or nil when it has none.
    public static func openDialog(of processID: pid_t) -> OpenDialog? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let dialog = dialogWindow(of: application) else { return nil }
        // The window server's name first: it is the title open_session matches.
        let served = WindowRelocator.windowNumber(of: dialog).flatMap { number in
            CGWindowID(exactly: number).flatMap {
                (CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]])?
                    .first?[kCGWindowName as String] as? String
            }
        } ?? ""
        var modal: CFTypeRef?
        AXUIElementCopyAttributeValue(dialog, kAXModalAttribute as CFString, &modal)
        return OpenDialog(
            title   : served.isEmpty ? string(dialog, kAXTitleAttribute) ?? "" : served,
            role    : string(dialog, kAXRoleAttribute) == (kAXSheetRole as String) ? "sheet" : "dialog",
            buttons : buttons(in: dialog).map(\.title).filter { !$0.isEmpty },
            isListed: string(dialog, kAXSubroleAttribute) == (kAXDialogSubrole as String) && (modal as? Bool) == true
        )
    }

    /// Presses `title` in the scope `dialogs` names in `processID`, the Window IDs of the dialogs
    /// the seat holds, and observes the scene after it, verified like a menu item: by the
    /// application's windows.
    public static func perform(
        _ title          : String,
        processID        : pid_t,
        dialogs          : [Int],
        allowsDestructive: Bool,
        closingRefusal   : ((String) -> String?)? = nil,
        observe          : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome {

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 1)
        let listed  = dialogs.isEmpty ? [] : windowsAndSheets(of: application)
        // An alert a command just opened may not be the focused window yet.
        let focused = dialogs.isEmpty
            ? try await awaitingDialog(
                read     : { element(application, kAXFocusedWindowAttribute) },
                isDialog : isDialog,
                elsewhere: { dialogWindow(of: application) }
            )
            : (window: nil, isDialog: true)
        let windows = scope(
            dialogs      : dialogs,
            window       : { number in listed.first { WindowRelocator.windowNumber(of: $0) == number } },
            focusedWindow: { focused.window }
        )
        guard !windows.isEmpty else {
            return ActOutcome(.honestMiss, dialogs.isEmpty
                ? "No dialog is open: the application has no window in front that accessibility can read."
                : "The dialog open in the seat is not one accessibility can read.")
        }

        let resolution = resolve(
            title,
            among            : windows.flatMap(buttons(in:)),
            allowsDestructive: allowsDestructive,
            inDialog         : focused.isDialog,
            closingRefusal   : closingRefusal
        )
        switch resolution {
            case .outcome(let outcome):
                return outcome
            case .press(let button, let title):
                let before = MenuBarCommand.windowSignature(of: processID)
                let error  = AXUIElementPerformAction(button, kAXPressAction as CFString)
                // A button that opens a modal can keep the reply past the timeout: it was pressed.
                guard error == .success || error == .cannotComplete else {
                    return ActOutcome(
                        .actedUnverified,
                        "Pressing '\(title)' failed with AXError \(error.rawValue).",
                        check: MenuBarCommand.windowCheck(.unknown, limits: [.deliveryUncertain], performed: .uncertain)
                    )
                }
                try? await Task.sleep(for: .milliseconds(400))
                return try await observed(title, observe: observe) { MenuBarCommand.windowSignature(of: processID) != before }
        }
    }

    /// What a press that was dispatched says once the window after it is perceived: whether the
    /// application's windows changed, with the scene. A perception that fails leaves the press made and
    /// its effect unknown (`no_after_scene`), with no scene and no error text: nothing says it worked,
    /// failed or changed nothing, and it is not pressed again. A cancellation, or any error once the task
    /// was cancelled, is no failed perception: it is thrown, the gesture made, and the call ends cancelled.
    package static func observed(
        _ title       : String,
        observe       : () async throws -> SceneSnapshot,
        windowsChanged: () -> Bool
    ) async throws -> ActOutcome {
        let scene: SceneSnapshot
        do {
            scene = try await observe()
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            return ActOutcome(.actedUnverified, "pressed '\(title)', but the window could not be perceived after it, so whether "
                + "it took effect is unknown. Do not press it again; observe the session before further input.",
                check: MenuBarCommand.windowCheck(.unknown, limits: [.noAfterScene]))
        }
        let changed = windowsChanged()
        let check   = MenuBarCommand.windowCheck(changed ? .passed : .unknown)
        return changed
            ? ActOutcome(.foundActed, "pressed '\(title)': a window of the application opened, closed or "
                + "was retitled", scene: scene, check: check)
            : ActOutcome(.actedUnverified, "pressed '\(title)'" + MenuBarCommand.unchangedWindows + "; "
                + "the scene shows whether it took effect. Do not press it again blind.",
                scene: scene, check: check)
    }

    /// The application's dialog, the focused window first and then its windows and their sheets.
    private static func dialogWindow(of application: AXUIElement) -> AXUIElement? {
        let focused = element(application, kAXFocusedWindowAttribute).map { [$0] } ?? []
        return (focused + windowsAndSheets(of: application)).first(where: isDialog)
    }

    /// A sheet, a window whose subrole says dialog, or a modal one, as Photoshop's New Document
    /// (`AXLayoutArea`, `AXDialog`, modal) reads.
    private static func isDialog(_ window: AXUIElement) -> Bool {
        var modal: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modal)
        let subrole = string(window, kAXSubroleAttribute)
        return string(window, kAXRoleAttribute) == (kAXSheetRole as String)
            || subrole == (kAXDialogSubrole as String) || subrole == (kAXSystemDialogSubrole as String)
            || (modal as? Bool) == true
    }

    /// Every `AXButton` under `window`, bounded: a dialog holds a handful, and a window that
    /// holds thousands of elements is not the dialog this is for.
    private static func buttons(in window: AXUIElement) -> [Button<AXUIElement>] {
        let closing = [kAXCancelButtonAttribute, kAXCloseButtonAttribute].compactMap { element(window, $0) }
        var found: [Button<AXUIElement>] = []
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (node, depth) = pending.popLast(), visited < 2_000 {
            visited += 1
            if string(node, kAXRoleAttribute) == (kAXButtonRole as String) {
                var enabled: CFTypeRef?
                AXUIElementCopyAttributeValue(node, kAXEnabledAttribute as CFString, &enabled)
                found.append(Button(
                    title          : string(node, kAXTitleAttribute) ?? "",
                    isEnabled      : (enabled as? Bool) ?? true,
                    element        : node,
                    closesItsWindow: closing.contains { CFEqual($0, node) }
                ))
            }
            guard depth < 10 else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                  let elements = children as? [AXUIElement]
            else { continue }
            pending.append(contentsOf: elements.map { ($0, depth + 1) })
        }
        return found
    }

    /// The application's `AXWindows` entries and the sheets attached to them, which accessibility
    /// lists as children of their window and not as windows of their own.
    private static func windowsAndSheets(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows + windows.flatMap { window in
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
                  let elements = children as? [AXUIElement]
            else { return [AXUIElement]() }
            return elements.filter { string($0, kAXRoleAttribute) == (kAXSheetRole as String) }
        }
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
