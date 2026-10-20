//
//  RoomRenderQueue.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit

/// RoomRenderQueue spaces room submissions by at least one 60 Hz frame, including GPU completion
/// and pulse installation before admitting another room. It owns weak requests, not views, and
/// prioritizes visible rooms and uniform changes. No timer runs when the queue is empty.
@MainActor
final class RoomRenderQueue {
    static let shared = RoomRenderQueue()

    private var pending: [Request] = []
    private var wake   : Task<Void, Never>?

    private var isRendering = false

    private static let frameInterval = Duration.milliseconds(17)

    private init() {}

    func enqueue(_ view: RoomLightView) {
        pending.removeAll { $0.view == nil }
        guard !pending.contains(where: { $0.view === view }) else { return }
        pending.append(Request(view: view))
        scheduleNext()
    }

    func remove(_ view: RoomLightView) {
        pending.removeAll { $0.view == nil || $0.view === view }
    }

    /// Releases the global slot after the command buffer and its image readback have finished.
    func didFinishRender() {
        isRendering = false
        scheduleNext()
    }

    private func scheduleNext() {
        guard !isRendering, wake == nil, !pending.isEmpty else { return }
        wake = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.frameInterval)
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
