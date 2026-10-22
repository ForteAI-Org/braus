//
//  RoomRenderQueue.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit

/// RoomRenderQueue submits ready precomputed rooms together in one transaction, without waiting for
/// another room's GPU completion or pulse readback. Ray-traced refinements retain one global slot
/// and at least one 60 Hz frame between starts. It owns weak requests and prioritizes visible rooms
/// and uniform changes. No timer runs when idle. Resize previews are gathered separately.
///
/// Live frames, a room's single precomputed frame while its size or uniforms change, bypass the
/// order too: each room draws one at once, in the pass that changed it, unless it drew one less than a
/// display frame ago, when it waits here for the rest of that frame; a room with one in flight asks
/// again when it completes.
@MainActor
final class RoomRenderQueue {
    static let shared = RoomRenderQueue()

    private var pending: [Request] = []
    private var hasScheduledRender = false

    private let now: @MainActor () -> ContinuousClock.Instant
    private let schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    private var isRefining = false

    /// When the last ray-traced submission started, which the next one keeps a frame away from.
    private var lastStart: ContinuousClock.Instant?

    private static let frameInterval = Duration.milliseconds(17)

    /// Rooms whose size settled in the last few milliseconds, previewed together.
    private var previews: [ViewRequest] = []
    private var previewWake: Task<Void, Never>?

    /// Long enough for the rooms one layout pass resized, whose settle timers end a moment apart,
    /// to be previewed in one transaction.
    private static let previewGathering = Duration.milliseconds(4)

    /// Rooms whose next live frame waits for a display frame to pass since their last.
    private var liveRooms: [ViewRequest] = []
    private var liveWake : Task<Void, Never>?

    /// Supplies monotonic time and a one-shot wake. The wake must defer its action, even at zero delay,
    /// so rooms enqueued in the same main-actor turn are gathered before any submission begins.
    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = { delay, action in
            Task { @MainActor in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                action()
            }
        }
    ) {
        self.now = now
        self.schedule = schedule
    }

    /// Draws `view`'s live frame now when it may, or once a display frame has passed since its last.
    func live(_ view: RoomLightView) {
        guard let delay = view.liveFrameDelay else { return }
        guard delay > 0 else {
            view.renderLiveFrame()
            return
        }
        if !liveRooms.contains(where: { $0.view === view }) {
            liveRooms.append(ViewRequest(view: view))
        }
        guard liveWake == nil else { return }
        liveWake = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.liveWake = nil
            let views = self.liveRooms.compactMap(\.view)
            self.liveRooms.removeAll()
            for view in views {
                self.live(view)
            }
        }
    }

    func enqueue(_ view: any RoomRenderTarget) {
        pending.removeAll { $0.view == nil }
        guard !pending.contains(where: { $0.view === view }) else { return }
        pending.append(Request(view: view))
        scheduleNext()
    }

    func remove(_ view: any RoomRenderTarget) {
        pending.removeAll { $0.view == nil || $0.view === view }
        previews.removeAll { $0.view == nil || $0.view === view }
        liveRooms.removeAll { $0.view == nil || $0.view === view }
    }

    /// Previews `view` with the other rooms that settle within a few milliseconds, all in one Core
    /// Animation transaction, so the new images and their framing reach the screen together.
    func preview(_ view: RoomLightView) {
        guard !previews.contains(where: { $0.view === view }) else { return }
        previews.append(ViewRequest(view: view))
        guard previewWake == nil else { return }
        previewWake = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.previewGathering)
            guard let self else { return }
            self.previewWake = nil
            let views = self.previews.compactMap(\.view)
            self.previews.removeAll()
            CATransaction.begin()
            for view in views {
                view.renderPreview()
            }
            CATransaction.commit()
        }
    }

    /// Releases the ray-tracing slot after its command buffer and image readback have finished.
    /// Precomputed completions never release a slot owned by a ray-traced room.
    func didFinishRender(for path: LightingPath?) {
        guard path == .rayTraced else { return }
        isRefining = false
        scheduleNext()
    }

    private func scheduleNext() {
        guard !hasScheduledRender, !pending.isEmpty else { return }
        let hasPrecomputed = pending.contains {
            $0.view?.path == .precomputed && $0.view?.canRenderQueuedFrame == true
        }
        guard hasPrecomputed || !isRefining else { return }
        let elapsed = lastStart.map { now() - $0 } ?? Self.frameInterval
        let delay   = hasPrecomputed ? .zero : max(.zero, Self.frameInterval - elapsed)
        hasScheduledRender = true
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.hasScheduledRender = false
            self.renderNext()
        }
    }

    private func renderNext() {
        let ready = pending.compactMap { $0.view }.filter { $0.canRenderQueuedFrame }
        pending.removeAll()
        let ordered = ready.sorted(by: Self.precedes)
        CATransaction.begin()
        for view in ordered {
            if view.path == .precomputed {
                _ = view.renderQueuedFrame()
                continue
            }
            let elapsed = lastStart.map { now() - $0 } ?? Self.frameInterval
            guard !isRefining, elapsed >= Self.frameInterval else {
                pending.append(Request(view: view))
                continue
            }
            isRefining = true
            lastStart   = now()
            if !view.renderQueuedFrame() {
                isRefining = false
            }
        }
        CATransaction.commit()
        scheduleNext()
    }

    /// Orders visible rooms first, with selection/status changes ahead of settled geometry.
    private static func precedes(
        _ first : any RoomRenderTarget,
        _ second: any RoomRenderTarget
    ) -> Bool {
        let firstPriority  = first.renderPriority
        let secondPriority = second.renderPriority
        if firstPriority.visible != secondPriority.visible { return firstPriority.visible }
        if firstPriority.uniforms != secondPriority.uniforms { return firstPriority.uniforms }
        return firstPriority.top > secondPriority.top
    }

    /// Request borrows a room until it is detached, superseded, or selected for rendering.
    private struct Request {
        weak var view: (any RoomRenderTarget)?
    }

    /// ViewRequest borrows a room for its precomputed preview or live frame.
    private struct ViewRequest {
        weak var view: RoomLightView?
    }
}
