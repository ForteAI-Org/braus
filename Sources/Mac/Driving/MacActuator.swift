import CoreGraphics
import EngineCore
import Foundation
import MacDriver
import Synchronization

/// MacDeliveryNote says how the last gesture to a process went: the rung that ran, what it did, and
/// why each rung above it was skipped (spec section 3, rule 5). It feeds the outcome and, later, the
/// memory's channel table.
public struct MacDeliveryNote: Sendable, Equatable {

    public enum Rung: Int, Sendable, Equatable {
        case accessibility = 1
        case inPlace       = 2
    }

    public var rung: Rung
    public var how: String
    public var skipped: [String]
    /// The engine's verdict, once `confirm` gives it.
    public var effect: DeliveryEffect?
    /// Rung 2 delivered, but the key-window records it sent first could not be taken back
    /// (`MacEventReceipt.preparationNotRestored`).
    public var preparationNotRestored: Bool

    public init(
        rung                  : Rung,
        how                   : String,
        skipped               : [String],
        effect                : DeliveryEffect? = nil,
        preparationNotRestored: Bool = false
    ) {
        self.rung                   = rung
        self.how                    = how
        self.skipped                = skipped
        self.effect                 = effect
        self.preparationNotRestored = preparationNotRestored
    }
}

/// MacActuator fills `Actuating` with the MacDriver's ladder, rungs 1 and 2: every gesture is resolved
/// against the scene the engine was last given (`MacSceneCache`), planned by `MacRungPlanner`, and run
/// on the first rung that delivers.
///
/// - Rung 1 refusing before any request (`actionNotListed`, read from the element's own actions) falls to rung 2
///   with that reason. An error the app answered to a request (`actionFailed`) is `uncertain` and never replayed on
///   rung 2: the app may have acted (R06).
/// - A target that no longer matches its scene throws `staleTarget`: the engine reads again.
/// - An uncertain rung 1 (the app timed out) throws `uncertain` and is never replayed on rung 2.
/// - Rung 2 refused on this build throws, naming the reason; nothing was posted.
/// - Rung 1's blocking accessibility calls run off the caller's actor (`run`).
/// - The person first (rule 6): when the person clicked, typed or scrolled in the app after the scene
///   was read, the gesture is refused with `personActed`; the engine reads the app again.
/// - The call's stop (N16): a cancelled task is checked right before each rung's first effect, between rung 1's
///   refusal and rung 2, and by the hands before each write (`MacAccessibilityActing`). Before anything went out the
///   gesture is refused as `stopped`, a `GestureNotSent`: the engine answers it as refused with nothing sent, and an
///   input whose earlier gestures went out as a partial delivery, never replayed. A stop after an effect leaves that
///   effect standing (rung 1 answers `uncertain` between focus's writes; rung 2 keeps `InputDriver`'s own stop,
///   whose cancellation the engine answers as uncertain). The front app's guard is settled either way.
/// - Every failure but `uncertain` leaves the actuator as `GestureNotSent` (`MacActuationFailure.notSent`),
///   so the engine answers it as refused with nothing sent; `uncertain` stays a delivery that may have acted.
/// - `lastDeliveryRoute` keeps the default, posted: the engine reads an accessibility click as one that left
///   a field's caret at its end (the Seat's), and rung 1 only focuses a field, so its Command-Down is needed.
///
/// - The person's front app stays in front (`MacFocusGuard`): a gesture can make the app activate
///   itself (Notes' "New note" press does). When it did and the person did not act meanwhile, the
///   person's app is brought back; `takeFocus` tells how it went. A self-activation is no touch by the
///   person; keys they typed while the app was in front did reach it, and rule 6 refuses after them.
///
/// The app is never activated and its window never raised.
public final class MacActuator: Actuating {

    public let cache: MacSceneCache
    public let actor: any MacAccessibilityActing
    public let delivery: any MacEventDelivering
    /// Nil only where no person can touch the app (tests); a watch that is not running refuses nothing.
    public let person: (any MacPersonWatching)?
    /// Nil only where no person's app can be in front (tests): no gesture is guarded.
    public let focus: (any MacWorkspace)?
    private let notes = Mutex<[pid_t: MacDeliveryNote]>([:])
    private let focusOutcomes = Mutex<[pid_t: MacFocusGuard.Outcome]>([:])
    /// The processes a gesture left with key-window records not taken back, since the last take.
    private let unrestored = Mutex<Set<pid_t>>([])
    /// The processes whose last note no call has taken yet (`takeFreshDelivery`).
    private let fresh = Mutex<Set<pid_t>>([])

    public init(
        cache   : MacSceneCache,
        actor   : any MacAccessibilityActing,
        delivery: any MacEventDelivering,
        person  : (any MacPersonWatching)?,
        focus   : (any MacWorkspace)? = nil
    ) {
        self.cache    = cache
        self.actor    = actor
        self.delivery = delivery
        self.person   = person
        self.focus    = focus
    }

    /// How the last gesture to the process was delivered.
    public func lastDelivery(in processID: pid_t) -> MacDeliveryNote? {
        notes.withLock { $0[processID] }
    }

    /// The note of the last gesture delivered to the process since the last take, nil when none was delivered since;
    /// taking it keeps the note (`confirm` still writes its effect) but marks it read, so each call records only the
    /// gestures it sent itself, never an earlier call's (M05). A call whose gestures were refused before any went out
    /// takes nothing.
    public func takeFreshDelivery(in processID: pid_t) -> MacDeliveryNote? {
        guard fresh.withLock({ $0.remove(processID) }) != nil else { return nil }
        return notes.withLock { $0[processID] }
    }

    /// How the front app went across the last guarded gesture to the process since the last take, nil
    /// when none ran; taking it clears it, so each call reads its own gestures.
    public func takeFocus(in processID: pid_t) -> MacFocusGuard.Outcome? {
        focusOutcomes.withLock { $0.removeValue(forKey: processID) }
    }

    /// Whether a gesture to the process since the last take left key-window records not taken back;
    /// taking it clears it, so each call reports its own gestures.
    public func takeUnrestoredPreparation(in processID: pid_t) -> Bool {
        unrestored.withLock { $0.remove(processID) != nil }
    }

    public func perform(_ gesture: Gesture, in processID: pid_t) async throws {
        do {
            try await performOnLadder(gesture, in: processID)
        } catch let failure as MacActuationFailure {
            throw failure.notSent ?? failure
        }
    }

    private func performOnLadder(_ gesture: Gesture, in processID: pid_t) async throws {
        guard let entry = cache.latest(for: processID) else { throw MacActuationFailure.noScene }
        if let touched = person?.lastTouch(of: processID), touched >= entry.readAt {
            throw MacActuationFailure.personActed
        }
        guard let focus else { return try await deliver(gesture, entry: entry, processID: processID) }
        let focusGuard = await MacFocusGuard.begin(focus)
        do {
            try await deliver(gesture, entry: entry, processID: processID)
        } catch {
            await settle(focusGuard, processID)
            throw error
        }
        await settle(focusGuard, processID)
    }

    public func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {
        notes.withLock { $0[processID]?.effect = effect }
    }

    private func settle(_ focusGuard: MacFocusGuard, _ processID: pid_t) async {
        let outcome = await focusGuard.settle(after: processID)
        focusOutcomes.withLock { $0[processID] = outcome }
    }

    // MARK: Rungs

    /// The refusal of a gesture the call's stop reached before anything of it went out.
    static let stopped = GestureNotSent(reason: "stopped",
                                        sentence: "The call was stopped before anything of this gesture was sent.")

    /// Throws `stopped` when the call's task was cancelled; checked right before a rung's first effect.
    private static func checkStopped() throws {
        if Task.isCancelled { throw stopped }
    }

    private func deliver(_ gesture: Gesture, entry: MacSceneCache.Entry, processID: pid_t) async throws {
        switch MacRungPlanner.plan(gesture, at: Self.point(of: gesture), in: entry.window) {
            case .refused(let reason):
                throw MacActuationFailure.refused(reason)
            case .events(let reason, let needsKeyWindow):
                try Self.checkStopped()
                try await inPlace(gesture, entry: entry, processID: processID, needsKeyWindow: needsKeyWindow,
                                  skipped: [reason])
            case .accessibility(let step):
                try Self.checkStopped()
                do {
                    try await Self.run(step, by: actor, at: address(Self.target(of: step), entry, processID))
                    note(MacDeliveryNote(rung: .accessibility, how: Self.describe(step), skipped: []), processID)
                } catch is CancellationError {
                    // The hands throw it only before their first write: nothing of the gesture went out.
                    throw Self.stopped
                } catch MacTreeFailure.actionNotListed(let action) {
                    try await inPlaceAfterRungOne(gesture, entry: entry, processID: processID,
                                                  reason: "element has no \(action)")
                } catch MacTreeFailure.actionFailed(let reason) {
                    // The request reached the app, which may have acted: nothing is sent again on rung 2 (R06).
                    let how = "\(Self.describe(step)), uncertain: \(reason)"
                    note(MacDeliveryNote(rung: .accessibility, how: how, skipped: []), processID)
                    throw MacActuationFailure.uncertain(reason)
                } catch MacTreeFailure.staleTarget(let path) {
                    throw MacActuationFailure.staleTarget(path)
                } catch MacTreeFailure.uncertain(let reason) {
                    note(MacDeliveryNote(rung: .accessibility, how: "\(Self.describe(step)), uncertain: \(reason)", skipped: []),
                         processID)
                    throw MacActuationFailure.uncertain(reason)
                }
        }
    }

    /// Rung 1's accessibility calls block until the app answers or their messaging timeout passes. They
    /// run on the global executor, so the caller's actor, the main actor in Braus, is not held meanwhile
    /// (a whole act on Notes' "Nuova nota" took 9 to 10 s live, 15 Oct).
    @concurrent
    static func run(_ step: MacAccessibilityStep, by actor: any MacAccessibilityActing, at address: MacElementAddress) async throws {
        switch step {
            case .perform(let action, _): try await actor.perform(action, on: address)
            case .select                : try await actor.select(address)
            case .focus                 : try await actor.focus(address)
            case .scroll(_, let direction): try await actor.scroll(address, direction)
        }
    }

    static func target(of step: MacAccessibilityStep) -> MacTreeNode {
        switch step {
            case .perform(_, let node), .select(let node), .focus(let node), .scroll(let node, _): node
        }
    }

    /// Rung 2 after rung 1 refused before any request. A rung 2 refusal then stays `uncertain`, never "nothing was
    /// sent", as before: the conservative answer.
    private func inPlaceAfterRungOne(
        _ gesture: Gesture, entry: MacSceneCache.Entry, processID: pid_t, reason: String
    ) async throws {
        // Rung 1's refusal was read before any request, so a stop here leaves the whole gesture unsent.
        try Self.checkStopped()
        do {
            try await inPlace(gesture, entry: entry, processID: processID, needsKeyWindow: false, skipped: [reason])
        } catch MacActuationFailure.refused(let refusal) {
            throw MacActuationFailure.uncertain("\(reason), then rung 2 refused: \(refusal)")
        }
    }

    private func inPlace(
        _ gesture: Gesture, entry: MacSceneCache.Entry, processID: pid_t, needsKeyWindow: Bool, skipped: [String]
    ) async throws {
        guard entry.windowNumber != 0 else {
            throw MacActuationFailure.refused("rung 2 needs the window's server number; none matched its frame")
        }
        let receipt = try await delivery.deliver(
            gesture,
            toWindow      : entry.windowNumber,
            of            : processID,
            needsKeyWindow: needsKeyWindow
        )
        let how = needsKeyWindow ? "events to the process with the key-window records" : "events to the process"
        if receipt.preparationNotRestored { _ = unrestored.withLock { $0.insert(processID) } }
        note(MacDeliveryNote(rung: .inPlace, how: how, skipped: skipped,
                             preparationNotRestored: receipt.preparationNotRestored), processID)
    }

    private func address(_ node: MacTreeNode, _ entry: MacSceneCache.Entry, _ processID: pid_t) -> MacElementAddress {
        MacElementAddress(
            processID  : processID,
            windowIndex: entry.windowIndex,
            path       : node.path,
            role       : node.role,
            name       : node.title ?? node.descriptionText ?? node.help ?? node.placeholder ?? Self.rowText(node),
            window     : entry.windowIdentity
        )
    }

    private func note(_ note: MacDeliveryNote, _ processID: pid_t) {
        notes.withLock { $0[processID] = note }
        _ = fresh.withLock { $0.insert(processID) }
    }

    /// A row has no name of its own; its first text names it for the stale check.
    static func rowText(_ node: MacTreeNode) -> String? {
        guard node.role == "AXRow" else { return nil }
        return node.flattened.first { $0.role == "AXStaticText" && $0.value?.isEmpty == false }?.value
    }

    static func point(of gesture: Gesture) -> CGPoint {
        switch gesture {
            case .click(let point, _, _), .scroll(let point, _, _), .drag(let point, _): point
            case .key, .character, .type, .insert                                     : .zero
        }
    }

    static func describe(_ step: MacAccessibilityStep) -> String {
        switch step {
            case .perform(let action, let node): "\(action) on \(node.role)"
            case .select(let node)             : "selected \(node.role)"
            case .focus(let node)              : "focused \(node.role)"
            case .scroll(let node, let direction): "one page \(direction.rawValue) in \(node.role)"
        }
    }
}

public enum MacActuationFailure: Error, Equatable, Sendable {
    /// No scene was read for the process: the engine reads before it acts.
    case noScene
    case staleTarget([Int])
    case uncertain(String)
    case refused(String)
    /// The person clicked, typed or scrolled in the app after its scene was read: read it again.
    case personActed
}

extension MacActuationFailure {

    /// The failure as the engine's `GestureNotSent` when nothing of the gesture went out: every case but
    /// `uncertain`, whose accessibility request may have acted and is never replayed. Rule 6: the engine
    /// answers a refusal and never retries it.
    public var notSent: GestureNotSent? {
        switch self {
            case .noScene:
                GestureNotSent(reason: "no_scene", sentence: "No scene of the app was read yet: observe it first.")
            case .staleTarget:
                GestureNotSent(reason: "stale_target",
                               sentence: "The control no longer matches the scene that named it: observe again.")
            case .refused(let reason):
                GestureNotSent(reason: "refused", sentence: "The app's route refused it: \(reason).")
            case .personActed:
                GestureNotSent(reason: "person_acted", sentence: "The person changed the app; read it again.")
            case .uncertain:
                nil
        }
    }
}
