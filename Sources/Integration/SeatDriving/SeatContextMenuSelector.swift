import AccessibilityActions
import CoreGraphics
import EngineCore
import Foundation
import Perception
import PerceptionCore
import SeatCapture
import SeatCore
import SeatSession
import WindowPlacement

/// SeatContextMenuSelector chooses one observed row through the Driver's scoped menu interaction.
/// The menu's capture and input share its attested identity. The Driver revokes that authority and
/// verifies withdrawal on every path; no ordinary parent input is sent while the menu is tracking.
@MainActor
public struct SeatContextMenuSelector {

    private let target: SeatTarget
    private let pipeline: ScenePipeline

    /// Creates a selector over a borrowed or owned target and its production perception pipeline.
    public init(target: SeatTarget, pipeline: ScenePipeline) {
        self.target = target
        self.pipeline = pipeline
    }

    /// Opens once and chooses a unique enabled row. Delivery and withdrawal do not prove the
    /// command's application effect: the outcome requires a fresh check of that intended effect. Its
    /// check (`OperationCheck`) says whether the row was chosen in the Driver's menu, never that the
    /// command took effect; `report` receives what the choice perceived, for the call's record.
    public func select(
        item: String,
        on control: String,
        identity: ApplicationIdentity,
        section: String? = nil,
        permissions: ActionPermissions = ActionPermissions(),
        dryRun: Bool = false,
        report: @escaping @MainActor (SelectorPerception) async -> Void = { _ in }
    ) async throws -> ActOutcome {
        try await selectWithReceipt(item: item, on: control, identity: identity, section: section,
                                    permissions: permissions, dryRun: dryRun, report: report).outcome
    }

    /// `select`, with the Seat's outcome of the menu when the Seat was asked (M05): the opener's receipt and the
    /// receipts posted inside the menu, for the call's record; nil when the choice was refused before the Seat was
    /// asked (no item, no control, destructive refused, the text-field rule, a dry run). A throw returns nothing: the
    /// receipts of what went out before it are not recovered.
    package func selectWithReceipt(
        item: String,
        on control: String,
        identity: ApplicationIdentity,
        section: String? = nil,
        permissions: ActionPermissions = ActionPermissions(),
        dryRun: Bool = false,
        report: @escaping @MainActor (SelectorPerception) async -> Void = { _ in }
    ) async throws -> (outcome: ActOutcome, receipt: SeatMenuOutcome?) {
        let seat = try target.agentSeat()
        let turn = try await seat.acquire()
        var perception = SelectorPerception()
        var receipt: SeatMenuOutcome?
        do {
            let outcome = try await perform(
                item: item, on: control, identity: identity, section: section,
                permissions: permissions, dryRun: dryRun, seat: seat, turn: turn, perception: &perception, receipt: &receipt
            )
            try seat.release(turn)
            await report(perception)
            return (outcome, receipt)
        } catch {
            do { try seat.release(turn) }
            catch let cleanup {
                throw TurnReleaseFailure(primary: String(describing: error), cleanup: String(describing: cleanup))
            }
            throw error
        }
    }

    private func perform(
        item: String,
        on control: String,
        identity: ApplicationIdentity,
        section: String?,
        permissions: ActionPermissions,
        dryRun: Bool,
        seat: AgentSeat,
        turn: Turn,
        perception: inout SelectorPerception,
        receipt: inout SeatMenuOutcome?
    ) async throws -> ActOutcome {
        guard !LabelText.normalize(item).isEmpty else {
            return ActOutcome(.refused, "context_menu needs the item's title")
        }
        let parent = try target.currentWindow()
        let beforeDelivery = try await target.observe()
        let before = try await perceive(beforeDelivery, identity: identity, title: parent.title)
        perception.before = before
        let opener: SceneElement
        switch before.scene.resolve(
            target: control, section: section, preferNativeControls: true,
            preferTextEntry: permissions.contextMenusOnTextFieldsOnly
        ) {
            case .found(let element): opener = element
            case .none:
                return ActOutcome(.honestMiss, "no target '\(control)' for the contextual menu", scene: before.scene)
            case .ambiguous(let count):
                return ActOutcome(.ambiguous, "\(count) targets match '\(control)'; choose a section or unique ID", scene: before.scene)
        }
        // The item is classified with the control that opened its menu first. The seat's menus are chosen
        // through the scene, which cannot read an irreversible effect back.
        if ActionPolicy.isDestructiveMenuItem(
            item, openedBy: opener.label, bundleID: identity.bundleID,
            role: opener.role, container: opener.container
        ) {
            switch IrreversiblePolicy.decision(allowed: permissions.allowsDestructive, readBack: .cannotConfirm) {
                case .allowed:
                    break
                case .needsConsent:
                    return ActOutcome(.refused, "'\(item)' requires --allow-destructive", scene: before.scene)
                case .cannotReadBack:
                    return ActOutcome(.refused, IrreversiblePolicy.readBackRefusal("'\(item)'"), scene: before.scene)
            }
        }
        let captured = beforeDelivery.geometry.window
        let nativeWindow = DropdownOpening.Window(
            processID    : captured.processID,
            number       : captured.windowNumber,
            frame        : captured.frame,
            resolveNumber: { WindowRelocator.windowNumber(of: $0) }
        )
        let route = Self.route(
            opener        : opener.role,
            textFieldsOnly: permissions.contextMenusOnTextFieldsOnly,
            offersShowMenu: { (try? DropdownOpening.canShowMenu(control: opener.label, in: nativeWindow)) == true }
        )
        if route == .refused {
            return ActOutcome(.refused, "\(identity.name) opens this control's menu outside the Seat and the control offers no native menu action; use a native text field or a visible button", scene: before.scene)
        }
        if dryRun {
            let opening = route == .native ? " through its native show-menu action" : ""
            return ActOutcome(.dryRun, "would open '\(opener.label)'\(opening) and choose '\(item)' in its observed menu", scene: before.scene)
        }
        perception.target = opener
        var selected: String?
        var missing: String?
        var failure: String?
        var menuWindow: PerceivedWindow?
        let cleanup: String
        let menuNumber: Int
        if route == .native {
            // The menu is chosen through its own accessibility items: no pixels, no pointer.
            @MainActor @Sendable func choose(_ menu: ContextMenu) async throws -> Bool {
                try Task.checkCancellation()
                do {
                    try DropdownOpening.select(item: item, in: menu.frame, processID: menu.window.processID)
                } catch DropdownOpening.Failure.controlNotUnique {
                    let titles = DropdownOpening.menuItemTitles(in: menu.frame, processID: menu.window.processID)
                    missing = "no unique enabled '\(item)' in the native menu. It holds: "
                        + (titles.isEmpty ? "nothing readable" : titles.joined(separator: ", "))
                    return false
                }
                selected = item
                return true
            }
            let receipt = try await seat.useNativePopupMenu(
                of      : parent,
                turn    : turn,
                opening : { try DropdownOpening.showMenu(control: opener.label, in: nativeWindow) },
                choosing: choose
            )
            cleanup    = "\(receipt.closedBy)"
            menuNumber = receipt.menu.window.windowNumber
        } else {
            guard let location = InputLocation(screenPoint: before.globalPoint(of: opener), observedIn: beforeDelivery.geometry) else {
                throw SeatDrivingFailure.frameUnusable
            }
            let result = try await seat.withContextMenu(
                openedAt: location, observation: beforeDelivery.reference, turn: turn
            ) { interaction in
                do {
                    try Task.checkCancellation()
                    let delivery: SeatObservationDelivery
                    switch await interaction.observe() {
                        case .success(let observed): delivery = observed
                        case .failure(let reason): throw reason
                    }
                    let menu = try await perceive(delivery, identity: identity, title: "Contextual menu")
                    menuWindow = menu
                    // The scene's own resolution first, then the menu title rule that names
                    // `Compress “file”` by "Compress"; a miss names what the menu holds.
                    let enabled = menu.scene.elements.filter { !$0.isUnlabeled && $0.isEnabled != false }
                    var chosen: SceneElement?
                    if case .found(let found) = menu.scene.resolve(target: item) {
                        chosen = found.isEnabled != false ? found : nil
                    } else {
                        chosen = LabelText.menuItemMatch(item, in: enabled.map(\.label)).map { enabled[$0] }
                    }
                    guard let row = chosen else {
                        let titles = enabled.map(\.label).filter { LabelText.isNameworthy($0) }
                        missing = "no unique enabled '\(item)' in the observed menu. It holds: "
                            + (titles.isEmpty ? "nothing readable" : titles.joined(separator: ", "))
                        return
                    }
                    guard let choice = InputLocation(screenPoint: menu.globalPoint(of: row), observedIn: delivery.geometry) else {
                        throw SeatDrivingFailure.frameUnusable
                    }
                    try Task.checkCancellation()
                    try await interaction.send(.click(choice, button: .left), observation: delivery.reference)
                    selected = row.label
                } catch {
                    failure = String(describing: error)
                }
            }
            cleanup    = "\(result.cleanup)"
            menuNumber = result.menu.window.windowNumber
            // The pointer path has a Seat menu outcome; the native popup uses its own AX receipt.
            receipt = result
        }
        try Task.checkCancellation()
        // A failed post-menu reading cannot turn a delivered choice into a dead click or invite
        // replay. Withdrawal is already the Driver's verified result, independent of this capture.
        var afterWindow: PerceivedWindow?
        var readAfter = true
        do {
            afterWindow = try await perceive(try await target.observe(), identity: identity, title: parent.title)
        } catch {
            readAfter = false
            failure = [failure, "parent observation: \(error)"].compactMap { $0 }.joined(separator: "; ")
        }
        perception.menu  = menuWindow
        perception.after = afterWindow
        let after = afterWindow?.scene
        let checked = OperationCheck.Target(opener)
        let afterLimit: [OperationCheck.Limit] = readAfter ? [] : [.noAfterScene]
        if let failure, selected == nil {
            return ActOutcome(
                .actedUnverified,
                "contextual menu interaction: \(failure); cleanup: \(cleanup). Inspect the intended effect before further input",
                scene: after,
                check: OperationCheck(
                    condition: .menuItemChosen,
                    method   : .driverReceipt,
                    verdict  : .unknown,
                    expected : item,
                    limits   : [.deliveryUncertain, .commandEffectUnchecked] + afterLimit,
                    performed: .uncertain,
                    target   : checked
                )
            )
        }
        if let missing {
            // The menu opened and was withdrawn with no row chosen: the requested choice was not performed.
            return ActOutcome(
                .honestMiss,
                "\(missing); cleanup: \(cleanup)",
                scene: after,
                check: OperationCheck(
                    condition : .menuItemChosen,
                    method    : .driverReceipt,
                    verdict   : .failed,
                    expected  : item,
                    limits    : afterLimit,
                    performed : .substitute,
                    substitute: "menu_opened_and_withdrawn",
                    target    : checked
                )
            )
        }
        // The Driver delivered the choice and verified the menu's withdrawal: the choice is checked,
        // the command's effect is not.
        let chosen = OperationCheck(
            condition: .menuItemChosen,
            method   : .driverReceipt,
            verdict  : .passed,
            expected : item,
            observed : selected,
            limits   : [.commandEffectUnchecked] + afterLimit,
            performed: .requested,
            target   : checked
        )
        if let failure {
            return ActOutcome(
                .actedUnverified,
                "contextual menu interaction: \(failure); cleanup: \(cleanup). Inspect the intended effect before further input",
                scene: after,
                check: chosen
            )
        }
        let message = "requested '\(selected ?? item)' in menu #\(menuNumber); cleanup: \(cleanup). The command's application effect remains unverified: inspect it before further input"
        return ActOutcome(.actedUnverified, message, scene: after, check: chosen)
    }

    /// How the opener's menu is reached: a posted right click, the control's own Show Menu action,
    /// or neither. Where menus open under the person's pointer, only a text field's opens in the Seat.
    enum Route { case pointer, native, refused }

    static func route(opener role: String?, textFieldsOnly: Bool, offersShowMenu: () -> Bool) -> Route {
        guard textFieldsOnly, !AccessibilityAugmentation.textEntryRoles.contains(role ?? "") else { return .pointer }
        return offersShowMenu() ? .native : .refused
    }

    private func perceive(
        _ delivery: SeatObservationDelivery, identity: ApplicationIdentity, title: String
    ) async throws -> PerceivedWindow {
        guard delivery.frame.geometry.isValid, let image = delivery.frame.makeCGImage() else {
            throw SeatDrivingFailure.frameUnusable
        }
        let captured = delivery.geometry.window
        let scene = try await pipeline.perceive(image, of: ScenePipeline.Window(
            bundleID: identity.bundleID, appName: identity.name, title: title,
            processID: captured.processID, frame: captured.frame, windowNumber: captured.windowNumber
        ))
        return PerceivedWindow(scene: scene, frame: captured.frame)
    }

    private struct TurnReleaseFailure: Error, CustomStringConvertible {
        let primary: String
        let cleanup: String
        var description: String { "\(primary); releasing the menu Turn: \(cleanup)" }
    }
}
