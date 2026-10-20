//
//  RoomRenderQueue.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit

/// RoomRenderQueue starts room submissions at least one 60 Hz frame apart, and admits the next room
/// only after the previous one's GPU completion and pulse installation. It owns weak requests, not
/// views, and prioritizes visible rooms and uniform changes. No timer runs when the queue is empty.
/// Rooms that settle after a resize are previewed together first, outside the one-at-a-time order.
@MainActor
final class RoomRenderQueue {
    static let shared = RoomRenderQueue()

    private var pending: [Request] = []
    private var wake   : Task<Void, Never>?

    private var isRendering = false

    /// When the last submission started, which the next one keeps a frame away from.
    private var lastStart: ContinuousClock.Instant?

    private static let frameInterval = Duration.milliseconds(17)

    /// Rooms whose size settled in the last few milliseconds, previewed together.
    private var previews: [Request] = []
    private var previewWake: Task<Void, Never>?

    /// Long enough for the rooms one layout pass resized, whose settle timers end a moment apart,
    /// to be previewed in one transaction.
    private static let previewGathering = Duration.milliseconds(4)

    private init() {}

    func enqueue(_ view: RoomLightView) {
        pending.removeAll { $0.view == nil }
        guard !pending.contains(where: { $0.view === view }) else { return }
        pending.append(Request(view: view))
        scheduleNext()
    }

    func remove(_ view: RoomLightView) {
        pending.removeAll { $0.view == nil || $0.view === view }
        previews.removeAll { $0.view == nil || $0.view === view }
    }

    /// Previews `view` with the other rooms that settle within a few milliseconds, all in one Core
    /// Animation transaction, so the new images and their framing reach the screen together.
    func preview(_ view: RoomLightView) {
        guard !previews.contains(where: { $0.view === view }) else { return }
        previews.append(Request(view: view))
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

    /// Releases the global slot after the command buffer and its image readback have finished.
    func didFinishRender() {
        isRendering = false
        scheduleNext()
    }

    private func scheduleNext() {
        guard !isRendering, wake == nil, !pending.isEmpty else { return }
        let elapsed = lastStart.map { ContinuousClock.now - $0 } ?? Self.frameInterval
        let delay   = max(.zero, Self.frameInterval - elapsed)
        wake = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.wake = nil
            self.renderNext()
        }
    }

    private func renderNext() {
        let ready = pending.compactMap { $0.view }.filter { $0.canRenderQueuedFrame }
        pending.removeAll()
        let ordered = ready.sorted(by: Self.precedes)
        guard let view = ordered.first else { return }
        pending = ordered.dropFirst().map { Request(view: $0) }
        isRendering = true
        lastStart   = .now
        if !view.renderQueuedFrame() {
            didFinishRender()
        }
    }

    /// Orders visible rooms first, with selection/status changes ahead of settled geometry.
    private static func precedes(
        _ first : RoomLightView,
        _ second: RoomLightView
    ) -> Bool {
        let firstVisible  = !first.visibleRect.isEmpty && !first.isHiddenOrHasHiddenAncestor
        let secondVisible = !second.visibleRect.isEmpty && !second.isHiddenOrHasHiddenAncestor
        if firstVisible != secondVisible { return firstVisible }
        if first.hasPendingUniforms != second.hasPendingUniforms { return first.hasPendingUniforms }
        return first.convert(
            first.bounds,
            to: nil
        ).maxY > second.convert(
            second.bounds,
            to: nil
        ).maxY
    }

    /// Request borrows a room until it is detached, superseded, or selected for rendering.
    private struct Request {
        weak var view: RoomLightView?
    }
}
