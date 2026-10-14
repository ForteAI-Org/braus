import AutomationRuntime
//
//  SceneCommand.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import CoreGraphics
import EngineCore
import Foundation
import LiveScenes
import Memory
import PerceptionCore
import SeatBroker

/// SceneCommand perceives the interaction window once, teaches the brain what it saw, and prints the
/// text map a model would read, or the scene's JSON with `--json`, enriched from memory. With `--seat`
/// the scene is the first one the brokered session reads as it opens the window (`BrokeredSeat`).
enum SceneCommand {

    static func run(_ invocation: Invocation) async throws {
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        if invocation.flags.contains("seat") {
            let knowledge = Runtime.knowledgeDirectory(invocation)
            let recorder  = Runtime.commandLineRecorder(knowledge: knowledge)
            let started   = ContinuousClock.now
            try await BrokeredSeat.withSession(
                application,
                invocation,
                knowledge: knowledge,
                recorder : recorder
            ) { desktop, scene in
                try await report(
                    scene,
                    elapsed : started.duration(to: .now),
                    frame   : desktop.screenFrame,
                    recorder: recorder,
                    service : MemoryService.shared(for: knowledge),
                    invocation
                )
            }
        } else {
            let runtime = Runtime(invocation: invocation)
            let started = ContinuousClock.now
            let perceived = try await runtime.scenes.currentScene(of: application.processIdentifier)
            let elapsed = started.duration(to: .now)
            // Every look teaches the brain, as the watcher's did; the map printed is the enriched one.
            let recorder = runtime.commandLineRecorder()
            let scene = await recorder.observe(perceived)
            try await report(
                scene,
                elapsed : elapsed,
                frame   : perceived.frame,
                recorder: recorder,
                service : runtime.service,
                invocation
            )
        }
    }

    /// Prints `scene` once what it taught is written, and on standard error what the Brain learned.
    private static func report(
        _ scene     : SceneSnapshot,
        elapsed     : Duration,
        frame       : CGRect,
        recorder    : CallRecorder,
        service     : MemoryService,
        _ invocation: Invocation
    ) async throws {
        _ = await service.flush(within: service.configuration.closingBudget)
        let key = BrainApplicationKey.observe(CaptureSampleKey(eventID: recorder.eventID, phase: .current))
        let learned = try? await service.application(key)
        if invocation.flags.contains("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            print(String(decoding: try encoder.encode(scene), as: UTF8.self))
        } else {
            print(scene.text())
        }
        let size = "\(Int(frame.width))×\(Int(frame.height)) pt"
        let brain = switch learned?.outcome {
            case .observed(let created, let updated, _)?: "brain: \(created) new anchors, \(updated) seen again"
            default: "brain: not recorded (\(await service.status().lastFailure ?? "memory unavailable"))"
        }
        let summary = "perceived \(scene.elements.count) elements in \(elapsed), frame \(size), token \(scene.token); "
            + brain + "\n"
        FileHandle.standardError.write(Data(summary.utf8))
    }
}
