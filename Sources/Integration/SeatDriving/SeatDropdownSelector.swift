import CoreGraphics
import AccessibilityActions
import EngineCore
import Foundation
import Perception
import PerceptionCore
import SeatCapture
import SeatCore
import SeatSession
import WindowPlacement

/// SeatDropdownSelector keeps observation, opening, selection and verification in one Seat Turn.
/// The Driver owns the temporary menu and its cleanup. Perception identifies a row only in a
/// capture of that menu's attested window, never in the parent application's accessibility tree.
@MainActor
public struct SeatDropdownSelector {

    private let target: SeatTarget
    private let pipeline: ScenePipeline
    private let popupRows: (any PopupRowReading)?
    private let windows: (any WindowListing)?

    /// Creates a selector. `popupRows` is optional and nil by default: with a reader the arrow-key
    /// route is counted over the rows the application named for itself, scrolled-out ones included,
    /// and without one it is counted over the rows the pixels cut out of the painted page, which is
    /// what this always did.
    public init(
        target: SeatTarget,
        pipeline: ScenePipeline,
        popupRows: (any PopupRowReading)? = nil,
        windows: (any WindowListing)? = nil
    ) {
        self.target = target
        self.pipeline = pipeline
        self.popupRows = popupRows
        self.windows = windows
    }

    /// Selects one item in a flat native dropdown. Success requires the requested value to be
    /// visible at the original control after the menu closes. Capture diagnostics are optional and
    /// remain local to the caller; no images enter the outcome's text scene.
    public func select(
        control: String,
        item: String,
        identity: ApplicationIdentity,
        permissions: ActionPermissions = ActionPermissions(),
        dryRun: Bool = false,
        onMenu: @escaping @MainActor @Sendable (ContextMenu) -> Void = { _ in },
        onCapture: @escaping @MainActor @Sendable (String, CGImage) throws -> Void = { _, _ in },
        report: @escaping @MainActor (SelectorPerception) async -> Void = { _ in }
    ) async throws -> (outcome: ActOutcome, receipt: PopupMenuReceipt?) {
        let seat = try target.agentSeat()
        let window = try target.currentWindow()
        let turn = try await seat.acquire()
        var perception = SelectorPerception()
        do {
            let result = try await perform(
                control: control, item: item, identity: identity, permissions: permissions,
                dryRun: dryRun, seat: seat, window: window, turn: turn, onMenu: onMenu, onCapture: onCapture,
                perception: &perception
            )
            try seat.release(turn)
            await report(perception)
            return result
        } catch {
            do { try seat.release(turn) }
            catch let cleanup { throw DropdownFailure.cleanup(primary: String(describing: error), cleanup: String(describing: cleanup)) }
            throw Self.worded(error)
        }
    }

    /// The seat's stop in words, as the agent reads it: Preview's Save As, 14/10/2026, answered a selection with
    /// "SeatInterruption(issues: [SeatCore.SeatIssue.geometryChanged], beforeAnyEvent: true)". A selection is several
    /// Commands, so a stop before one of them never says that nothing of the selection went out. Any other error
    /// is returned as it is.
    static func worded(_ error: any Error) -> any Error {
        guard let stop = error as? SeatInterruption else { return error }
        let why = stop.issues.map(SeatActuator.words).joined(separator: "; ")
        return GestureInterrupted(sentence: why.prefix(1).uppercased() + why.dropFirst() + (stop.beforeAnyEvent
            ? ". The seat stopped this step of the selection before sending it; an earlier step, such as opening the "
                + "menu, may have gone out"
            : ". It may have taken effect"))
    }

    private func perform(
        control: String,
        item: String,
        identity: ApplicationIdentity,
        permissions: ActionPermissions,
        dryRun: Bool,
        seat: AgentSeat,
        window: AdoptedWindow,
        turn: Turn,
        onMenu: @escaping @MainActor @Sendable (ContextMenu) -> Void,
        onCapture: @escaping @MainActor @Sendable (String, CGImage) throws -> Void,
        perception: inout SelectorPerception
    ) async throws -> (outcome: ActOutcome, receipt: PopupMenuReceipt?) {
        let beforeDelivery = try await target.observe()
        let beforeStill = beforeDelivery.frame
        let capturedWindow = beforeDelivery.geometry.window
        let beforeTitle = try await title(of: beforeStill)
        let nativeWindow = DropdownOpening.Window(
            processID: capturedWindow.processID,
            number: capturedWindow.windowNumber,
            frame: capturedWindow.frame,
            resolveNumber: { WindowRelocator.windowNumber(of: $0) }
        )
        let before = try await perceive(
            beforeStill, identity: identity, title: beforeTitle,
            stage: "before", onCapture: onCapture
        )
        perception.before = before
        var opener: SceneElement?
        var scopedBounds: NormalizedRect?
        // A native popup and its static caption can share a name. Prefer the control;
        // two actual controls with that name must still remain ambiguous.
        let resolution = before.scene.resolve(target: control, preferNativeControls: true)
        if case .found(let element) = resolution {
            opener = element
        } else if case .none = resolution,
                  beforeStill.geometry.windowObservation != nil,
                  let frame = try? DropdownOpening.frame(control: control, in: nativeWindow),
                  before.frame.contains(frame),
                  let bounds = AccessibilityFrameTrust.normalized(frame, in: before.frame),
                  let scoped = try await controlScene(beforeStill, bounds: bounds, identity: identity, title: beforeTitle),
                  case .found(let value) = scoped.resolve(target: control, preferNativeControls: true) {
            scopedBounds = bounds
            opener = SceneElement(id: value.id, kind: .control, label: value.label, bounds: bounds, role: "AXPopUpButton")
        }
        guard let opener else {
            let labels = before.scene.elements.map(\.label).joined(separator: ", ")
            return (ActOutcome(.honestMiss, "dropdown '\(control)' is missing or ambiguous. Read: \(labels)", scene: before.scene), nil)
        }
        if ActionPolicy.isAudioSendSelector(
            label: opener.label, bundleID: identity.bundleID, role: opener.role, container: opener.container
        ) {
            return (ActOutcome(.refused,
                "This audio routing control needs observed menu steps. Use act on the track's Send selector, "
                    + "then act on the visible menu item or submenu. To clear it, choose 'no send'. "
                    + "No input was sent; select is for flat dropdowns.", scene: before.scene), nil)
        }
        // The opener and the item are classified with their context first. The seat's dropdowns are chosen
        // through the scene, which cannot read an irreversible effect back.
        if ActionPolicy.isDestructive(
               label: opener.label, bundleID: identity.bundleID, role: opener.role, container: opener.container
           ) || ActionPolicy.isDestructiveMenuItem(
               item, openedBy: opener.label, bundleID: identity.bundleID,
               role: opener.role, container: opener.container
           ) {
            switch IrreversiblePolicy.decision(allowed: permissions.allowsDestructive, readBack: .cannotConfirm) {
                case .allowed:
                    break
                case .needsConsent:
                    return (ActOutcome(.refused, "selection requires --allow-destructive", scene: before.scene), nil)
                case .cannotReadBack:
                    return (ActOutcome(.refused, IrreversiblePolicy.readBackRefusal("Selecting '\(item)'"),
                                       scene: before.scene), nil)
            }
        }
        if dryRun {
            return (ActOutcome(.dryRun, "would open '\(opener.label)' and select '\(item)' in its own menu window", scene: before.scene), nil)
        }
        perception.target = opener
        let checked = OperationCheck.Target(opener)
        var menuScene: SceneSnapshot?
        var menuWindow: PerceivedWindow?
        @MainActor @Sendable func readItem(_ menu: ContextMenu, fromDisplay: Bool) async throws -> SceneElement? {
            onMenu(menu)
            guard let identityOfMenu = menu.window.identity else { throw SeatDrivingFailure.frameUnusable }
            let observed: PerceivedWindow
            if fromDisplay {
                // Some custom menu window filters return scaled parent pixels. Capture the actual
                // display composition and crop only the attested, still-unmoved menu rectangle.
                let still = try await target.displayStill()
                guard still.geometry.isValid, let pixels = still.makeCGImage(),
                      still.geometry.screenRect.contains(menu.frame),
                      let live = WindowServerProbe.geometry(of: menu.window.windowNumber),
                      live.hasSameIdentity(as: menu.window), live.frame == menu.frame else {
                    throw SeatDrivingFailure.frameUnusable
                }
                let display = still.geometry.screenRect
                let scale = still.geometry.scaleFactor
                let crop = CGRect(x: (menu.frame.minX - display.minX) * scale,
                                  y: (menu.frame.minY - display.minY) * scale,
                                  width: menu.frame.width * scale, height: menu.frame.height * scale).integral
                guard let image = pixels.cropping(to: crop) else { throw SeatDrivingFailure.frameUnusable }
                try onCapture("menu", image)
                let scene = try await pipeline.perceive(image, of: ScenePipeline.Window(
                    bundleID: identity.bundleID, appName: identity.name, title: "Dropdown", frame: menu.frame
                ))
                observed = PerceivedWindow(scene: scene, frame: menu.frame)
            } else {
                observed = try await perceive(
                    try await SeatCaptureStream.still(of: .attestedWindow(identityOfMenu), timeout: .seconds(3)),
                    identity: identity, title: "Dropdown", stage: "menu", onCapture: onCapture
                )
            }
            menuScene = observed.scene
            menuWindow = observed
            guard observed.frame == menu.frame else { throw SeatDrivingFailure.frameUnusable }
            guard case .found(let element) = observed.scene.resolve(target: item) else { return nil }
            return element
        }
        let receipt: PopupMenuReceipt
        // A remote file panel's popup is opened and chosen through accessibility alone,
        // and its pixel opener is refused by the seat (ADR 0031).
        let remotePanel = seat.holdsRemoteFilePanel
        var remoteListing: String?
        @MainActor @Sendable func chooseRemotely(_ menu: ContextMenu) async throws -> Bool {
            let roots = RemoteMenuChoice.roots(host: window.reference.processID, menuOwner: menu.window.processID)
            let outcome = try RemoteMenuChoice.accessibility.choose(item, in: menu.frame, under: roots)
            guard case .missing(let listing) = outcome else { return true }
            remoteListing = listing
            return false
        }
        if try DropdownOpening.canShow(control: opener.label, in: nativeWindow) {
            receipt = try await seat.useNativePopupMenu(
                of: window, turn: turn,
                opening: {
                    try DropdownOpening.show(control: opener.label, in: nativeWindow)
                }
            ) { menu in
                if remotePanel { return try await chooseRemotely(menu) }
                guard try await readItem(menu, fromDisplay: false) != nil else { return false }
                try Task.checkCancellation()
                try DropdownOpening.select(item: item, in: menu.frame, processID: window.reference.processID)
                return true
            }
        } else {
            // The observation's own geometry, which is what the seat converts a coordinate
            // through: the opener is clicked under the picture it was read in.
            guard let location = InputLocation(screenPoint: before.globalPoint(of: opener),
                                               observedIn: beforeDelivery.geometry) else {
                throw SeatDrivingFailure.frameUnusable
            }
            receipt = try await seat.useDropdownMenu(
                openedAt: location, of: window, turn: turn, keyInterval: ActionTiming.standard.popupArrow
            ) { [rowReader = popupRows] menu in
                guard let element = try await readItem(menu, fromDisplay: true), let scene = menuScene else { return nil }
                // The rows the application named for itself, when a reader is there to ask: they
                // include what the page does not paint, so the distance between two items is the
                // real one. Pixel rows, and no wrap through a page, otherwise.
                let named = await rowReader?.popupRows(
                    ofProcess : window.reference.processID,
                    popupFrame: menu.frame
                ) ?? []
                let currentValue = opener.value ?? opener.label
                let route = PopupRowPick.plan(rows: named, currentValue: currentValue, target: element.label)
                    ?? PopupRowPick.plan(
                        rows        : PopupRowPick.rows(in: scene, windowFrame: menu.frame, popupFrame: menu.frame),
                        currentValue: currentValue,
                        target      : element,
                        wraps       : false
                    )
                guard let plan = route else { return nil }
                let arrow = plan.delta > 0 ? Key.downArrow : Key.upArrow
                return Array(repeating: arrow, count: abs(plan.delta)) + [Key.return]
            }
        }
        let afterStill = try await target.windowStill()
        let afterTitle = try await title(of: afterStill)
        let sameWindow = capturedWindow.identity.map {
            afterStill.geometry.windowObservation?.window.identity == $0
        } ?? false
        let after = try await perceive(
            afterStill, identity: identity, title: afterTitle,
            stage: "after", onCapture: onCapture
        )
        perception.menu  = menuWindow
        perception.after = after
        guard receipt.selectionRequested else {
            let labels = remoteListing
                ?? menuScene?.elements.map(\.label).joined(separator: ", ")
                ?? "unreadable"
            // The menu opened and closed with no row chosen: the requested selection was not performed.
            return (
                ActOutcome(
                    .honestMiss,
                    "no unique '\(item)' in the dropdown; menu closed. Items: \(labels)",
                    scene: after.scene,
                    check: OperationCheck(
                        condition : .menuItemChosen,
                        method    : .driverReceipt,
                        verdict   : .failed,
                        expected  : item,
                        performed : .substitute,
                        substitute: "menu_opened_and_closed",
                        target    : checked
                    )
                ),
                receipt
            )
        }
        let verified: Bool
        let method: OperationCheck.Method
        var read: String?
        var readable = true
        if !sameWindow {
            verified = false
            method = .controlValue
            readable = false
        } else if remotePanel {
            // The popup's own value, by its label or, once changed, by the value it now holds.
            let value = (try? DropdownOpening.value(control: opener.label, in: nativeWindow))
                ?? (try? DropdownOpening.value(control: item, in: nativeWindow))
            verified = value.map { LabelText.normalize($0) == LabelText.normalize(item) } ?? false
            method   = .controlValue
            read     = value
            readable = value != nil
        } else if let scopedBounds {
            let scoped = try await controlScene(afterStill, bounds: scopedBounds, identity: identity, title: afterTitle)
            if let scoped, case .found(let value) = scoped.resolve(target: item) {
                verified = LabelText.normalize(value.label) == LabelText.normalize(item)
                    && after.frame.size == before.frame.size
                read = value.label
            } else {
                verified = false
                readable = false
            }
            method = .sceneText
        } else {
            verified = DropdownValueVerification.verifies(
                item: item, control: opener, after: after.scene.elements
            )
            method   = .controlValue
            read     = verified ? item : nil
            readable = verified
        }
        // A value that did not read as the item is not proved another: it stays unknown unless a value was read.
        let check = OperationCheck(
            condition: .valueReadBack, method: method,
            verdict: verified ? .passed : (read != nil ? .failed : .unknown), expected: item, observed: read,
            limits: readable ? [] : [.readbackUnavailable], performed: .requested, target: checked
        )
        let message = verified
            ? "selected '\(item)' in menu window #\(receipt.menu.window.windowNumber); the dropdown now reads '\(item)'"
            : "requested '\(item)' in menu window #\(receipt.menu.window.windowNumber), but the dropdown value was not verified"
        return (
            ActOutcome(verified ? .foundActed : .actedUnverified, message, scene: after.scene, check: check),
            receipt
        )
    }

    /// Names the captured recipient, which can be a dialog above the held document.
    private func title(of still: SeatFrame) async throws -> String {
        guard let window = still.geometry.windowObservation?.window else { return "" }
        if let windows {
            let rows = try await windows.windows(ownedBy: window.processID).filter { $0.number == window.windowNumber }
            return rows.count == 1 ? rows[0].title ?? "" : ""
        }
        guard let captured = target.lastCapturedWindow,
              captured.reference.identity == window.identity else { return "" }
        return captured.title
    }

    private func controlScene(
        _ still: SeatFrame, bounds: NormalizedRect, identity: ApplicationIdentity, title: String
    ) async throws -> SceneSnapshot? {
        guard still.geometry.windowObservation != nil, let image = still.makeCGImage() else { return nil }
        // Map the window region into the delivered surface, including ScreenCaptureKit padding.
        let content = still.geometry.contentRectInSurface
        let scale = still.geometry.scaleFactor
        let pixels = bounds.pixelBox(in: CGSize(width: content.width * scale, height: content.height * scale))
            .offsetBy(dx: content.minX * scale, dy: content.minY * scale)
        let imageBounds = NormalizedRect(
            x: pixels.minX / CGFloat(image.width), y: pixels.minY / CGFloat(image.height),
            width: pixels.width / CGFloat(image.width), height: pixels.height / CGFloat(image.height)
        )
        return try await pipeline.perceive(
            image, inside: imageBounds, of: ScenePipeline.Window(bundleID: identity.bundleID, appName: identity.name, title: title)
        )
    }

    private func perceive(
        _ still: SeatFrame,
        identity: ApplicationIdentity,
        title: String,
        stage: String,
        onCapture: (String, CGImage) throws -> Void
    ) async throws -> PerceivedWindow {
        guard still.geometry.isValid, let image = still.makeCGImage() else { throw SeatDrivingFailure.frameUnusable }
        try onCapture(stage, image)
        let frame = still.geometry.screenRect
        let scene = try await pipeline.perceive(image, of: ScenePipeline.Window(
            bundleID: identity.bundleID,
            appName: identity.name,
            title: title,
            processID: still.geometry.windowObservation?.window.processID,
            frame: frame,
            windowNumber: still.geometry.windowObservation?.window.windowNumber
        ))
        return PerceivedWindow(scene: scene, frame: frame)
    }
}

/// DropdownFailure preserves both the primary operation error and a failed Turn release.
public enum DropdownFailure: Error {
    case cleanup(primary: String, cleanup: String)
}
