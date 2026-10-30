//
//  HumanSceneReading.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AccessibilityFacts
import AppKit
import AutomationRuntime
import CoreGraphics
import Foundation
import InteractionListener
import InteractionObservation
import WindowPlacement
import Memory
import OSLog
import Perception
import PerceptionCore
import ScreenCapture
import Synchronization

/// HumanSceneReading supplies current scenes without posting input or retaining a native window.
/// Implementations validate window ownership and list current windows in front-to-back order.
/// A scene starts with capture; later AX values may reflect input received during perception.
nonisolated protocol HumanSceneReading: Sendable {
    func scene(window: InteractionWindow, mode: ProductionPerception.Mode,
               timing: NativeHumanSceneReader.Timing) async throws -> SceneSnapshot
    func windows(processID: Int32) async throws -> [InteractionWindow]
    func finalWindows(processID: Int32) async throws -> [InteractionWindow]
    /// A structural read alone of every on-screen window of the process, within `seconds`: no capture, no OCR.
    func structure(processID: Int32, seconds: Double) async -> InteractionStructuralRead
}

extension HumanSceneReading {
    func finalWindows(processID: Int32) async throws -> [InteractionWindow] {
        try await windows(processID: processID)
    }

    func structure(processID: Int32, seconds: Double) async -> InteractionStructuralRead {
        InteractionStructuralRead(processID: processID, interval: .init(start: 0, end: 0))
    }
}

nonisolated struct NativeHumanSceneReader: HumanSceneReading {
    private let capturer = StillCapturer()
    private let pipeline: ScenePipeline
    private let textPipeline: ScenePipeline
    /// An action read's pipeline where the structural read covered its window: native facts only, no OCR.
    private let nativePipeline: ScenePipeline

    /// Recognizes no text: the action read of a window the structural read covered keeps native facts only.
    private struct NoText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] { [] }
        func recognizeTextCancellably(in image: CGImage, accuracy: TextRecognitionAccuracy) async throws -> [RecognizedText] { [] }
    }

    init() {
        let timing = Timing()
        pipeline = Timing.$current.withValue(timing) {
            ProductionPerception.pipeline(
                valueGuard: { ValueMinimization.namesSecret($0) || ValueMinimization.scrubCredentials($0).1 },
                timingHook: { Timing.current?.record($0, duration: $1) })
        }
        textPipeline = Timing.$current.withValue(timing) {
            ProductionPerception.pipeline(
                mode: .textOnly,
                valueGuard: { ValueMinimization.namesSecret($0) || ValueMinimization.scrubCredentials($0).1 },
                timingHook: { Timing.current?.record($0, duration: $1) })
        }
        nativePipeline = Timing.$current.withValue(timing) {
            ScenePipeline(text: NoText(), augmentation: AccessibilityAugmenter(
                windowNumberResolver: { WindowRelocator.windowNumber(of: $0) },
                valueGuard: { ValueMinimization.namesSecret($0) || ValueMinimization.scrubCredentials($0).1 }
            ), timingHook: { Timing.current?.record($0, duration: $1) })
        }
        let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")
        log.notice("human scene reader setup: \(timing.diagnostic, privacy: .public)")
    }

    @concurrent
    func scene(window: InteractionWindow, mode: ProductionPerception.Mode,
               timing: Timing) async throws -> SceneSnapshot {
        let started = ContinuousClock.now
        timing.beginSurface(processID: window.processID, windowNumber: window.number, mode: mode.rawValue)
        let image: CGImage
        do {
            defer { timing.record(.capture, since: started) }
            image = try await capturer.captureWindow(number: window.number, frame: window.frame,
                                                     expectedProcessID: window.processID)
        }
        let metadataStarted = ContinuousClock.now
        let app = NSRunningApplication(processIdentifier: window.processID)
        let descriptor = ScenePipeline.Window(
            bundleID: app?.bundleIdentifier ?? "", appName: app?.localizedName ?? "Application",
            title: window.title ?? "", processID: window.processID, frame: window.frame, windowNumber: window.number)
        timing.record(.metadata, since: metadataStarted)
        // One structural read per attempt covers every window of the process; the full read at hand-back takes the
        // long box, so the windows a person left off screen are read whole. It comes before perception: an action read
        // of a window it reached needs no OCR, since the report reads no pixel text (every report and ledger of the
        // recorded trials is the same without it).
        var covered = false
        if !timing.hasStructure {
            let seconds = mode == .textOnly ? Self.actionStructureSeconds : Self.longStructureSeconds
            let structure = await read(processID: window.processID, including: window.number, seconds: seconds)
            timing.recordStructure(structure)
            covered = mode == .textOnly && structure.windows.contains { $0.number == window.number }
        }
        let perceptionStarted = ContinuousClock.now
        defer { timing.record(.perception, since: perceptionStarted) }
        let scene = try await Timing.$current.withValue(timing) {
            try await (mode == .full ? pipeline : covered ? nativePipeline : textPipeline).perceive(image, of: descriptor)
        }
        let semantics = await NativeInteractionSemanticReader.capture(
            processID: window.processID, windows: [window.number],
            resolveWindow: { WindowRelocator.windowNumber(of: $0) },
            isReserved: { ValueMinimization.namesSecret($0) || ValueMinimization.scrubCredentials($0).1 })
            .withholding { ValueMinimization().minimize(text: $0).0 }
        timing.recordSemantics(semantics)
        return scene
    }

    /// The structural read's box after an action, and when control passes or comes back: there no person waits on
    /// it within a second (hand-back), or it runs beside the transition (when control passes).
    static let actionStructureSeconds = 0.15
    static let longStructureSeconds = 1.0
    /// The box of a read while the person pauses: no one waits on it, and input stops it. A pane another process
    /// serves answers slowly and needs more than an action's box.
    static let settledStructureSeconds = 0.5

    @concurrent
    func structure(processID: Int32, seconds: Double) async -> InteractionStructuralRead {
        await read(processID: processID, including: nil, seconds: seconds)
    }

    /// Every on-screen window of the process, the small ones an action types into included.
    @concurrent
    private func read(processID: Int32, including number: Int?, seconds: Double) async -> InteractionStructuralRead {
        let windows = InteractionWindowReader.windows(excluding: -1).filter { $0.processID == processID }.map(\.number)
        return await NativeInteractionSemanticReader.structure(
            processID: processID, windows: Set(windows + [number].compactMap { $0 }), seconds: seconds,
            resolveWindow: { WindowRelocator.windowNumber(of: $0) },
            hostName: { NSRunningApplication(processIdentifier: $0)?.localizedName },
            isReserved: { ValueMinimization.namesSecret($0) || ValueMinimization.scrubCredentials($0).1 })
            .withholding { ValueMinimization().minimize(text: $0).0 }
    }

    @concurrent
    func windows(processID: Int32) async throws -> [InteractionWindow] {
        InteractionWindowReader.windows(excluding: -1).filter { $0.processID == processID }
    }

    /// Take-back can order out the document while staging it. Final evidence must include it.
    @concurrent
    func finalWindows(processID: Int32) async throws -> [InteractionWindow] {
        InteractionWindowReader.windows(excluding: -1, onScreenOnly: false).filter { $0.processID == processID }
    }

    static func isReadable(_ window: InteractionWindow, processID: Int32) -> Bool {
        window.processID == processID && window.frame.width >= 120 && window.frame.height >= 60
    }

    /// Keeps the largest normal window and its higher panels, without menu-bar or desktop surfaces.
    static func frontWindows(in windows: [InteractionWindow], processID: Int32) -> [InteractionWindow] {
        let candidates = windows.filter {
            isReadable($0, processID: processID) && $0.layer >= 0
                && $0.layer < CGWindowLevelForKey(.mainMenuWindow)
        }
        guard let document = candidates.filter({ $0.layer == 0 }).max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }), let index = candidates.firstIndex(where: { $0.number == document.number }) else { return candidates }
        return Array(candidates[...index])
    }

    static func actionWindow(
        _ requested: InteractionWindow?, menuBar: Bool, in windows: [InteractionWindow], processID: Int32
    ) -> InteractionWindow? {
        if !menuBar, let requested, requested.processID == processID,
           let current = windows.first(where: { $0.number == requested.number && isReadable($0, processID: processID) }) {
            return current
        }
        return frontWindows(in: windows, processID: processID).first
    }

    /// Timing belongs to one read attempt. OCR and AX record concurrently under the mutex;
    /// repeated stages add their elapsed time, and an unstarted stage remains absent.
    final class Timing: Sendable {
        @TaskLocal
        static var current: Timing?

        enum Stage: String, CaseIterable, Sendable {
            case capture, windows, metadata, perception
            case sceneMinimization = "scene minimization"
            case rendering = "compact text"
            case difference = "SceneChanges"
            case diagnostics = "diagnostic redaction"
            case textMinimization = "text minimization"
            case compression = "LZFSE"
        }
        private let elapsed = Mutex<[String: Double]>([:])
        private let evidence = Mutex(HumanReadProvenance())

        func beginSurface(processID: Int32, windowNumber: Int, mode: String) {
            evidence.withLock { $0.surfaces.append(.init(processID: processID, windowNumber: windowNumber, mode: mode)) }
        }

        func recordSemantics(_ snapshot: InteractionSemanticSnapshot) {
            evidence.withLock {
                guard let index = $0.surfaces.indices.last else { return }
                $0.surfaces[index].semantics = snapshot
            }
            let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")
            log.notice("human scene semantics: added_ms=\(snapshot.interval.milliseconds, privacy: .public) elements=\(snapshot.elements.count, privacy: .public) queries=\(snapshot.attributeReads, privacy: .public) truncated=\(snapshot.truncated, privacy: .public)")
        }

        /// Whether this attempt already holds a structural read: it covers every window of the process.
        var hasStructure: Bool { evidence.withLock { $0.surfaces.contains { $0.structure != nil } } }

        func recordStructure(_ read: InteractionStructuralRead) {
            evidence.withLock {
                guard let index = $0.surfaces.indices.last else { return }
                $0.surfaces[index].structure = read
            }
            let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")
            let collections = read.windows.flatMap(\.collections)
            log.notice("human scene structure: ms=\(read.interval.milliseconds, privacy: .public) windows=\(read.windows.count, privacy: .public) collections=\(collections.count, privacy: .public) members=\(collections.reduce(0) { $0 + $1.members.count }, privacy: .public) hosted=\(read.windows.flatMap(\.hosted).count, privacy: .public) unread=\(read.unread.count, privacy: .public)")
        }

        func failedSurface(processID: Int32, windowNumber: Int, mode: String) {
            evidence.withLock {
                if let index = $0.surfaces.indices.last, $0.surfaces[index].windowNumber == windowNumber {
                    $0.surfaces[index].failed = true
                } else {
                    $0.surfaces.append(.init(processID: processID, windowNumber: windowNumber, mode: mode, failed: true))
                }
            }
        }

        var provenance: HumanReadProvenance { evidence.withLock { $0 } }


        func record(_ stage: Stage, since start: ContinuousClock.Instant) {
            record(stage.rawValue, duration: start.duration(to: .now))
        }

        func record(_ stage: ScenePipeline.Stage, duration: Duration) {
            record(stage.rawValue, duration: duration)
        }

        private func record(_ stage: String, duration: Duration) {
            let parts = duration.components
            let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
            elapsed.withLock { $0[stage, default: 0] += milliseconds }
            if stage == Stage.capture.rawValue || stage == ScenePipeline.Stage.augmentation.rawValue {
                let end = ProcessInfo.processInfo.systemUptime
                let interval = InteractionSemanticSnapshot.Interval(start: end - milliseconds / 1000, end: end)
                evidence.withLock {
                    guard let index = $0.surfaces.indices.last else { return }
                    if stage == Stage.capture.rawValue { $0.surfaces[index].capture = interval }
                    else { $0.surfaces[index].accessibility = interval }
                }
            }
        }

        func measure<T>(_ stage: Stage, _ operation: () throws -> T) rethrows -> T {
            let started = ContinuousClock.now
            defer { record(stage, since: started) }
            return try operation()
        }

        var milliseconds: [String: Double] { elapsed.withLock { $0 } }

        var diagnostic: String {
            let values = elapsed.withLock { $0 }
            let stages = Stage.allCases.map(\.rawValue)
                + ScenePipeline.Stage.allCases.map(\.rawValue)
            return stages.map { stage in
                let value = values[stage].map { String(format: "%.3f ms", $0) } ?? "n/a"
                return "\(stage) \(value)"
            }.joined(separator: ", ")
        }
    }
}
