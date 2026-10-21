import CoreGraphics
import EngineCore
import Foundation
import MacDriver
import PerceptionCore

/// MacControls fills `ControlPressing` for the MacDriver, for every app, under the accessibility
/// rules (spec section 3, rule 3):
///
/// - No call on the caller's actor: every read and press runs in a `@concurrent` function, so a slow
///   app never holds Braus's main actor.
/// - No unbounded walk: `pressControl` matches against the scene the engine just read (the engine
///   calls it before every click, so a miss must cost nothing); the reads use one bounded read of the
///   same window (`MacTreeLimits`).
/// - Every call has its messaging timeout, from `MacTreeLimits`.
///
/// Native menus are not in the window's tree; `pressMenuItem` goes to `menus`.
///
/// The person first (rule 6), on these fast paths as on the actuator's: when the person touched the process at or
/// after its latest scene was read, by the same watch and the same comparison as `MacActuator`, no `AXPress` and no
/// menu press goes out, and a menu choice is refused, whichever of its checks finds the touch. The last check is made
/// right before the press; a touch between it and the press is not seen.
public struct MacControls: ControlPressing {

    static let controlRoles: Set<String> = ["AXComboBox", "AXPopUpButton"]
    static let fieldRoles  : Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let toggleRoles : Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle", "AXDisclosureTriangle"]

    public let cache : MacSceneCache
    public let reader: any MacTreeReading
    public let actor : any MacAccessibilityActing
    public let limits: MacTreeLimits
    public let menus : any ControlPressing
    /// The actuator's own watch of the person (rule 6); nil where no person can touch the app.
    public let person: (any MacPersonWatching)?

    public init(
        cache : MacSceneCache,
        reader: any MacTreeReading,
        actor : any MacAccessibilityActing,
        limits: MacTreeLimits = .standard,
        menus : any ControlPressing,
        person: (any MacPersonWatching)? = nil
    ) {
        self.cache  = cache
        self.reader = reader
        self.actor  = actor
        self.limits = limits
        self.menus  = menus
        self.person = person
    }

    /// Presses the one combo box or pop-up button of the last scene whose value or title is the
    /// label. True when it was pressed, or the app timed out (it may have acted: the engine must not
    /// click it again); false when the scene has none, a part of it did not answer (M2), or the press
    /// was refused before acting.
    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        let want = LabelText.normalize(label)
        // A tree with a part that did not answer may hold another match there: none is the only one.
        guard !want.isEmpty, let entry = cache.latest(for: processID), !entry.window.hasUnreadParts else { return false }
        let matches = entry.window.flattened.filter { node in
            Self.controlRoles.contains(node.role)
                && (LabelText.normalize(node.value ?? "") == want || LabelText.normalize(node.title ?? "") == want)
        }
        guard matches.count == 1, let control = matches.first, !personActed(in: processID) else { return false }
        let address = MacElementAddress(
            processID  : processID,
            windowIndex: entry.windowIndex,
            path       : control.path,
            role       : control.role,
            name       : control.title ?? control.descriptionText ?? control.help ?? control.placeholder,
            window     : entry.windowIdentity
        )
        return await Self.press(by: actor, at: address)
    }

    /// The value of the one combo box or pop-up button whose value is among the labels; nil for none, for
    /// several, and over a read with a part that did not answer (M2), where another may lie.
    public func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
        guard !labels.isEmpty, let window = await read(processID), !window.hasUnreadParts else { return nil }
        let values = window.flattened.compactMap { node -> String? in
            guard Self.controlRoles.contains(node.role), let value = node.value,
                  labels.contains(LabelText.normalize(value)) else { return nil }
            return value
        }
        return values.count == 1 ? values[0] : nil
    }

    /// The state of the deepest toggle whose frame holds the point.
    public func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? {
        guard let window = await read(processID) else { return nil }
        let toggle = window.flattened.last { node in
            Self.toggleRoles.contains(node.role) && node.frame?.contains(point) == true
        }
        switch toggle?.value {
            case "0": return .off
            case "1": return .on
            case "2": return .mixed
            default : return nil
        }
    }

    /// The focused field's value; nil for a secure field, whatever the app answers.
    public func focusedFieldValue(in processID: pid_t) async -> String? {
        guard let window = await read(processID),
              let field = window.flattened.first(where: { $0.isFocused == true && Self.fieldRoles.contains($0.role) }),
              !field.isSecure
        else { return nil }
        return field.value
    }

    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        await delegated(title, within: menuFrame, in: processID) ?? false
    }

    /// A native menu's item by its title, as before; refused with nothing pressed when the person acted, whichever
    /// check found it.
    public func chooseMenuItem(_ item: SceneElement, within menuFrame: CGRect, in processID: pid_t) async -> MenuItemPress {
        guard !personActed(in: processID), let pressed = await delegated(item.label, within: menuFrame, in: processID) else {
            return .refused("the person changed the app; read it again")
        }
        return pressed ? .sent(.unattested) : .notHandled
    }

    /// The menu controller's answer, or nil when the person acted: then it is not called. This is the last check
    /// before the delegation, and its veto reaches the caller as a veto, never as a press not handled.
    private func delegated(_ title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool? {
        guard !personActed(in: processID) else { return nil }
        return await menus.pressMenuItem(titled: title, within: menuFrame, in: processID)
    }

    /// Whether the person touched the process at or after its latest scene was read: `MacActuator`'s rule 6, the
    /// same watch and the same comparison, whether or not the watch says it is running. No watch, no scene or no
    /// touch vetoes nothing.
    private func personActed(in processID: pid_t) -> Bool {
        guard let person, let entry = cache.latest(for: processID), let touched = person.lastTouch(of: processID) else {
            return false
        }
        return touched >= entry.readAt
    }

    // MARK: Off the caller's actor

    /// The window of the last scene, read again within the limits; nil without a scene or a window.
    private func read(_ processID: pid_t) async -> MacTreeNode? {
        guard let entry = cache.latest(for: processID) else { return nil }
        return await Self.read(by: reader, windowAt: entry.windowIndex, of: processID, limits: limits)
    }

    @concurrent
    static func read(by reader: any MacTreeReading, windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) async -> MacTreeNode? {
        try? await reader.read(windowAt: index, of: processID, limits: limits).window
    }

    /// Presses the control: true once the press was sent, uncertain included, so the engine does not click it again.
    /// A refusal, the call's stop before the write among them (`CancellationError`), answers false with nothing
    /// pressed; the click the engine then tries is refused by `MacActuator` as `stopped`, so a stop starts no gesture.
    @concurrent
    static func press(by actor: any MacAccessibilityActing, at address: MacElementAddress) async -> Bool {
        do {
            try await actor.perform("AXPress", on: address)
            return true
        } catch MacTreeFailure.uncertain {
            return true
        } catch {
            return false
        }
    }
}
