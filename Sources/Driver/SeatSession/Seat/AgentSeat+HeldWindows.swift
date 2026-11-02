import CoreGraphics
import SeatCore

extension AgentSeat {
    /// Publishes presentation from the seat's existing inventory; never grants input authority.
    /// An unavailable reading keeps the last list rather than claiming every window closed.
    func rememberHeldWindowPresentation(_ snapshot: AssignedSurfaceSnapshot) {
        guard !isApplicationLent else { return }
        for (identity, metadata) in snapshot.presentation { heldWindowMetadata[identity] = metadata }
        for identity in snapshot.destroyedByWindowServer + snapshot.withdrawnByApplication {
            heldWindowMetadata[identity] = nil
        }
        guard snapshot.inventory.completeness.isQualified else { return }
        let rows = snapshot.inventory.rows.map(\.surface)
        let order = Dictionary(heldWindowOrder.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        publishHeldWindows(rows.sorted {
            ($0.reference.identity.flatMap { order[$0] } ?? Int.max)
                < ($1.reference.identity.flatMap { order[$0] } ?? Int.max)
        }, frontToBack: false)
    }

    /// Uses the front-to-back WindowServer reading already made by a follow pass.
    func publishHeldWindows(_ surfaces: [WindowSurface], frontToBack: Bool = true) {
        guard !isApplicationLent else { return }
        if frontToBack { heldWindowOrder = surfaces.compactMap(\.reference.identity) }
        let process = currentTarget?.reference.identity?.process ?? assignmentKit.lifecycle.current?.instance
        let held = Set(session.records.values.compactMap { $0.window.reference.identity })
            .union(assignmentKit.inventory.heldMembers.map(\.identity))
        // A decoration, a tooltip or a context menu is part of another window, not one of its own.
        let ineligible = assignmentKit.lifecycle.isAssigned ? selectionKit.status().ineligible : [:]
        let windows = surfaces.filter { surface in
            guard let identity = surface.reference.identity else { return false }
            switch ineligible[identity] {
                case .roleCannotBeSelected, .transientMenu: return false
                default: break
            }
            return identity.process == process && held.contains(identity)
                && surface.isVisible && sensing.virtualDisplayBounds.contains(surface.reference.frame)
        }
        heldWindowSurfaces = windows
        heldWindowMetadata = heldWindowMetadata.filter { held.contains($0.key) }
        heldWindowsChanged?()
    }

    /// Lending stands down movement, but a closed window must still release its preview slot.
    func pruneClosedLentWindowPreviews() {
        guard heldWindowsChanged != nil else { return }
        let remaining = heldWindowSurfaces.filter { surface in
            let window = surface.reference
            if sensing.windowIsDestroyed(window) { return false }
            guard let live = sensing.windowGeometry(of: window.windowNumber) else { return true }
            return live.hasSameIdentity(as: window)
        }
        guard remaining != heldWindowSurfaces else { return }
        heldWindowSurfaces = remaining
        heldWindowsChanged?()
    }

    /// Seeds a new consumer once. Subsequent updates ride inventory folds and follow passes.
    package func refreshHeldWindows() {
        guard let surfaces = sensing.windowSurfaces(ownedBy: session.processIDs) else { return }
        publishHeldWindows(surfaces)
    }
}
