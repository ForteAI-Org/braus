//
//  BrokeredSeat.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import AppKit
import AutomationRuntime
import Foundation
import PerceptionCore
import SeatBroker

/// BrokeredSeat runs one `--seat` command on a worker's desktop as the app composes it (AppModel,
/// TeamModel): a `SeatBroker` of this process and a `BrokeredAutomationSession` that opens the
/// application through it, inside one turn. The window recipe, the closing guards, the menus' brief
/// activation, a browser's own new window and the finish by provenance are therefore the app's own.
///
/// The application is the running one the command line named, opened by its bundle identifier, so a
/// `--seat` command still drives only what is already running. Whatever the body does, the session
/// closes, which gives the window back, and the parked seat takes its display down.
enum BrokeredSeat {

    /// Who a missing permission is granted to, as the session's refusal says: macOS gives the grants of a
    /// command line to the terminal that launches it, never to Braus.app.
    static let grantee = "the terminal launching Braus"

    /// The broker and the worker's desktop one command drives, with the invocation's policy flags.
    static func compose(
        _ invocation: Invocation,
        knowledge   : URL
    ) -> (broker: SeatBroker, desktop: BrokeredAutomationSession) {
        let broker = SeatBroker(configuration: SeatBrokerConfiguration(
            allowUnvalidatedBuild: invocation.flags.contains("allow-unvalidated-build")
        ))
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : UUID(),
            knowledgeDirectory: knowledge,
            allowsDestructive : invocation.flags.contains("allow-destructive"),
            grantee           : grantee
        )
        return (broker, desktop)
    }

    /// Opens `application`, or its window titled `--window`, and runs `body` with the session and its
    /// first scene, which the Brain observes through `recorder`. `composed` replaces `compose` in tests.
    static func withSession(
        _ application: NSRunningApplication,
        _ invocation : Invocation,
        knowledge    : URL,
        recorder     : CallRecorder,
        composed     : (broker: SeatBroker, desktop: BrokeredAutomationSession)? = nil,
        _ body       : (BrokeredAutomationSession, SceneSnapshot) async throws -> Void
    ) async throws {
        if invocation.flags.contains("allow-unvalidated-build") {
            // The broker hands this research opt-in to the Driver; it is chosen here and said out loud.
            FileHandle.standardError.write(Data("seat: research opt-in for an unvalidated macOS build\n".utf8))
        }
        let (broker, desktop) = composed ?? compose(invocation, knowledge: knowledge)
        do {
            try await desktop.turn {
                let started = ContinuousClock.now
                let scene = try await CallRecorder.$current.withValue(recorder) {
                    try await desktop.open(
                        application: application.bundleIdentifier ?? application.localizedName ?? "",
                        window     : invocation.options["window"]
                    )
                }
                let frame  = desktop.screenFrame
                let number = desktop.observedWindowNumber.map { "#\($0) " } ?? ""
                let placed = "at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
                let opened = "seat: opened \(number)\"\(scene.windowTitle)\" \(placed)"
                FileHandle.standardError.write(Data("\(opened) in \(started.duration(to: .now))\n".utf8))
                try await body(desktop, scene)
            }
        } catch {
            await close(desktop, broker)
            throw error
        }
        await close(desktop, broker)
        FileHandle.standardError.write(Data("seat: window returned, display down\n".utf8))
    }

    /// Gives the window back, says what finishing left to do, and takes the parked seat's display down.
    private static func close(
        _ desktop: BrokeredAutomationSession,
        _ broker : SeatBroker
    ) async {
        await desktop.close()
        await broker.queue.shutdown()
        if let warning = desktop.closeWarning {
            FileHandle.standardError.write(Data("seat: \(warning)\n".utf8))
        }
    }
}
