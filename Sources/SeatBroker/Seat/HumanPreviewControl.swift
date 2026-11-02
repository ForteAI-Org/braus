//
//  HumanPreviewControl.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/10/2026.
//

import AppKit
import Engine
import ImageIO
import UniformTypeIdentifiers
import InteractionListener
import Observation
import OSLog
import SeatCore
import SeatInput
import SeatSession

/// HumanPreviewControl owns an intervention that pauses agent Commands, retains the lease
/// and suspends the host. The preview continues showing frames without forwarding input.
/// Yes hands a reviewed summary to a new turn; End Control closes and leaves the app with the person.
@MainActor
@Observable
public final class HumanPreviewControl {
    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")
    public private(set) var status = "The preview is for watching. Take control to pause the worker."
    public private(set) var hasStarted = false
    public private(set) var isFinished = false
    public private(set) var isFinishing = false
    public private(set) var isBlocked = false
    public private(set) var eventCount = 0
    /// The lent application's frontmost window once lending succeeded, until the episode ends.
    public private(set) var lentWindow: LentWindow?
    /// Every confirmed placement from the lend, cleared when the episode ends.
    public private(set) var lentWindows: [LentWindow] = []
    /// Receives every planned frame before any window moves, within the same 2.5 s budget as willLend.
    @ObservationIgnored public var willLendAll: (@MainActor ([LentWindow]) async -> Void)?
    /// Receives current, identity-verified frames before take-back moves any window; waits at most 0.5 s.
    @ObservationIgnored public var willTakeBack: (@MainActor ([LentWindow]) async -> Void)?
    /// Runs right before the lent windows move, with the front window and its planned frame, so a presentation
    /// can lead into the move. Lending waits for it at most `willLendLimit`.
    @ObservationIgnored public var willLend: (@MainActor (LentWindow) async -> Void)?
    nonisolated static let willLendLimit: Duration = .milliseconds(2500)
    /// Where the lent front window should land, centered, in window-server space; nil centers the windows on the
    /// screen. Read when the lend starts.
    @ObservationIgnored public var lendingAnchor: CGRect?
    /// Per-window destinations in WindowServer space, read after the worker drains, when lending starts.
    /// Origins are clamped to the person's visible frame without resizing. Missing or nonfinite origins
    /// use the relative layout and lendingAnchor; destination sizes are ignored.
    @ObservationIgnored
    public var lendingFrames: [Int: CGRect] = [:]
    /// Set when the application could not be lent, so a waiting presentation can end without reading `status`.
    public private(set) var lendingRefused = false
    /// Receives what each listener event says about the person while the application is lent, and how many
    /// seconds ago it ended, for the activity policy (`LendActivity`). Called on the main actor per event.
    @ObservationIgnored public var onActivity: (@MainActor (LendActivity.Evidence, Double) -> Void)?

    @ObservationIgnored private let session: BrokeredAutomationSession
    @ObservationIgnored private let sessionID: UUID?
    @ObservationIgnored private let suspend: () throws -> Void
    @ObservationIgnored private let waitForAgent: () async throws -> Void
    @ObservationIgnored private let endAgent: () -> Void
    @ObservationIgnored private let waitForWorker: () async -> Void
    @ObservationIgnored private let withholding: (String) -> String
    @ObservationIgnored private let resumeAgent: ((String, @escaping @MainActor () async throws -> Void) async throws -> Void)?
    @ObservationIgnored private var seat: AgentSeat?
    @ObservationIgnored private var token: InputCommandGate.HumanInput?
    @ObservationIgnored private var leaseToken: UUID?
    @ObservationIgnored private var beginning: Task<Void, Never>?
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var closingRequested = false
    @ObservationIgnored private var releasingFailedSession = false
    @ObservationIgnored private var endedWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var recorder: HumanInterventionRecorder?
    @ObservationIgnored private let interactionSource: () throws -> any HumanInteractionSource
    @ObservationIgnored private let interactionReader: any HumanInteractionReading
    @ObservationIgnored private let sceneReader: (any HumanSceneReading)?
    var history: [HumanRecordedInteraction] { recorder?.history ?? [] }

    /// RetainedPicture keeps immutable HEIC bytes at most 1920 by 1080, encoded off the main thread.
    /// A prior Pro Tools frame measured 79 KB at 1080p and 119 KB at 1261 by 827, with 8 to 11 ms
    /// encoding CPU. Native capture latency and the new recorder are not yet measured live.
    nonisolated struct RetainedPicture: Sendable {
        let heic: Data
        let pixelSize: CGSize
        let encodedSize: CGSize
    }

    init(
        session: BrokeredAutomationSession,
        suspend: @escaping () throws -> Void,
        waitForAgent: @escaping () async throws -> Void,
        endAgent: @escaping () -> Void,
        waitForWorker: @escaping () async -> Void = {},
        withholding: @escaping (String) -> String = { $0 },
        resumeAgent: ((String, @escaping @MainActor () async throws -> Void) async throws -> Void)? = nil,
        interactionSource: @escaping () throws -> any HumanInteractionSource = { try PassiveInteractionListener(hover: true) },
        interactionReader: any HumanInteractionReading = NativeHumanInteractionReader(),
        sceneReader: (any HumanSceneReading)? = NativeHumanSceneReader()
    ) {
        self.session = session
        self.sessionID = session.id
        self.suspend = suspend
        self.waitForAgent = waitForAgent
        self.endAgent = endAgent
        self.waitForWorker = waitForWorker
        self.withholding = withholding
        self.resumeAgent = resumeAgent
        self.interactionSource = interactionSource
        self.interactionReader = interactionReader
        self.sceneReader = sceneReader
    }

    /// Takes control for the person: suspends the worker, waits for its current action, then lends the held
    /// application to `screen`, the screen the person works on. `finish()` leaves it there and closes the session.
    public func takeControl(on screen: NSScreen?) {
        guard !hasStarted, !isFinished, !isFinishing else { return }
        do {
            guard let screen else { throw PreviewControlFailure("No physical display is available for control.") }
            try begin(lendingOn: screen)
        } catch { block(error) }
    }

    /// Starts the episode; with a screen, lends the application there once the worker has drained.
    func begin(lendingOn screen: NSScreen? = nil) throws {
        guard !hasStarted, !isFinished, !isFinishing else { return }
        guard sessionID != nil, session.id == sessionID, let seat = session.heldSeat else {
            throw SeatBrokerError.sessionClosed
        }
        self.seat = seat
        token = try seat.beginHumanInput()
        hasStarted = true
        leaseToken = try session.retainForHumanIntervention()
        try suspend()
        status = "Waiting for the current action to finish…"
        HumanInterventionEmbeddings.prepareLocal()
        let pressed = ContinuousClock.now
        Self.log.notice("take control: waiting for the worker's current action")
        beginning = Task { [self] in
            do {
                try await waitForAgent()
                Self.log.notice("take control: the current action drained after \(ContinuousClock.now - pressed, privacy: .public)")
                guard !isFinishing, !isFinished, session.id == sessionID else { return }
                guard let screen else {
                    status = "The worker is paused. The preview is for watching only."
                    return
                }
                let report = try await session.lendApplication(
                    on: screen,
                    around: lendingAnchor,
                    lendingFrames: lendingFrames,
                    willMoveAll: { [weak self] windows in
                        let front = windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                        await self?.prepareLend(windows, frontWindowNumber: front?.windowNumber)
                    }
                )
                Self.log.notice("take control: lent after \(ContinuousClock.now - pressed, privacy: .public)")
                didLend(report)
            } catch let refusal as ApplicationLendingRefusal {
                lendingWasRefused(refusal)
            } catch {
                block(error)
            }
        }
    }

    func prepareLend(_ windows: [WindowReference], frontWindowNumber: Int?) async {
        let planned = windows.map(LentWindow.init)
        let all = willLendAll
        let legacy = willLend
        guard all != nil || legacy != nil else { return }
        await Self.waiting(within: Self.willLendLimit) {
            async let allFinished: Void? = all?(planned)
            async let frontFinished: Void? = planned.first(where: { $0.windowNumber == frontWindowNumber }).map { window in
                Task { @MainActor in await legacy?(window) }
            }?.value
            _ = await (allFinished, frontFinished)
        }
    }

    func prepareTakeBack(_ windows: [WindowReference]) async {
        guard let willTakeBack else { return }
        let current = windows.map(LentWindow.init)
        await Self.waiting(within: .milliseconds(500)) { await willTakeBack(current) }
    }

    /// Bounds presentation waits even when a hook ignores cancellation. Late hooks convey no authority.
    static func waiting(within limit: Duration, operation: @escaping @MainActor () async -> Void) async {
        let (ended, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { @MainActor in
            await operation()
            signal.yield()
        }
        let timeout = Task {
            try? await Task.sleep(for: limit)
            signal.yield()
        }
        var iterator = ended.makeAsyncIterator()
        _ = await iterator.next()
        timeout.cancel()
        signal.finish()
    }

    /// Reports placement and activation independently while retaining the person's control.
    func didLend(_ report: ApplicationLendingReport) {
        guard !isFinished, !isFinishing, !isBlocked, recorder == nil else { return }
        lentWindows = report.moves.map { LentWindow(windowNumber: $0.window.windowNumber, processID: $0.window.processID, frame: $0.after) }
        lentWindow = LentWindow.front(of: report, target: seat?.currentTarget?.reference.windowNumber)
        status = report.failures.isEmpty
            ? "Use the application on your screen. Choose End Control when finished."
            : "You still have control. " + report.failures.map(\.reason).joined(separator: " ")
                + " Choose End Control when finished."
        guard let lentWindow else { return }
        let lent = lentWindow.processID
        do {
            let source = ObservedInteractionSource(try interactionSource()) { [weak self] event in
                guard let onActivity = self?.onActivity else { return }
                // Content another process hosts inside the lent window is work in the lent application.
                let seen = event.window == nil && event.processID > 0 && event.processID != lent
                    ? HumanInterventionRecorder.hosted(
                        event,
                        in     : lent,
                        windows: InteractionWindowReader.windows(excluding: ProcessInfo.processInfo.processIdentifier)
                    ) ?? event
                    : event
                onActivity(LendActivity.Evidence(seen, lent: lent), max(0, ProcessInfo.processInfo.systemUptime - event.endedAt))
            }
            recorder = try HumanInterventionRecorder(
                window: lentWindow,
                source: source,
                reader: interactionReader,
                sceneReader: sceneReader,
                onRecord: { [weak self] count in self?.eventCount = count },
                onFailure: { [weak self] error in self?.block(error) }
            )
        } catch { block(error) }
    }

    func lendingWasRefused(_ refusal: ApplicationLendingRefusal) {
        lendingRefused = true
        status = refusal.localizedDescription + " The worker remains paused. Choose End Control when finished."
    }

    /// The largest picture the history keeps: a 1080p screen.
    nonisolated static let retainedPictureBounds = CGSize(width: 1920, height: 1080)

    /// `captured` as HEIC at quality 0.8, scaled down to fit `retainedPictureBounds` and never up, encoded on the
    /// concurrent pool. Nil when it cannot be encoded: the entry then keeps its place in the order with no
    /// picture. Only the immutable encoding is retained and charged to the episode.
    @concurrent
    static func encoded(_ captured: CGImage) async -> (data: Data, size: CGSize)? {
        guard let image = scaledToFit(captured, retainedPictureBounds) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, CGSize(width: image.width, height: image.height))
    }

    /// `image` scaled down to fit `bounds`, keeping its proportions; `image` itself when it already fits.
    nonisolated static func scaledToFit(_ image: CGImage, _ bounds: CGSize) -> CGImage? {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height), 1)
        guard scale < 1 else { return image }
        let width = Int((CGFloat(image.width) * scale).rounded()), height = Int((CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Reports an episode failure while keeping End Control available.
    public func block(_ error: any Error, caller: String = #fileID, line: Int = #line) {
        Self.log.notice("""
            human control blocked by \(caller, privacy: .public):\(line, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
        guard !isFinished, !isFinishing else { return }
        isBlocked = true
        Task { await recorder?.stop() }
        status = "Control paused: \(error.localizedDescription) End control to return the application."
    }

    /// Ends control once. Yes supplies a reviewed new turn; End Control closes and leaves windows.
    /// `automatically` says why control ended without the person handing it back, for the report's first line.
    public func finish(
        _ end: HumanControlEnd = .closingSession,
        automatically reason: String? = nil,
        caller: String = #fileID,
        line: Int = #line
    ) async {
        Self.log.notice("human control finishing, asked by \(caller, privacy: .public):\(line, privacy: .public)\(reason.map { ", ended automatically: " + $0 } ?? "", privacy: .public)")
        guard !isFinished else { return }
        if end == .closingSession, !closingRequested {
            closingRequested = true
            if finishing != nil { endAgent() }
        }
        if let finishing {
            await finishing.value
            return
        }
        isFinishing = true
        let task = Task { [self] in
            beginning?.cancel()
            await beginning?.value
            let recorder = self.recorder
            let leaseToken = self.leaseToken
            var needsSessionClose = false
            var digest: HumanInterventionSummary.Digest?
            let embeddings = HumanInterventionEmbeddings.local()
            let completion = HumanControlCompletion(
                takeBack: {
                    do {
                        let report = try await self.session.takeBackApplication()
                        needsSessionClose = report.applicationVanished
                        return report.applicationVanished ? "The lent application is no longer running." : nil
                    } catch {
                        needsSessionClose = true
                        throw error
                    }
                },
                review: { note in
                    await recorder?.stop()
                    guard let review = recorder?.review else {
                        return "Human control ended. Recording is incomplete; inspect the current state.\n" + (note ?? "")
                    }
                    let preparationStarted = ContinuousClock.now
                    let preparedEvidence = await HumanInterventionSummary.prepare(review)
                    Self.log.notice("human digest evidence: \(ContinuousClock.now - preparationStarted, privacy: .public)")
                    let withholdingStarted = ContinuousClock.now
                    let evidence = preparedEvidence.withholding(self.withholding)
                    Self.log.notice("human digest withholding: \(ContinuousClock.now - withholdingStarted, privacy: .public)")
                    let vectors = await embeddings.vectors(
                        actions: evidence.embeddingActions,
                        effects: evidence.embeddingEffects
                    )
                    Self.log.notice("human digest linking: \(vectors.mode, privacy: .public), \(vectors.elapsedMilliseconds, privacy: .public) ms, \(evidence.threadTexts.count, privacy: .public) eligible threads\(vectors.reason.map { ", " + $0 } ?? "", privacy: .public)")
                    let renderingStarted = ContinuousClock.now
                    let prepared = await HumanInterventionSummary.render(
                        evidence, note: note.map(self.withholding), actionVectors: evidence.threadVectors(vectors),
                        embeddingModel: vectors.model
                    )
                    Self.log.notice("human digest rendering: \(ContinuousClock.now - renderingStarted, privacy: .public)")
                    #if DEBUG
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let directory = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/Braus/Runs")
                        .appendingPathComponent("handoff-\(stamp)-\(UUID().uuidString)")
                    do {
                        try await HumanInterventionReplay.write(review, embeddingModel: vectors.model, to: directory)
                        Self.log.notice("human review replay saved: \(directory.path, privacy: .public)")
                    } catch {
                        Self.log.error("human review replay failed: \(String(describing: error), privacy: .public)")
                    }
                    #endif
                    digest = prepared
                    return prepared.text
                },
                drain: { await self.waitForWorker() },
                resume: { summary in
                    guard !self.closingRequested else { throw CancellationError() }
                    guard let resumeAgent = self.resumeAgent else {
                        throw PreviewControlFailure("No worker is available to resume this intervention.")
                    }
                    try await resumeAgent(summary) {
                        guard !self.closingRequested else { throw CancellationError() }
                        if let recorder, let review = recorder.review {
                            try await recorder.intervention.resolve(review.revision, as: .resume)
                        }
                        if needsSessionClose {
                            // A failed placement keeps Driver's gate closed until normal session teardown.
                            self.releasingFailedSession = true
                            await self.session.close()
                            self.releasingFailedSession = false
                        } else if let leaseToken {
                            let details: HumanInterventionDetails?
                            if let recorder, let review = recorder.review, let digest {
                                details = HumanInterventionDetails(
                                    review: review, digest: digest, intervention: recorder.intervention,
                                    withholding: self.withholding
                                )
                            } else { details = nil }
                            try await self.session.completeHumanIntervention(leaseToken, details: details)
                        }
                        await recorder?.releaseReview()
                        digest = nil
                        guard !self.closingRequested else { throw CancellationError() }
                        self.sessionDidClose()
                        self.status = "The worker is reviewing your changes."
                    }
                    guard !self.closingRequested else { throw CancellationError() }
                },
                close: {
                    await recorder?.stop()
                    await recorder?.intervention.close()
                    await recorder?.releaseReview()
                    if self.session.id == self.sessionID {
                        await self.seat?.abandonHumanInput(reason: .sessionClosed)
                    }
                    if self.hasStarted {
                        self.endAgent()
                        if self.session.id == self.sessionID { await self.session.close() }
                    }
                    self.sessionDidClose()
                },
                ending: reason.map { "Ended automatically: \($0)." }
            )
            do { try await completion.run(end) }
            catch {
                let wasStopped = closingRequested
                endAgent()
                await session.close()
                sessionDidClose()
                if !wasStopped { status = "Control ended, but the worker could not resume: \(error.localizedDescription)" }
            }
        }
        finishing = task
        await task.value
    }

    /// Explicit session closure wins over an episode, including closure caused by a real tool failure.
    func sessionWillClose() {
        if !releasingFailedSession { closingRequested = true }
        isFinishing = true
        lentWindow = nil
        lentWindows = []
    }

    func drainForSessionClose() async {
        beginning?.cancel()
        await beginning?.value
        await recorder?.stop()
        await recorder?.intervention.close()
        await recorder?.releaseReview()
        await seat?.abandonHumanInput(reason: .sessionClosed)
    }

    func sessionDidClose() {
        lentWindow = nil
        lentWindows = []
        recorder = nil
        token = nil
        leaseToken = nil
        seat = nil
        isFinished = true
        isFinishing = false
        status = "Control ended. Send a new instruction to continue."
        for waiter in endedWaiters { waiter.resume() }
        endedWaiters.removeAll()
    }

    public func waitUntilFinished() async {
        guard !isFinished else { return }
        await withCheckedContinuation { endedWaiters.append($0) }
    }

}

/// HumanControlEnd: closing leaves lent windows where the person has them (the lease end abandons lending,
/// with no double move); resuming the worker takes them back first.
public enum HumanControlEnd {
    case closingSession
    case resumingWorker

    var takesBackApplication: Bool { self == .resumingWorker }
}

/// LentWindow describes a planned, confirmed or current placement on the person's screen.
nonisolated public struct LentWindow: Sendable, Equatable {
    public let windowNumber: Int
    public let processID: Int32
    /// In window-server space: y down from the top of the menu-bar screen.
    public let frame: CGRect

    init(windowNumber: Int, processID: Int32, frame: CGRect) {
        self.windowNumber = windowNumber
        self.processID = processID
        self.frame = frame
    }

    init(_ window: WindowReference) {
        self.init(windowNumber: window.windowNumber, processID: window.processID, frame: window.frame)
    }

    /// The activation window, falling back to the target or first move for reports without activation.
    static func front(of report: ApplicationLendingReport, target: Int?) -> LentWindow? {
        guard let move = report.moves.first(where: { $0.window == report.activationWindow })
            ?? report.moves.first(where: { $0.window.windowNumber == target }) ?? report.moves.first
        else { return nil }
        return LentWindow(windowNumber: move.window.windowNumber, processID: move.window.processID, frame: move.after)
    }
}

/// PreviewControlFailure reports an episode or retained-history failure.
struct PreviewControlFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
