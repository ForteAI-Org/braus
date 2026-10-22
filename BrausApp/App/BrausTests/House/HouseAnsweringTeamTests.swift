//
//  HouseAnsweringTeamTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import ChatCore
import ModelTransports
import os
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

/// HouseAnsweringTeamTests checks a crowded house whose workers answer at once, as the room costs probe
/// starts them: the window appears and follows their turns without laying itself out again and again.
@MainActor
@Suite("A house of many answering workers", .serialized)
struct HouseAnsweringTeamTests {

    /// The longest the main thread may stay busy at once while the house appears or follows a turn. A
    /// cold appearance of thirty rooms takes well under a second; the layout loop held it for minutes.
    private static let longestStretch: Duration = .seconds(5)

    /// The window sits far off screen behind every other, and nothing is sent to it.
    @Test("Thirty workers, eight of them answering: the house appears and follows their turns in bounded time")
    func settlesWhileAnswering() async throws {
        let root = URL.temporaryDirectory.appending(
            path         : "HouseAnsweringTeamTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at                         : root,
            withIntermediateDirectories: true
        )
        defer { TemporaryStore.discard(root) }
        let suite       = "braus-house-answering-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let (team, answering) = try await Self.answeringTeam(
            count      : 30,
            in         : root,
            preferences: preferences
        )
        #expect(answering.count == 8)
        #expect(answering.allSatisfy(team.isAnswering))

        // A loop holds the main thread, where no expectation can run; the run then ends here instead.
        let finished = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            if !finished.withLock({ $0 }) { fatalError("The house window held the main thread for minutes") }
        }
        defer { finished.withLock { $0 = true } }

        let window = Self.window(of: team)
        defer {
            window.contentView = nil
            window.close()
        }
        var watch = MainThreadWatch()
        window.orderBack(nil)
        try await watch.pump(
            window,
            for: .seconds(3)
        )
        #expect(
            watch.longest < Self.longestStretch,
            "appearing held the main thread for \(watch.longest)"
        )
        #expect(answering.allSatisfy { id in
            HouseRoster.workers(of: team).first { $0.id == id }?.status == .busy
        })

        // Each turn that ends changes the house while the others still answer.
        for id in answering {
            team.stopAnswering(id)
            try await watch.pump(
                window,
                for: .milliseconds(300)
            )
        }
        #expect(
            watch.longest < Self.longestStretch,
            "following the turns held the main thread for \(watch.longest)"
        )
        await team.closeAgentHosts()
    }

    // MARK: Fixture

    /// MainThreadWatch measures the longest the main thread stays away between its turns, while the
    /// window is laid out about every 10 ms, as a display cycle does.
    @MainActor
    private struct MainThreadWatch {
        private(set) var longest: Duration = .zero

        mutating func pump(
            _ window   : NSWindow,
            for seconds: Duration
        ) async throws {
            let clock = ContinuousClock()
            let end   = clock.now + seconds
            var last  = clock.now
            while clock.now < end {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
                let now = clock.now
                longest = max(
                    longest,
                    now - last
                )
                last    = now
            }
        }
    }

    /// The house of `team`, 1200 by 900 points, with its toolbar and title bridged as the app's window
    /// has them, far off screen and not yet ordered in.
    private static func window(of team: TeamModel) -> NSWindow {
        let hosting = NSHostingView(rootView: HouseShellView(
            team                : team,
            isInspectorRequested: .constant(false)
        ))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(
                x     : -30_000,
                y     : 0,
                width : 1200,
                height: 900
            ),
            styleMask  : [.titled, .closable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        // Closing frees the hosted rooms' denoiser buckets, which the shared pool would keep.
        window.isReleasedWhenClosed = false
        window.appearance           = NSAppearance(named: .darkAqua)
        window.contentView          = hosting
        return window
    }

    /// A team of `count` workers in a store under `root`, as the room costs probe makes it: every
    /// seventh without a model, every third of the rest answering through a stand-in agent that only
    /// waits. Returns the team, once those workers answer, and their ids.
    private static func answeringTeam(
        count      : Int,
        in root    : URL,
        preferences: UserDefaults
    ) async throws -> (team: TeamModel, answering: [UUID]) {
        let agent = root.appending(path: "claude")
        try Data(standIn.utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )
        let store     = try WorkspaceStore.opening(in: root.appending(
            path         : "Store",
            directoryHint: .isDirectory
        ))
        let selection = ModelSelection(
            provider: .claudeCode,
            model   : "claude-opus-5",
            effort  : .high
        )
        var answering: [UUID] = []
        for index in 0..<count {
            let worker = try await store.createWorker(
                name      : "Worker \(index + 1)",
                role      : "Role \(index % 9 + 1)",
                appearance: WorkerAppearance(
                    seed   : Int64(index * 7 + 3),
                    palette: "dusk"
                )
            )
            guard index % 7 != 6 else { continue }

            try await store.configure(
                worker   : worker.id,
                selection: selection
            )
            if index % 3 == 0 { answering.append(worker.id) }
        }

        let team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent,
            preferences     : preferences
        )
        await team.load()
        for id in answering {
            team.selection = id
            await team.openSelectedConversation()
            team.draft = "Wait."
            await team.send()
        }
        team.selection = nil
        let deadline = ContinuousClock.now + .seconds(10)
        while !answering.allSatisfy(team.isAnswering), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (team, answering)
    }

    /// A stand-in agent that starts and then only waits, so its worker stays busy.
    private static let standIn = """
        #!/usr/bin/python3
        import json, sys, time
        sys.stdin.read()
        print(json.dumps({'type': 'system', 'subtype': 'init', 'model': 'claude-opus-5', 'session_id': 's1'}), flush=True)
        time.sleep(600)

        """
}
