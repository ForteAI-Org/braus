//
//  HumanInterventionConsumer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import CoreGraphics
import Engine
import Foundation
import InteractionListener
import InteractionObservation
import Memory
import OSLog
import PerceptionCore

/// HumanInterventionConsumer owns one background task and a latest-pending state request.
/// Started reads keep their capture-time action even when input arrives during perception.
/// HumanIntervention owns the ordered findings; coalesced actions complete their leases as covered.
/// Stop input before finish; cancellation blocks leased work and never creates a review.
actor HumanInterventionConsumer {
    typealias Intervention = HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")
    private let intervention: Intervention
    private let window: LentWindow
    private let reader: any HumanSceneReading
    private let buttons: InteractionButtonState
    private var initialScenes: [Int: SceneSnapshot]
    private let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var task: Task<Intervention.Review, any Error>?
    private var latest: (sequence: UInt64, payload: HumanRecordedInteraction)?
    private var inputEnded = false
    private var reviewReleased = false
    private var leased: Intervention.WorkItem?
    // Only text-only action scenes become baselines; the full final state stays separate.
    private var textBaselines: [Int: (scene: SceneSnapshot, sequence: UInt64)] = [:]
    private var reads = 0
    private var covered = 0
    private var superseded = 0
    private var inputDuringRead = 0
    private var failures = 0
    private var rawBytes = 0
    private var compressedBytes = 0
    /// The structural read taken when control passed, on its own task beside the transition; nil until it ends, and
    /// for good when input arrived during it (a mix of before and after is no "before").
    private var initialStructure: InteractionStructuralRead?
    private var initialRead: Task<Void, Never>?
    /// Structural reads taken when the person paused after a read, and the one pending.
    private var settled: [HumanReadProvenance.Settled] = []
    private var settling: Task<Void, Never>?

    /// How long the person must pause after a read before the window is read again: a pane still appearing at the
    /// read after its button (System Settings' Displays pane) is drawn by then.
    static let settlePause: Duration = .milliseconds(400)

    /// Uses supplied pre-control scenes when available; otherwise the review uses each window's first keyframe.
    init(
        intervention: Intervention,
        window: LentWindow,
        reader: any HumanSceneReading,
        buttons: InteractionButtonState,
        initialScenes: [Int: SceneSnapshot] = [:]
    ) {
        self.intervention = intervention
        self.window = window
        self.reader = reader
        self.buttons = buttons
        self.initialScenes = initialScenes.mapValues(Self.minimized)
    }

    func enqueue(_ sequence: UInt64, payload: HumanRecordedInteraction) {
        guard !inputEnded, !reviewReleased else { return }
        if sequence > (latest?.sequence ?? 0) { latest = (sequence, payload) }
        settling?.cancel()
        settling = nil
        wake.continuation.yield(())
        start()
    }

    /// Reads the lent process whole while the transition runs; called once, as control passes to the person.
    func beginInitialRead() {
        guard initialRead == nil, !inputEnded else { return }
        initialRead = Task {
            let read = await reader.structure(processID: window.processID,
                                              seconds: NativeHumanSceneReader.longStructureSeconds)
            keepInitial(read)
        }
    }

    private func keepInitial(_ read: InteractionStructuralRead) {
        // Input during the read leaves a mix of before and after: no read stands for "before" then.
        guard latest == nil, !read.windows.isEmpty else {
            Self.log.notice("human initial structure: not kept (input during the read \(self.latest != nil, privacy: .public), windows \(read.windows.count, privacy: .public))")
            return
        }
        initialStructure = read
        Self.log.notice("human initial structure: ms=\(read.interval.milliseconds, privacy: .public) windows=\(read.windows.count, privacy: .public) fields=\(read.windows.flatMap(\.fields).count, privacy: .public) members=\(read.windows.flatMap(\.collections).reduce(0) { $0 + $1.members.count }, privacy: .public)")
    }

    /// After the read of `sequence`, once the person pauses, reads the windows again: what a pane drew after that read.
    private func settle(after sequence: UInt64) {
        settling?.cancel()
        settling = Task {
            do { try await Task.sleep(for: Self.settlePause) } catch { return }
            guard isQuiet(since: sequence) else { return }
            let read = await reader.structure(processID: window.processID,
                                              seconds: NativeHumanSceneReader.settledStructureSeconds)
            keepSettled(read, after: sequence)
        }
    }

    private func isQuiet(since sequence: UInt64) -> Bool {
        !Task.isCancelled && !inputEnded && latest?.sequence == sequence && buttons.snapshot().processID != window.processID
    }

    private func keepSettled(_ read: InteractionStructuralRead, after sequence: UInt64) {
        guard isQuiet(since: sequence), !read.windows.isEmpty else { return }
        settled.removeAll { $0.sequence == sequence }
        settled.append(.init(sequence: sequence, structure: read))
        Self.log.notice("human settled structure: after #\(sequence, privacy: .public) ms=\(read.interval.milliseconds, privacy: .public) windows=\(read.windows.count, privacy: .public)")
    }

    /// Drains pending leases and always reads the current front surfaces after the input boundary.
    /// Repeated finish calls join the same task until releaseReview permanently ends access.
    func finish() async throws -> Intervention.Review {
        guard !reviewReleased else { throw Intervention.Failure.invalidPhase }
        inputEnded = true
        wake.continuation.yield(())
        start()
        guard let task else { preconditionFailure("The consumer task was not started") }
        let review = try await task.value
        guard !reviewReleased else { throw Intervention.Failure.invalidPhase }
        return review
    }

    /// Releases this consumer's review and scene copies after input has ended and reconstruction
    /// has joined. The transferred review and intervention remain owned by the resumed turn.
    func releaseReview() async {
        guard inputEnded else { return }
        reviewReleased = true
        _ = await task?.result
        task = nil
        latest = nil
        leased = nil
        textBaselines.removeAll()
        initialScenes.removeAll()
        initialStructure = nil
        settled.removeAll()
    }

    func cancel() async {
        task?.cancel()
        initialRead?.cancel()
        settling?.cancel()
        inputEnded = true
        wake.continuation.finish()
        do { _ = try await task?.value }
        catch {
            // Cancellation abandons reconstruction; the owner closes the episode.
            Self.log.notice("human reconstruction cancelled")
        }
    }

    private func start() {
        guard task == nil, !reviewReleased else { return }
        task = Task { try await run() }
    }

    private func run() async throws -> Intervention.Review {
        defer {
            textBaselines.removeAll()
            latest = nil
            wake.continuation.finish()
        }
        do {
            for await _ in wake.stream {
                try Task.checkCancellation()
                while let item = await intervention.next() {
                    leased = item
                    try await consume(item)
                    leased = nil
                }
                if inputEnded { return try await review() }
            }
            throw CancellationError()
        } catch {
            if let leased {
                do { try await intervention.fail(leased) }
                catch { Self.log.notice("human reconstruction lease already invalidated") }
            }
            throw error
        }
    }

    private func waitForRelease() async throws {
        while buttons.snapshot().processID == window.processID {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }

    private func listedWindows(timing: NativeHumanSceneReader.Timing) async throws -> [InteractionWindow] {
        let started = ContinuousClock.now
        defer { timing.record(.windows, since: started) }
        return try await reader.windows(processID: window.processID)
    }

    private func consume(_ item: Intervention.WorkItem) async throws {
        while true {
            try await waitForRelease()
            let target = latest.flatMap { $0.sequence >= item.sequence ? $0 : nil }
                ?? (sequence: item.sequence, payload: item.payload)
            var surface = target.payload.window.flatMap { $0.processID == window.processID ? $0 : nil }
                ?? InteractionWindow(processID: window.processID, number: window.windowNumber,
                                     title: nil, layer: 0, frame: window.frame)
            let stamp = buttons.snapshot()
            if stamp.processID == window.processID { continue }
            let started = ContinuousClock.now
            var scene: SceneSnapshot?
            var finding: HumanSceneFinding
            var differencePreview = ""
            var menuClosed = false
            let timing = NativeHumanSceneReader.Timing()
            do {
                let menuBar = target.payload.element?.role == "AXMenuBarItem"
                let windows = try await listedWindows(timing: timing)
                guard let selected = NativeHumanSceneReader.actionWindow(
                    target.payload.window, menuBar: menuBar, in: windows, processID: window.processID
                ) else { throw CocoaError(.fileNoSuchFile) }
                if let requested = target.payload.window, requested.processID == window.processID, !menuBar,
                   Self.isTransient(requested), !windows.contains(where: { $0.number == requested.number }) {
                    menuClosed = true
                }
                surface = selected
                if buttons.snapshot() != stamp || (latest?.sequence ?? 0) > target.sequence { continue }
                let observed: SceneSnapshot
                do {
                    reads += 1
                    observed = try await reader.scene(window: surface, mode: .textOnly, timing: timing)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    timing.failedSurface(processID: window.processID, windowNumber: surface.number,
                                         mode: ProductionPerception.Mode.textOnly.rawValue)
                    // Retry only a transient that disappeared during capture, never a still-present surface.
                    guard Self.isTransient(surface) else { throw error }
                    let current = try await listedWindows(timing: timing)
                    guard !current.contains(where: { $0.number == surface.number }),
                          let fallback = NativeHumanSceneReader.actionWindow(
                            nil, menuBar: false, in: current, processID: window.processID
                          ) else { throw error }
                    guard buttons.snapshot() == stamp, (latest?.sequence ?? 0) <= target.sequence else { throw error }
                    surface = fallback
                    menuClosed = true
                    reads += 1
                    observed = try await reader.scene(window: surface, mode: .textOnly, timing: timing)
                }
                try Task.checkCancellation()
                let kept = timing.measure(.sceneMinimization) { Self.minimized(observed) }
                scene = kept
                let text: String
                let kind: HumanSceneFinding.Kind
                if let before = textBaselines[surface.number] {
                    text = timing.measure(.difference) {
                        SceneChanges.text(from: before.scene, to: kept, since: Int(before.sequence))
                    }
                    kind = text == "Unchanged since revision \(before.sequence)." ? .unchanged : .changes
                    differencePreview = timing.measure(.diagnostics) {
                        Self.diagnosticDifference(text, before: before.scene, after: kept)
                            .split(separator: "\n").prefix(3).joined(separator: "\n")
                    }
                } else {
                    text = timing.measure(.rendering) { kept.text() }
                    kind = .keyframe
                }
                let context = menuClosed ? "read of window #\(surface.number) (menu closed)\n" : ""
                // Canvas crops for surfaces without text belong to issue #16; keep the recorded picture.
                do {
                    let minimized = timing.measure(.textMinimization) {
                        ValueMinimization().minimize(text: context + text).0
                    }
                    finding = try timing.measure(.compression) {
                        try HumanSceneFinding(sequence: target.sequence, kind: kind,
                                                   text: minimized,
                                                   readMilliseconds: Self.milliseconds(since: started),
                                                   windowNumber: surface.number,
                                                   baselineSequence: textBaselines[surface.number]?.sequence,
                                                   scenes: [surface.number: kept])
                    }
                } catch {
                    scene = nil
                    finding = .init(sequence: target.sequence, kind: .failed, reason: .compression,
                                    readMilliseconds: Self.milliseconds(since: started), windowNumber: surface.number)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                finding = .init(sequence: target.sequence, kind: .failed, reason: .read,
                                readMilliseconds: Self.milliseconds(since: started), windowNumber: surface.number)
            }
            finding.readMilliseconds = Self.milliseconds(since: started)
            try Task.checkCancellation()
            if finding.kind == .failed {
                timing.failedSurface(processID: window.processID, windowNumber: surface.number, mode: finding.mode.rawValue)
            }
            finding.provenance = timing.provenance
            finding.inputDuringRead = buttons.snapshot() != stamp || (latest?.sequence ?? 0) > target.sequence
            if finding.inputDuringRead {
                finding.provenance?.firstOverlappingSequence = target.sequence
                finding.provenance?.lastOverlappingSequence = latest?.sequence ?? target.sequence
            }
            finding = try await complete(item, with: finding)
            if let scene, finding.kind != .failed { textBaselines[surface.number] = (scene, target.sequence) }
            if finding.inputDuringRead { inputDuringRead += 1 }
            if finding.kind == .failed { failures += 1 }
            rawBytes += finding.rawBytes
            compressedBytes += finding.compressedBytes
            let context = menuClosed ? "read of window #\(surface.number) (menu closed)" : nil
            log(finding, action: target.payload.diagnostic, timing: timing, context: context)
            if finding.kind == .changes || finding.kind == .unchanged {
                Self.log.notice("difference #\(target.sequence, privacy: .public): \(differencePreview, privacy: .public)")
            }
            settle(after: target.sequence)
            return
        }
    }

    /// Completes through the capture-time action in lease order. Charge the read once, before
    /// recording coverage, so a byte-budget refusal cannot leave coverage of a missing finding.
    private func complete(_ first: Intervention.WorkItem, with result: HumanSceneFinding) async throws -> HumanSceneFinding {
        var item = first
        var finding = result
        var charged = false
        while true {
            try Task.checkCancellation()
            let isTarget = item.sequence == finding.sequence
            var entry = finding
            if !isTarget {
                entry = HumanSceneFinding(sequence: item.sequence, kind: finding.kind == .failed ? .superseded : .covered)
                if entry.kind == .covered { entry.coveredBySequence = finding.sequence }
            }
            entry.recordedAction = item.payload.summaryAction
            do {
                try await intervention.complete(item, with: entry,
                                                retainedBytes: (charged ? 0 : finding.compressedBytes))
            } catch Intervention.Failure.capacityExceeded {
                let inputDuringRead = finding.inputDuringRead
                finding = .init(sequence: finding.sequence, kind: .failed, reason: .byteBudget,
                                readMilliseconds: finding.readMilliseconds, windowNumber: finding.windowNumber)
                finding.inputDuringRead = inputDuringRead
                continue
            }
            charged = true
            if isTarget { return finding }
            // Each covered action also represents a pending read request that never started.
            superseded += 1
            if entry.kind == .covered { covered += 1 }
            log(entry, action: item.payload.diagnostic)
            leased = nil
            guard let next = await intervention.next() else { throw Intervention.Failure.invalidWorkItem }
            item = next
            leased = next
        }
    }

    private func review() async throws -> Intervention.Review {
        let started = ContinuousClock.now
        let revision = try await intervention.endInput()
        Self.log.notice("human handoff: endInput, elapsed \(ContinuousClock.now - started, privacy: .public)")
        settling?.cancel()
        // A session shorter than the initial read waits for it: it ends within its own box.
        await initialRead?.value
        let timing = NativeHumanSceneReader.Timing()
        var finalState = try await finalFinding(timing: timing)
        let review: Intervention.Review
        do {
            review = try await intervention.beginReview(revision, finalState: finalState,
                                                       retainedBytes: finalState.compressedBytes)
        } catch Intervention.Failure.capacityExceeded {
            finalState = .init(sequence: 0, kind: .failed, reason: .byteBudget,
                               readMilliseconds: finalState.readMilliseconds)
            review = try await intervention.beginReview(revision, finalState: finalState)
        }
        log(finalState, action: "final state", timing: timing)
        Self.log.notice("human handoff: beginReview, elapsed \(ContinuousClock.now - started, privacy: .public)")
        Self.log.notice("""
            human reconstruction: actions=\(review.findings.count, privacy: .public) \
            reads=\(self.reads, privacy: .public) covered=\(self.covered, privacy: .public) \
            superseded=\(self.superseded, privacy: .public) input-during-read=\(self.inputDuringRead, privacy: .public) \
            failures=\(self.failures + (finalState.kind == .failed ? 1 : 0), privacy: .public) \
            raw=\(self.rawBytes + finalState.rawBytes, privacy: .public) bytes \
            lzfse=\(self.compressedBytes + finalState.compressedBytes, privacy: .public) bytes \
            final-state=\(finalState.rawBytes, privacy: .public)/\(finalState.compressedBytes, privacy: .public) bytes evaluating
            """)
        return review
    }

    private func finalFinding(timing: NativeHumanSceneReader.Timing) async throws -> HumanSceneFinding {
        let started = ContinuousClock.now
        while true {
            try await waitForRelease()
            let stamp = buttons.snapshot()
            if stamp.processID == window.processID { continue }
            do {
                let listingStarted = ContinuousClock.now
                let listed = try await reader.finalWindows(processID: window.processID)
                timing.record(.windows, since: listingStarted)
                let windows = NativeHumanSceneReader.frontWindows(in: listed, processID: window.processID)
                for surface in windows {
                    let title = ValueMinimization().minimize(text: surface.title ?? "").0
                    Self.log.notice("final window #\(surface.number, privacy: .public) size=\(surface.frame.width, privacy: .public)x\(surface.frame.height, privacy: .public) layer=\(surface.layer, privacy: .public) title=\(title, privacy: .public)")
                }
                let closed = Set(textBaselines.keys).union(initialScenes.keys)
                    .filter { number in !listed.contains { $0.number == number } }.sorted()
                guard !windows.isEmpty else {
                    return try .init(sequence: 0, kind: .failed, text: "", readMilliseconds: 0,
                                     reason: .noWindows, initialScenes: initialScenes,
                                     closedWindowNumbers: closed)
                }
                var texts: [String] = []
                var scenes: [Int: SceneSnapshot] = [:]
                if !listed.contains(where: { $0.number == window.windowNumber }) {
                    texts.append("The lent window #\(window.windowNumber) is no longer in the current window inventory.")
                }
                // The listing includes windows off screen, but only on-screen windows can be captured. A panel
                // the application hides on deactivation is off screen at hand-back: it is not read, nor failed.
                let visible = windows.contains { $0.layer != 0 }
                    ? Set(try await reader.windows(processID: window.processID).map(\.number)) : []
                var failed = false
                for surface in windows {
                    if buttons.snapshot() != stamp { break }
                    if surface.layer != 0, !visible.contains(surface.number) {
                        Self.log.notice("final window #\(surface.number, privacy: .public) is off screen; not read")
                        continue
                    }
                    reads += 1
                    do {
                        let scene = try await reader.scene(window: surface, mode: .full, timing: timing)
                        let kept = timing.measure(.sceneMinimization) { Self.minimized(scene) }
                        scenes[surface.number] = kept
                        texts.append("window #\(surface.number)\n" + timing.measure(.rendering) { kept.text() })
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failed = true
                        timing.failedSurface(processID: window.processID, windowNumber: surface.number, mode: "full")
                        texts.append("window #\(surface.number): read failed: surface unavailable")
                    }
                }
                try Task.checkCancellation()
                if buttons.snapshot() != stamp { continue }
                let minimized = timing.measure(.textMinimization) {
                    ValueMinimization().minimize(text: texts.joined(separator: "\n\n")).0
                }
                var finding = try timing.measure(.compression) {
                    try HumanSceneFinding(sequence: 0, kind: failed ? .failed : .keyframe,
                                             text: minimized,
                                             readMilliseconds: Self.milliseconds(since: started),
                                             reason: failed ? .read : nil,
                                             scenes: scenes,
                                             initialScenes: initialScenes,
                                             closedWindowNumbers: closed)
                }
                finding.readMilliseconds = Self.milliseconds(since: started)
                finding.provenance = timing.provenance
                finding.provenance?.initialStructure = initialStructure
                finding.provenance?.settled = settled.isEmpty ? nil : settled
                return finding
            } catch is CancellationError { throw CancellationError() }
            catch {
                return .init(sequence: 0, kind: .failed, reason: .read,
                             readMilliseconds: Self.milliseconds(since: started))
            }
        }
    }

    private static func isTransient(_ surface: InteractionWindow) -> Bool {
        surface.layer > 0 && surface.layer != CGWindowLevelForKey(.modalPanelWindow)
            && surface.layer != CGWindowLevelForKey(.mainMenuWindow)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private func log(
        _ finding: HumanSceneFinding, action: String,
        timing: NativeHumanSceneReader.Timing? = nil, context: String? = nil
    ) {
        let outcome = (finding.coveredBySequence.map { "covered by #\($0)" } ?? finding.kind.rawValue)
            + (finding.inputDuringRead ? ", input during read" : "") + (finding.reason.map { ": " + $0.rawValue } ?? "")
            + (context.map { ", " + $0 } ?? "")
        let stages = timing.map { ", " + $0.diagnostic } ?? ""
        Self.log.notice("""
            #\(finding.sequence, privacy: .public) \(action, privacy: .public) -> \(outcome, privacy: .public), \
            mode=\(finding.mode.rawValue, privacy: .public), \
            raw \(Double(finding.rawBytes) / 1024, privacy: .public) KB -> \
            lzfse \(Double(finding.compressedBytes) / 1024, privacy: .public) KB, \
            read \(finding.readMilliseconds, privacy: .public) ms\(stages, privacy: .public)
            """)
    }

    /// Removes reserved field values wherever OCR or another label repeats them, then applies the
    /// same minimization used by observation records. No unminimized scene becomes a baseline.
    static func minimized(_ scene: SceneSnapshot) -> SceneSnapshot {
        let secretValues = scene.elements.filter {
            $0.role == "AXSecureTextField" || ValueMinimization.namesSecret($0.label)
        }.compactMap(\.value) + scene.outOfViewFields.filter {
            $0.role == "AXSecureTextField" || ValueMinimization.namesSecret($0.label)
        }.map(\.value)
        var minimized = ValueMinimization(secrets: secretValues).minimize(scene: scene)
        for index in minimized.elements.indices where minimized.elements[index].role == "AXSecureTextField" {
            minimized.elements[index].label = "a protected field"
            minimized.elements[index].value = ValueMinimization.marker
            minimized.elements[index].selectedRange = nil
        }
        for index in minimized.outOfViewFields.indices where minimized.outOfViewFields[index].role == "AXSecureTextField" {
            minimized.outOfViewFields[index].label = "a protected field"
            minimized.outOfViewFields[index].value = ValueMinimization.marker
        }
        return minimized
    }

    /// Ordinary values are withheld only as whole texts, including quoted values in a difference.
    /// Only secret-named values longer than two characters are withheld inside other text.
    static func diagnosticDifference(_ text: String, before: SceneSnapshot, after: SceneSnapshot) -> String {
        let fields = (before.elements + after.elements).compactMap { element in
            element.value.map { (label: element.label, value: $0) }
        } + (before.outOfViewFields + after.outOfViewFields).map { (label: $0.label, value: $0.value) }
        let values = Set(fields.map(\.value))
        let secrets = Set(fields.filter {
            $0.value.count > 2 && ValueMinimization.namesSecret($0.label)
        }.map(\.value))
        let minimization = ValueMinimization(
            secrets: Array(secrets), exact: Dictionary(uniqueKeysWithValues: values.map { ($0, .confidentialContent) }))
        // Compact values end at the next structural suffix. Earlier values and multiline values
        // are quoted; both forms are minimized as whole texts, never as arbitrary fragments.
        let quoted = Dictionary(values.flatMap { value in
            [value, value.trimmingCharacters(in: .whitespacesAndNewlines)].map { (String(reflecting: $0), value) }
        }, uniquingKeysWith: { first, _ in first })
        var kept = text
        let alternatives = values.filter { !$0.isEmpty && $0 != ValueMinimization.marker }
            .sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        if !alternatives.isEmpty {
            let suffix = #"(?= @-?\d+,-?\d+(?:\s|$)| \[sel | \[disabled\]| \{| ~recalled|: |$)"#
            guard let pattern = try? NSRegularExpression(pattern: "(?<= = )(?:" + alternatives + ")" + suffix)
            else { return ValueMinimization.marker }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text) else { continue }
                kept.replaceSubrange(range, with: minimization.minimize(text: String(text[range])).0)
            }
        }
        let quotedText = kept
        for match in quotedText.matches(of: /"(?:\\.|[^"\\])*"/).reversed() {
            guard let value = quoted[String(match.output)] else { continue }
            let replacement = minimization.minimize(text: value).0
            kept.replaceSubrange(match.range, with: String(reflecting: replacement))
        }
        return minimization.minimize(text: kept).0
    }
}
