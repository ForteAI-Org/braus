//
//  BrokeredSeatTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import AppKit
import AutomationRuntime
@testable import braus
import Foundation
import PerceptionCore
@testable import SeatBroker
import SeatDriving
import Testing

/// How a `--seat` command reaches the desktop: through a worker's brokered session on a broker of its
/// own, as the app's workers do, never through a seat of the command line's. The opening is supplied in
/// place of the broker's, keeping its order (the grants, the queue, the opening on the granted seat), so
/// nothing here raises a display; what the real opening does on one is the live check.
@MainActor
@Suite("braus --seat commands on the brokered session")
struct BrokeredSeatTests {

    private struct Stopped: Error {}

    /// A session whose opening records what it was asked for and names the Dock, which nothing adopts.
    private static func composed(
        _ knowledge: URL,
        opened     : @escaping @MainActor (String, String?) -> Void
    ) throws -> (broker: SeatBroker, desktop: BrokeredAutomationSession) {
        let dock   = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene  = SceneSnapshot(bundleID: "com.apple.dock", appName: "Dock", windowTitle: "Untitled",
                                   viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let broker = SeatBroker()
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : UUID(),
            knowledgeDirectory: knowledge,
            allowsDestructive : false,
            missingGrant      : { nil },
            requestGrants     : {},
            seating           : { _, application, window in
                opened(application, window)
                return (TargetApp(pid: dock, bundleID: "com.apple.dock", name: "Dock", bundleURL: nil, windows: []),
                        SeatTarget())
            },
            perceiving        : { _, _ in scene }
        )
        return (broker, desktop)
    }

    private static func knowledge() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("braus-brokered-seat-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("a --seat command opens the running application by its bundle ID and --window through the brokered session, holds the seat for the body and gives it back")
    func aSeatCommandOpensThroughTheBrokeredSession() async throws {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        let knowledge = Self.knowledge()
        var requests: [String] = []
        let (broker, desktop) = try Self.composed(knowledge) { application, window in
            requests.append(application + " | " + (window ?? "nil"))
        }
        let invocation = Invocation(arguments: ["scene", "Dock", "--seat", "--window", "Untitled"])
        var during: [SeatQueue.State] = []
        var first: SceneSnapshot?

        try await BrokeredSeat.withSession(
            dock,
            invocation,
            knowledge: knowledge,
            recorder : Runtime.commandLineRecorder(knowledge: knowledge),
            composed : (broker, desktop)
        ) { session, scene in
            #expect(session === desktop)
            #expect(session.id != nil)
            during = broker.queue.entries.map(\.state)
            first  = scene
        }

        #expect(requests == ["com.apple.dock | Untitled"])
        #expect(first?.windowTitle == "Untitled")
        #expect(during == [.acting])
        #expect(desktop.id == nil, "the session closed once the command ended")
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a --seat command's session names the terminal, not Braus.app, as who to allow a missing permission")
    func aSeatCommandNamesTheTerminalAsTheGrantee() {
        let (_, desktop) = BrokeredSeat.compose(
            Invocation(arguments: ["scene", "Dock", "--seat"]),
            knowledge: Self.knowledge()
        )
        #expect(desktop.grantee == BrokeredSeat.grantee)
        #expect(BrokeredSeat.grantee == "the terminal launching Braus")
    }

    @Test("a --seat command whose body throws still closes the session and gives the seat back")
    func aFailedSeatCommandGivesTheSeatBack() async throws {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        let knowledge = Self.knowledge()
        let (broker, desktop) = try Self.composed(knowledge) { _, _ in }

        await #expect(throws: Stopped.self) {
            try await BrokeredSeat.withSession(
                dock,
                Invocation(arguments: ["act", "Dock", "Save", "--seat"]),
                knowledge: knowledge,
                recorder : Runtime.commandLineRecorder(knowledge: knowledge),
                composed : (broker, desktop)
            ) { _, _ in
                throw Stopped()
            }
        }

        #expect(desktop.id == nil)
        #expect(broker.queue.entries.isEmpty)
    }
}
