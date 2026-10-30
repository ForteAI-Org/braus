//
//  HumanInterventionRecorder.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import CoreGraphics
import Engine
import Foundation
import InteractionListener
import InteractionObservation
import OSLog

/// HumanInterventionRecorder drains the source promptly into a bounded inbox, then resolves and
/// records each admitted event in order. Pictures have 600 ms from resolution start to arrive.
/// Events arriving during a capture skip pixels, not recording, to keep bursts draining promptly.
/// At most one native capture remains in flight, even if it ignores cancellation.
/// Stop joins the source and ordered recorder, then joins reconstruction and logs its review.
@MainActor
final class HumanInterventionRecorder {
    struct DroppedEvent: Hashable {
        let kind: InteractionEvent.Kind
        let processID: Int32
        let layer: Int?

        var diagnostic: String {
            "kind=\(kind.rawValue) pid=\(processID) layer=\(layer.map(String.init) ?? "unknown")"
        }
    }

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")
    let intervention: HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>
    private(set) var history: [HumanRecordedInteraction] = []
    private(set) var droppedOtherAppEvents = 0
    private(set) var droppedEventCounts: [DroppedEvent: Int] = [:]
    private(set) var processing: Task<Void, Never>?
    private let consumer: HumanInterventionConsumer?
    private(set) var review: HumanInterventionConsumer.Intervention.Review?
    private let source: any HumanInteractionSource
    private let reader: any HumanInteractionReading
    private let window: LentWindow
    private let onFailure: (any Error) -> Void
    private let onRecord: (Int) -> Void
    private let commandName: @MainActor (InteractionEvent) -> String?
    private var intake: Task<Void, Never>?
    private var stoppingSource: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var hasFailed = false
    private var pictureTask: Task<Void, Never>?
    private var pictureID: UUID?
    private var readyPicture: HumanPreviewControl.RetainedPicture?
    private var lastTextClick: (index: Int, windowRevision: UInt64)?

    init(
        window: LentWindow,
        source: any HumanInteractionSource,
        reader: any HumanInteractionReading,
        sceneReader: (any HumanSceneReading)? = nil,
        maximumEvents: Int = 4096,
        maximumRetainedBytes: Int = 256 * 1024 * 1024,
        pendingEvents: Int = 64,
        commandName: @escaping @MainActor (InteractionEvent) -> String? = InteractionCommandName.render,
        frontmostProcessID: @escaping @MainActor () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        isMenuBarPoint: @escaping @MainActor (CGPoint) -> Bool = { point in
            guard let primary = NSScreen.screens.first else { return false }
            return NSScreen.screens.contains { screen in
                HumanInterventionRecorder.menuBarFrame(
                    screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                    primaryScreenMaxY: primary.frame.maxY, fallbackHeight: NSStatusBar.system.thickness
                ).contains(point)
            }
        },
        onScreenWindows: @escaping @MainActor () -> [InteractionWindow] = {
            InteractionWindowReader.windows(excluding: ProcessInfo.processInfo.processIdentifier)
        },
        ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        onRecord: @escaping (Int) -> Void = { _ in },
        onFailure: @escaping (any Error) -> Void
    ) throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: maximumEvents, maximumRetainedBytes: maximumRetainedBytes)
        self.intervention = intervention
        let consumer = sceneReader.map {
            HumanInterventionConsumer(intervention: intervention, window: window, reader: $0, buttons: source.buttons)
        }
        self.consumer = consumer
        // The read that stands for "before" runs on its own task, beside the transition, never holding it.
        Task { await consumer?.beginInitialRead() }
        self.window = window
        self.source = source
        self.reader = reader
        self.onRecord = onRecord
        self.commandName = commandName
        self.onFailure = onFailure
        let inbox = AsyncStream<(event: InteractionEvent, allowsPicture: Bool, menuBar: Bool, windowRevision: UInt64)>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, pendingEvents)))
        intake = Task { [self] in
            defer { inbox.continuation.finish() }
            // Track every click, including dropped apps, without waiting for metadata or pictures.
            var lastClickWindow: InteractionWindow?
            var windowRevision: UInt64 = 0
            do {
                for try await routed in source.events {
                    // Content another process hosts inside the lent window is the lent application's.
                    let event = routed.window == nil && routed.processID != window.processID
                        && routed.processID != ownProcessID && [.click, .rightClick, .drag, .scroll].contains(routed.kind)
                        ? Self.hosted(routed, in: window.processID, windows: onScreenWindows()) ?? routed : routed
                    let click = [.click, .rightClick].contains(event.kind)
                    if click {
                        if event.window == nil || event.window?.number != lastClickWindow?.number
                            || event.window?.processID != lastClickWindow?.processID {
                            windowRevision += 1
                        }
                        lastClickWindow = event.window
                    }
                    let onMenuBar = click && isMenuBarPoint(event.point)
                    let menuBar = onMenuBar && frontmostProcessID() == window.processID
                    guard event.kind == .gap || (!onMenuBar && event.processID == window.processID) || menuBar else {
                        recordDropped(event)
                        continue
                    }
                    guard event.kind != .hover, event.kind != .focus else { continue }
                    if case .dropped = inbox.continuation.yield((event, pictureTask == nil, menuBar, windowRevision)) {
                        reportFailure(PreviewControlFailure("The temporary input queue is full. End control; recording is incomplete."))
                        break
                    }
                }
            } catch { reportFailure(error) }
        }
        processing = Task { [self] in
            for await pending in inbox.stream {
                guard let payload = await resolve(pending.event, allowsPicture: pending.allowsPicture,
                                                  menuBar: pending.menuBar, windowRevision: pending.windowRevision)
                else { continue }
                do {
                    let sequence = try await intervention.record(payload, retainedBytes: payload.retainedBytes)
                    await consumer?.enqueue(sequence, payload: payload)
                    history.append(payload)
                    if [.click, .rightClick].contains(payload.kind),
                       ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(payload.element?.role ?? "") {
                        lastTextClick = (history.count - 1, pending.windowRevision)
                    }
                    onRecord(history.count)
                } catch HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>.Failure.capacityExceeded {
                    reportFailure(PreviewControlFailure("The temporary input history is full. End control; recording is incomplete."))
                    break
                } catch {
                    reportFailure(error)
                    break
                }
            }
        }
    }

    /// Idempotent joined teardown. In-flight optional pixels are cancelled, never awaited or retained
    /// after closure; an uncooperative native capture can finish only into its discarded local result.
    func stop() async {
        if let stopping { await stopping.value; return }
        pictureTask?.cancel()
        let task = Task { [self] in
            let started = ContinuousClock.now
            await stopSource()
            await intake?.value
            await processing?.value
            Self.log.notice("human handoff: recorder and input queue stopped, elapsed \(ContinuousClock.now - started, privacy: .public)")
            pictureID = nil
            readyPicture = nil
            pictureTask?.cancel()
            pictureTask = nil
            let status = await intervention.status()
            for (index, entry) in history.enumerated() {
                Self.log.notice("#\(index + 1, privacy: .public) \(entry.diagnostic, privacy: .public)")
            }
            for (event, count) in droppedEventCounts.sorted(by: { $0.key.diagnostic < $1.key.diagnostic }) {
                Self.log.notice("dropped other-app event: \(event.diagnostic, privacy: .public) count=\(count, privacy: .public)")
            }
            let pictures = history.filter { $0.picture != nil }.count
            Self.log.notice("""
                human control recorded: entries=\(self.history.count, privacy: .public) \
                bytes=\(status.retainedBytes, privacy: .public) pictures=\(pictures, privacy: .public) \
                dropped other-app events=\(self.droppedOtherAppEvents, privacy: .public) \
                incomplete=\(self.hasFailed, privacy: .public)
                """)
            if let consumer, !hasFailed {
                do { review = try await consumer.finish() }
                catch { reportFailure(PreviewControlFailure("Reconstruction did not finish.")) }
            } else { await consumer?.cancel() }
            if consumer == nil || hasFailed { await intervention.close() }
            lastTextClick = nil
            history.removeAll()
        }
        stopping = task
        await task.value
    }

    /// Drops recording and reconstruction copies after a joined stop. The resumed turn must own
    /// any transferred review; this does not close or release the intervention's retained history.
    func releaseReview() async {
        await stop()
        review = nil
        await consumer?.releaseReview()
    }

    private func stopSource() async {
        if let stoppingSource { await stoppingSource.value; return }
        let task = Task { await source.stop() }
        stoppingSource = task
        await task.value
    }

    private func reportFailure(_ error: any Error) {
        guard !hasFailed else { return }
        hasFailed = true
        onFailure(error)
        Task { await stopSource() }
    }

    /// A pointer event routed to a process with no window under the pointer, where the lent application's window
    /// is topmost (`windows` front to back), is that application's: a remote view or extension it hosts. Windows over
    /// it at a higher layer do not count: the input passed through them (a screen recorder's overlay).
    static func hosted(_ event: InteractionEvent, in lent: Int32, windows: [InteractionWindow]) -> InteractionEvent? {
        let under = windows.filter { $0.frame.contains(event.point) }
        guard event.window == nil, event.processID > 0, event.processID != lent,
              [.click, .rightClick, .drag, .scroll].contains(event.kind),
              !under.contains(where: { $0.processID == event.processID }),
              let host = under.first(where: { $0.processID == lent }),
              !under.prefix(while: { $0 != host }).contains(where: { $0.layer <= host.layer })
        else { return nil }
        return InteractionEvent(
            kind: event.kind, timestamp: event.timestamp, startedAt: event.startedAt, endedAt: event.endedAt,
            precedingRevision: event.precedingRevision, revision: event.revision, point: event.point,
            window: host, processID: lent, deltaX: event.deltaX, deltaY: event.deltaY,
            sourceProcessID: event.sourceProcessID, sequence: event.sequence, gap: event.gap, keyCode: event.keyCode,
            modifiers: event.modifiers, endPoint: event.endPoint, clickCount: event.clickCount)
    }

    /// Converts one AppKit screen's menu strip to the listener's global top-left coordinates.
    static func menuBarFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        primaryScreenMaxY: CGFloat,
        fallbackHeight: CGFloat
    ) -> CGRect {
        let height = screenFrame.maxY - visibleFrame.maxY
        return CGRect(x: screenFrame.minX, y: primaryScreenMaxY - screenFrame.maxY,
                      width: screenFrame.width, height: height > 0 ? height : fallbackHeight)
    }

    private func recordDropped(_ event: InteractionEvent) {
        droppedOtherAppEvents += 1
        let dropped = DroppedEvent(kind: event.kind, processID: event.window?.processID ?? event.processID,
                                   layer: event.window?.layer)
        droppedEventCounts[dropped, default: 0] += 1
    }

    private func resolve(
        _ event: InteractionEvent,
        allowsPicture: Bool,
        menuBar: Bool,
        windowRevision: UInt64
    ) async -> HumanRecordedInteraction? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
        let wantsPicture = allowsPicture && [.click, .rightClick, .drag].contains(event.kind)
        var captureID = wantsPicture && !menuBar ? startPicture(for: event, deadline: deadline) : nil
        let keyboard = event.kind == .typing || event.kind == .shortcut
        let beforeSemantics = history.last?.provenance.postActionState
        let beforeRevision = source.observationRevision
        let semanticWindows = Set([window.windowNumber, event.window?.number].compactMap { $0 })
        let semantics = event.kind == .gap ? nil : await reader.semantics(
            processID: window.processID, windows: semanticWindows)
        let stateAtAction = beforeRevision == event.revision && source.observationRevision == beforeRevision
        if let semantics {
            Self.log.notice("human action semantics: source=\(event.sequence, privacy: .public) added_ms=\(semantics.interval.milliseconds, privacy: .public) elements=\(semantics.elements.count, privacy: .public) queries=\(semantics.attributeReads, privacy: .public) truncated=\(semantics.truncated, privacy: .public) revision_attested=\(stateAtAction, privacy: .public)")
        }
        var element = event.kind == .gap ? nil : await reader.element(
            at: keyboard ? nil : event.point, processID: window.processID, menuBar: menuBar)
        if menuBar, element?.role != "AXMenuBarItem" {
            recordDropped(event)
            return nil
        }
        if wantsPicture, menuBar { captureID = startPicture(for: event, deadline: deadline) }
        var inferredWindow: InteractionWindow?
        var isTargetInferredFromLastClick = false
        if keyboard, element?.role?.isEmpty != false, let lastTextClick,
           lastTextClick.windowRevision == windowRevision {
            let click = history[lastTextClick.index]
            let age = event.startedAt - click.endedAt
            if age >= 0, age <= 60 {
                element = click.element
                inferredWindow = element?.isProtected == true ? nil : click.window
                isTargetInferredFromLastClick = true
            }
        }
        let endElement: InteractionElementMetadata?
        if event.kind == .drag, let endPoint = event.endPoint {
            endElement = await reader.element(at: endPoint, processID: window.processID, menuBar: false)
        } else { endElement = nil }
        // Poll the completion slot without joining a native capture that may ignore cancellation.
        while let captureID, pictureID == captureID, pictureTask != nil,
              stopping == nil, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(until: min(deadline, .now.advanced(by: .milliseconds(10))), clock: .continuous)
        }
        let picture = captureID != nil && pictureID == captureID ? readyPicture : nil
        if pictureID == captureID {
            pictureID = nil
            readyPicture = nil
        }
        return HumanRecordedInteraction(event: event, processID: menuBar ? window.processID : event.processID,
                                        element: element, endElement: endElement,
                                        isTargetInferredFromLastClick: isTargetInferredFromLastClick,
                                        inferredWindow: inferredWindow,
                                        semantics: semantics, stateAtAction: stateAtAction, beforeSemantics: beforeSemantics,
                                        commandName: event.kind == .shortcut ? commandName(event) : nil, picture: picture)
    }

    /// Uses the event's dialog or menu only when it belongs to the lent process. Capture verifies
    /// that owner again against fresh shareable content before retaining any pixels.
    static func pictureWindow(for surface: InteractionWindow?, fallback: LentWindow) -> LentWindow {
        guard let surface, surface.processID == fallback.processID else { return fallback }
        return LentWindow(windowNumber: surface.number, processID: surface.processID, frame: surface.frame)
    }

    private func startPicture(for event: InteractionEvent, deadline: ContinuousClock.Instant) -> UUID? {
        guard pictureTask == nil, stopping == nil else { return nil }
        let id = UUID()
        pictureID = id
        let target = Self.pictureWindow(for: event.window, fallback: window)
        pictureTask = Task { [weak self, reader] in
            let picture = await reader.picture(of: target)
            guard let self else { return }
            if self.pictureID == id, ContinuousClock.now <= deadline { self.readyPicture = picture }
            self.pictureTask = nil
        }
        return id
    }
}
