import AppKit
import AutomationRuntime
import EngineCore
import Foundation
import MacDriver
@testable import MacSession
import MacDriving
import PerceptionCore
import Synchronization
import Testing

/// Issue #51 on the real Mac: how the MacDriver does across the apps people use. BRAUS_MAC_LIVE_TESTS=1
/// and BRAUS_MAC_MATRIX_TESTS=1, the desktop free. Each installed app is opened through
/// `MacAutomationSession`; the row says whether the MacDriver drove it or handed it to the seat and why,
/// its coverage, timings, and the longest main-actor stall. One harmless target is clicked where a click
/// has no side effect; elsewhere the app is only read. The stall is asserted (under half a second), and
/// an issue is recorded for each app after which the person's app was not in front.
/// BRAUS_MAC_MATRIX_DISCOVER=1 clicks nothing and prints each scene's labels, to choose targets.
/// BRAUS_MAC_MATRIX_ALL=1 maps every app in /Applications, /System/Applications and Utilities, read
/// only, except the ones whose launch does something (`notLaunched`), mapped only when running.
/// Chrome and its app shims, and Google Drive with its document shortcuts (they open the browser), are
/// never touched. BRAUS_MAC_MATRIX_SETTLE=seconds (default 2) is how long the app stays open after open
/// and after the click before the front app is checked, so a late steal is seen before the app quits. BRAUS_MAC_MATRIX_ONLY=Name,Name limits the run;
/// BRAUS_MAC_MATRIX_SKIP=Name,Name never launches the apps of this Mac whose launch does something.
/// Labels of an Italian Mac. An app is quit only when the test launched it.
@MainActor
@Suite("Mac app matrix, live", .serialized)
struct MacAppMatrixLiveTests {

    struct App: Sendable {
        let name: String
        let bundleID: String
        /// Harmless targets, the first the scene shows is clicked; empty: read only.
        let targets: [String]
        let family: String
    }

    nonisolated static let apps = [
        App(name: "Calculator", bundleID: "com.apple.calculator", targets: ["7"], family: "AppKit"),
        App(name: "Settings", bundleID: "com.apple.systempreferences", targets: ["Generali"], family: "SwiftUI"),
        App(name: "Finder", bundleID: "com.apple.finder", targets: ["Applicazioni"], family: "AppKit"),
        App(name: "Notes", bundleID: "com.apple.Notes", targets: ["Note"], family: "AppKit"),
        App(name: "Mail", bundleID: "com.apple.mail", targets: [], family: "AppKit"),
        App(name: "Safari", bundleID: "com.apple.Safari", targets: [], family: "AppKit+WebKit"),
        App(name: "Pages", bundleID: "com.apple.iWork.Pages", targets: [], family: "AppKit"),
        App(name: "Reminders", bundleID: "com.apple.reminders", targets: [], family: "SwiftUI/AppKit"),
        App(name: "Calendar", bundleID: "com.apple.iCal", targets: [], family: "AppKit"),
        App(name: "Music", bundleID: "com.apple.Music", targets: [], family: "AppKit/Catalyst"),
        App(name: "Preview", bundleID: "com.apple.Preview", targets: [], family: "AppKit"),
        App(name: "TextEdit", bundleID: "com.apple.TextEdit", targets: [], family: "AppKit"),
        App(name: "Xcode", bundleID: "com.apple.dt.Xcode", targets: [], family: "AppKit"),
        App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", targets: [], family: "Electron"),
        App(name: "Notion", bundleID: "notion.id", targets: [], family: "Electron"),
        App(name: "Figma", bundleID: "com.figma.Desktop", targets: [], family: "Electron"),
        App(name: "Spotify", bundleID: "com.spotify.client", targets: [], family: "CEF"),
        App(name: "Voice Memos", bundleID: "com.apple.VoiceMemos", targets: [], family: "Catalyst/SwiftUI"),
    ]

    /// Never launched by the test, because launching them does something: a connection, the camera, a
    /// remote desktop, a system change, a recording, a chat or sync starting, or the session we run in.
    /// They are mapped only when already running.
    nonisolated static let notLaunched: [String: String] = [
        "com.google.Chrome": "never touched by tests",
        "com.anthropic.claudefordesktop": "the session this test runs from",
        "com.apple.MobileSMS": "opens conversations",
        "com.apple.FaceTime": "calls",
        "com.apple.PhotoBooth": "turns the camera on",
        "com.apple.ScreenContinuity": "connects to the iPhone",
        "com.apple.exposelauncher": "changes the desktop view",
        "com.apple.apps.launcher": "changes the desktop view",
        "com.apple.launchpad.launcher": "changes the desktop view",
        "com.apple.Siri": "listens",
        "com.apple.screenshot.launcher": "starts a capture",
        "com.apple.MigrateAssistant": "asks to quit every app",
        "com.apple.bootcampassistant": "system change",
        "com.apple.backup.launcher": "starts a backup",
        "com.apple.VoiceOverUtility": "may turn VoiceOver on",
    ]

    /// Every app in the usual folders, the curated ones with their targets first.
    static func everyApp() -> [App] {
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
        var seen = Set(apps.map(\.bundleID))
        var found: [App] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names.sorted() where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                found.append(App(name: String(name.dropLast(4)), bundleID: id, targets: [], family: family(of: url)))
            }
        }
        return apps + found
    }

    /// What the app is built with, from its frameworks and Info.plist.
    static func family(of url: URL) -> String {
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        if frameworks.contains("Electron Framework.framework") { return "Electron" }
        if frameworks.contains("Chromium Embedded Framework.framework") { return "CEF" }
        if frameworks.contains(where: { $0.hasPrefix("Qt") }) { return "Qt" }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/app.asar").path) { return "Electron" }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Wrapper").path) { return "iOS app" }
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        if info["UIDeviceFamily"] != nil || info["LSRequiresIPhoneOS"] != nil { return "Catalyst" }
        if info["JVMOptions"] != nil || frameworks.contains(where: { $0.contains("Java") }) { return "Java" }
        return "native"
    }

    static let allowedStall = Duration.milliseconds(500)

    struct Row {
        var app: App
        var route = "-"
        var coverage = "-"
        var open = "-"
        var openStall = Duration.zero
        var click = "-"
        var clickStall = Duration.zero
        var outcome = "-"
        /// The front app after this app was opened, clicked and closed, when it is not the person's.
        var frontAfter: String?
        /// The app in front a moment after open or the click, while the app still runs, when it is not
        /// the person's: "open: <bundle id>", "click: <bundle id>".
        var frontLate: [String] = []
        /// What the launch did to the front, from the session's launch log (`MacLaunchLog`).
        var launch = "-"
    }

    @Test("Each installed app: route, coverage, timings, and the main actor never held past half a second",
          .enabled(if: ProcessInfo.processInfo.environment["BRAUS_MAC_LIVE_TESTS"] == "1"
                   && ProcessInfo.processInfo.environment["BRAUS_MAC_MATRIX_TESTS"] == "1"))
    func matrix() async throws {
        let discover = ProcessInfo.processInfo.environment["BRAUS_MAC_MATRIX_DISCOVER"] == "1"
        let only = ProcessInfo.processInfo.environment["BRAUS_MAC_MATRIX_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let skipped = Set((ProcessInfo.processInfo.environment["BRAUS_MAC_MATRIX_SKIP"] ?? "").split(separator: ",").map(String.init))
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let settle = Duration.seconds(Double(ProcessInfo.processInfo.environment["BRAUS_MAC_MATRIX_SETTLE"] ?? "") ?? 2)
        /// The owner of the front window, from the window server (no run loop needed), as a bundle id.
        func frontNow() -> String? {
            LiveMacWorkspace.frontWindowOwner().flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        }
        /// Waits `settle`, then notes a front app that is not the person's and gives the person's back.
        func checkLate(_ phase: String, _ row: inout Row) async {
            try? await Task.sleep(for: settle)
            guard let now = frontNow(), now != front else { return }
            row.frontLate.append("\(phase): \(now)")
            if let front, let app = NSRunningApplication.runningApplications(withBundleIdentifier: front).first {
                app.activate()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        let clock = ContinuousClock()
        let longest = Mutex(Duration.zero)
        let tick = Task { @MainActor in
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                let now = clock.now
                longest.withLock { $0 = max($0, now - last) }
                last = now
            }
        }
        defer { tick.cancel() }
        func takeStall() -> Duration { longest.withLock { value in defer { value = .zero }; return value } }
        func seconds(_ duration: Duration) -> String { String(format: "%.2f s", Double(duration.components.attoseconds) / 1e18 + Double(duration.components.seconds)) }
        func millis(_ duration: Duration) -> String { "\(Int((Double(duration.components.attoseconds) / 1e15).rounded()) + Int(duration.components.seconds) * 1000) ms" }

        var rows: [Row] = []
        let every = ProcessInfo.processInfo.environment["BRAUS_MAC_MATRIX_ALL"] == "1"
        for app in (every ? Self.everyApp() : Self.apps) where only?.contains(app.name) ?? true {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil else { continue }
            var row = Row(app: app)
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
            // Chrome and its app shims (com.google.Chrome.app.*) are never touched, running or not.
            if app.bundleID.hasPrefix("com.google.Chrome") || app.bundleID.hasPrefix("com.google.drivefs") {
                row.route = "not touched: Chrome or Google Drive"
                print("MATRIX \(app.name) | \(app.family) | \(row.route)")
                rows.append(row)
                continue
            }
            if !wasRunning, let why = Self.notLaunched[app.bundleID] ?? (skipped.contains(app.name) ? "BRAUS_MAC_MATRIX_SKIP" : nil) {
                row.route = "not launched: \(why)"
                print("MATRIX \(app.name) | \(app.family) | \(row.route)")
                rows.append(row)
                continue
            }
            let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("mac-matrix-\(UUID().uuidString)")
            let session = MacAutomationSession(knowledgeDirectory: knowledge)
            _ = takeStall()
            let opened = clock.now
            var scene: SceneSnapshot?
            do {
                scene = try await session.open(application: app.bundleID, window: nil)
                row.route = "MacDriver"
            } catch let handoff as MacHandoff {
                row.route = "seat: \(handoff.reason)"
            } catch {
                row.route = "failed: \(error)"
            }
            row.open = seconds(clock.now - opened)
            row.openStall = takeStall()
            if let entry = MacLaunchLog(directory: knowledge).entries().last {
                row.launch = "\(entry.style?.rawValue ?? "running"), reverts \(entry.reverts), self-activated \(entry.selfActivated), "
                    + "restored \(entry.focusRestored), person acted \(entry.personActed), dialog \(entry.dialogInFront)"
            }
            await checkLate("open", &row)
            if let coverage = session.openedCoverage {
                row.coverage = "\(Int((coverage.coveredShare * 100).rounded()))% / \(coverage.actionableCount)"
            }
            if let scene {
                let labels = scene.elements.map(\.label)
                if discover {
                    print("DISCOVER \(app.name): \(scene.elements.prefix(80).map { "\($0.kind.rawValue):\($0.label)" })")
                } else if let target = app.targets.first(where: labels.contains) {
                    let acted = clock.now
                    do {
                        let outcome = try await session.act(target: target, verb: .click, section: nil, desiredState: nil)
                        row.outcome = "'\(target)' \(outcome.kind.rawValue)"
                    } catch {
                        row.outcome = "'\(target)' threw \(error)"
                    }
                    row.click = seconds(clock.now - acted)
                    row.clickStall = takeStall()
                    await checkLate("click", &row)
                } else if !app.targets.isEmpty {
                    row.outcome = "no target in scene"
                } else {
                    row.outcome = "read only"
                }
            }
            await session.close()
            if !wasRunning {
                NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
                try? await Task.sleep(for: .milliseconds(500))
            } else {
                try? await Task.sleep(for: .milliseconds(300))
            }
            let nowFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if nowFront != front {
                row.frontAfter = nowFront ?? "none"
                // Give the person's app back, so the next row starts as this one did.
                if let front, let app = NSRunningApplication.runningApplications(withBundleIdentifier: front).first {
                    app.activate()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            print("MATRIX \(app.name) | \(app.family) | \(row.route) | \(row.coverage) | open \(row.open), stall \(millis(row.openStall)) "
                  + "| \(row.outcome) | click \(row.click), stall \(millis(row.clickStall)) "
                  + "| front late: \(row.frontLate.isEmpty ? "kept" : row.frontLate.joined(separator: ", ")) | launch: \(row.launch)")
            rows.append(row)
        }

        print("| app | family | route | coverage / actionable | open | stall (open) | click | stall (click) | outcome | front after |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        for row in rows {
            print("| \(row.app.name) | \(row.app.family) | \(row.route) | \(row.coverage) | \(row.open) | \(millis(row.openStall)) "
                  + "| \(row.click) | \(row.click == "-" ? "-" : millis(row.clickStall)) | \(row.outcome) | \(row.frontAfter ?? "kept") |")
        }
        for row in rows {
            #expect(row.openStall < Self.allowedStall, "\(row.app.name): the main actor stalled \(row.openStall) during open")
            #expect(row.clickStall < Self.allowedStall, "\(row.app.name): the main actor stalled \(row.clickStall) during the click")
        }
        for row in rows where !row.frontLate.isEmpty {
            Issue.record("\(row.app.name): not the person's app in front while it ran (\(row.frontLate.joined(separator: ", ")))")
        }
        for row in rows where row.frontAfter != nil {
            Issue.record("\(row.app.name): \(row.frontAfter ?? "") was in front afterwards, not the person's app")
        }
    }
}
