import CoreGraphics
import Foundation
import MacDriver
import Synchronization
import Testing

/// P13, the native slice, offline on the fake workspace and a reader of the test's own: a running application without
/// a window is asked once, in the background, for one (F4), and an application's names are read in each of the person's
/// languages it localizes (F5). Nothing here is a claim about a real application's GUI: a fake workspace, a reader
/// whose window appears only after the request, and temporary bundles with their own tables.
@Suite("P13: the launcher on a running application without a window, and names in the person's languages")
struct MacLauncherIntakeTests {

    static let calendar = MacApp(bundleID: "com.apple.iCal", url: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                                 names: ["Calendar"])
    static let person = MacRunningApp(processID: 42, bundleID: "com.google.Chrome", name: "Google Chrome")
    static let pid: pid_t = 7001
    static let running = MacRunningApp(processID: pid, bundleID: "com.apple.iCal", name: "Calendar")
    static let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
    static let summary = MacWindowSummary(index: 0, role: "AXWindow", subrole: "AXStandardWindow", title: "Calendar",
                                          frame: frame, isMain: true, isFocused: true)

    /// A reader that answers only for the process the workspace holds as running for the application now, and whose
    /// window list is empty until the workspace recorded a launch of it, holding the window from then on: the window
    /// comes because of the request, for the process the request answered, not after a number of reads or for a
    /// process that is gone. `shows` false keeps the list empty whatever was asked; `hasWindow` lists it from the
    /// first read; `failsReads` throws; `holds` keeps one read (the first, or the first after the request) until
    /// `release`, so a test can cancel the open while it waits there.
    final class CausalReader: MacTreeReading, @unchecked Sendable {
        enum Hold { case nothing, firstRead, firstReadAfterRequest }

        let workspace: FakeWorkspace
        let bundleID : String
        let shows    : Bool
        let hasWindow: Bool
        let failsReads: Bool
        let reads = Mutex(0)
        private let gate = Mutex<(hold: Hold, waiting: CheckedContinuation<Void, Never>?)>((.nothing, nil))

        init(_ workspace: FakeWorkspace, bundleID: String = "com.apple.iCal", shows: Bool = true, hasWindow: Bool = false,
             failsReads: Bool = false, holds: Hold = .nothing) {
            self.workspace  = workspace
            self.bundleID   = bundleID
            self.shows      = shows
            self.hasWindow  = hasWindow
            self.failsReads = failsReads
            gate.withLock { $0.hold = holds }
        }

        var isTrusted: Bool { true }

        func release() {
            let waiting = gate.withLock { state -> CheckedContinuation<Void, Never>? in
                state.hold = .nothing
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume()
        }

        func windows(of processID: pid_t) async throws -> [MacWindowSummary] {
            let first = reads.withLock { value -> Bool in
                value += 1
                return value == 1
            }
            let requested = workspace.state.withLock { $0.launches.contains(bundleID) }
            let holdsThis = gate.withLock { state in
                switch state.hold {
                    case .nothing              : false
                    case .firstRead            : first
                    case .firstReadAfterRequest: requested
                }
            }
            if holdsThis {
                await withCheckedContinuation { continuation in
                    let resumeNow = gate.withLock { state -> Bool in
                        guard state.hold != .nothing else { return true }
                        state.waiting = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            if failsReads { throw MacTreeFailure.windowNotFound(index: 0) }
            // Only the process the workspace holds as running now: after the request, the one it answered.
            guard processID == workspace.running(bundleID: bundleID)?.processID else { return [] }
            if hasWindow { return [MacLauncherIntakeTests.summary] }
            return shows && requested ? [MacLauncherIntakeTests.summary] : []
        }

        func read(windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) async throws -> MacTreeRead {
            let tree = Trees.window("Calendar", MacLauncherIntakeTests.frame, children: []).addressed()
            return MacTreeRead(window: tree, nodesVisited: tree.flattened.count)
        }
    }

    /// A workspace whose launches fail, counted, everything else the fake's.
    final class FailingWorkspace: MacWorkspace, @unchecked Sendable {
        let inner: FakeWorkspace
        let attempts = Mutex(0)

        init(inner: FakeWorkspace) { self.inner = inner }

        func installedApplications() -> [MacApp] { inner.installedApplications() }
        func application(bundleID: String) -> MacApp? { inner.application(bundleID: bundleID) }
        func application(at url: URL) -> MacApp? { inner.application(at: url) }
        func running(bundleID: String) -> MacRunningApp? { inner.running(bundleID: bundleID) }
        func frontmost() async -> MacRunningApp? { await inner.frontmost() }
        func launch(_ app: MacApp) async throws -> MacRunningApp {
            attempts.withLock { $0 += 1 }
            throw MacTreeFailure.windowNotFound(index: -1)
        }
        func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp { try await inner.open(items, with: app) }
        func openLink(_ link: URL) async throws { try await inner.openLink(link) }
        func defaultApplication(for item: URL) -> MacApp? { inner.defaultApplication(for: item) }
        func activate(_ processID: pid_t) async { await inner.activate(processID) }
        func secondsSincePersonInput() -> TimeInterval { inner.secondsSincePersonInput() }
    }

    private func launcher(_ workspace: any MacWorkspace, _ reader: any MacTreeReading) -> MacLauncher {
        MacLauncher(workspace: workspace, reader: reader, windowTimeout: .milliseconds(200), pollInterval: .milliseconds(5))
    }

    // MARK: F4

    @Test("running with no window: asked once, in the background, for a window, which comes because of the request, for the process the request answered (the fake answers another than the one found), which is the one reported; the person's app untouched")
    func runningWithoutAWindowIsAskedOnce() async throws {
        let workspace = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running])
        let reader = CausalReader(workspace)
        let report = try await launcher(workspace, reader).open("Calendar")
        #expect(report.wasRunning && report.reopenRequested)
        #expect(workspace.state.withLock(\.launches) == ["com.apple.iCal"], "\(workspace.state.withLock(\.launches))")
        let answered = try #require(workspace.running(bundleID: "com.apple.iCal")?.processID)
        #expect(answered != Self.pid && report.processID == answered, "the process the request answered: \(report.processID)")
        #expect(report.window?.title == "Calendar", "\(String(describing: report.window))")
        #expect(reader.reads.withLock { $0 } >= 2, "the first read found none, a later one the window")
        #expect(workspace.state.withLock(\.activations).isEmpty && !report.selfActivated && !report.personActedMeanwhile)
    }

    @Test("a reopened app that comes forward is settled like a launched one: said self-activated, the person's app brought back when they did not act, left as they set it when they did, and left in front for the seat when it could not be brought back")
    func aReopenThatComesForwardIsSettled() async throws {
        let idle = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running], selfActivates: true)
        let restored = try await launcher(idle, CausalReader(idle)).open("Calendar")
        #expect(restored.reopenRequested && restored.selfActivated && restored.focusRestored && !restored.personActedMeanwhile
                && !restored.leftInFront, "\(restored)")
        #expect(idle.state.withLock(\.activations) == [42])

        let acting = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running], selfActivates: true)
        acting.personActsNow()
        let left = try await launcher(acting, CausalReader(acting)).open("Calendar")
        #expect(left.reopenRequested && left.selfActivated && !left.focusRestored && left.personActedMeanwhile && !left.leftInFront,
                "\(left)")
        #expect(acting.state.withLock(\.activations).isEmpty)

        let stuck = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running], selfActivates: true)
        stuck.state.withLock { $0.ignoresActivation = true }
        let front = try await launcher(stuck, CausalReader(stuck)).open("Calendar")
        #expect(front.reopenRequested && front.selfActivated && !front.focusRestored && !front.personActedMeanwhile
                && front.leftInFront, "\(front)")
    }

    @Test("an open cancelled while it waits after the request is settled first: the app brought forward is given back when the person did not act, left when they did, the cancellation thrown, the request not repeated")
    func cancelledAfterTheRequestIsSettled() async throws {
        for personActs in [false, true] {
            let workspace = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running], selfActivates: true)
            if personActs { workspace.personActsNow() }
            let reader = CausalReader(workspace, shows: false, holds: .firstReadAfterRequest)
            let launcher = launcher(workspace, reader)
            let opening = Task { try await launcher.open("Calendar") }
            while !workspace.state.withLock({ $0.launches.contains("com.apple.iCal") }) { await Task.yield() }
            while reader.reads.withLock({ $0 }) < 2 { await Task.yield() }
            opening.cancel()
            reader.release()
            await #expect(throws: CancellationError.self) { _ = try await opening.value }
            #expect(workspace.state.withLock(\.launches) == ["com.apple.iCal"], "asked once, not again")
            #expect(workspace.state.withLock(\.activations) == (personActs ? [] : [42]), "personActs \(personActs)")
        }
    }

    @Test("running with a window: nothing is asked of the application")
    func runningWithAWindowIsLeftAlone() async throws {
        let workspace = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running])
        let report = try await launcher(workspace, CausalReader(workspace, hasWindow: true)).open("Calendar")
        #expect(report.wasRunning && !report.reopenRequested && report.window?.title == "Calendar")
        #expect(workspace.state.withLock(\.launches).isEmpty)
    }

    @Test("running with no window that shows none after the request: reported as no window with the request made, not thrown, asked once only, the wait kept")
    func runningWithoutAWindowThatStaysWithout() async throws {
        let workspace = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running])
        let report = try await launcher(workspace, CausalReader(workspace, shows: false)).open("Calendar")
        #expect(report.wasRunning && report.reopenRequested && report.window == nil && report.secondsWaited >= 0.2)
        #expect(workspace.state.withLock(\.launches) == ["com.apple.iCal"], "\(workspace.state.withLock(\.launches))")
    }

    @Test("a read that fails is no reason to ask: nothing is asked, and no window is reported")
    func aFailedReadAsksNothing() async throws {
        let workspace = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running])
        let report = try await launcher(workspace, CausalReader(workspace, failsReads: true)).open("Calendar")
        #expect(report.wasRunning && !report.reopenRequested && report.window == nil)
        #expect(workspace.state.withLock(\.launches).isEmpty)
    }

    @Test("a request that fails is not repeated: the error is thrown, one attempt made, the person's app left as it was")
    func aFailedRequestIsNotRepeated() async throws {
        let inner = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running])
        let workspace = FailingWorkspace(inner: inner)
        await #expect(throws: MacTreeFailure.self) {
            _ = try await launcher(workspace, CausalReader(inner)).open("Calendar")
        }
        #expect(workspace.attempts.withLock { $0 } == 1)
        #expect(inner.state.withLock(\.activations).isEmpty && inner.state.withLock(\.front) == Self.person)
    }

    @Test("an open cancelled before the request asks nothing")
    func cancelledBeforeTheRequestAsksNothing() async throws {
        let workspace = FakeWorkspace(apps: [Self.calendar], front: Self.person, running: [Self.running])
        let reader = CausalReader(workspace, holds: .firstRead)
        let launcher = launcher(workspace, reader)
        let opening = Task { try await launcher.open("Calendar") }
        while reader.reads.withLock({ $0 }) == 0 { await Task.yield() }
        opening.cancel()
        reader.release()
        await #expect(throws: CancellationError.self) { _ = try await opening.value }
        #expect(workspace.state.withLock(\.launches).isEmpty)
    }

    @Test("not running: launched as before, no request on top")
    func notRunningIsLaunchedOnce() async throws {
        let workspace = FakeWorkspace(apps: [Self.calendar], front: Self.person)
        let reader = FakeTreeReader(isTrusted: true, windows: [500: [(Self.summary, Trees.window("Calendar", Self.frame, children: []))]],
                                    windowAfterPolls: 1)
        let report = try await launcher(workspace, reader).open("Calendar")
        #expect(!report.wasRunning && !report.reopenRequested && report.processID == 500)
        #expect(workspace.state.withLock(\.launches) == ["com.apple.iCal"])
    }

    // MARK: F5

    /// A bundle with an Info.plist, its `.lproj` folders, and either a loctable or per-language strings files.
    static func bundle(_ name: String, id: String, in root: URL, loctable: [String: [String: String]]? = nil,
                       strings: [String: [String: String]] = [:]) throws -> URL {
        let files = FileManager.default
        let app = root.appending(path: "\(name).app")
        let resources = app.appending(path: "Contents/Resources")
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name,
                                   "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        for language in Set((loctable?.keys.map { $0 } ?? []) + strings.keys) {
            try files.createDirectory(at: resources.appending(path: "\(language).lproj"), withIntermediateDirectories: true)
        }
        if let loctable {
            try PropertyListSerialization.data(fromPropertyList: loctable, format: .xml, options: 0)
                .write(to: resources.appending(path: "InfoPlist.loctable"))
        }
        for (language, names) in strings {
            try PropertyListSerialization.data(fromPropertyList: names, format: .xml, options: 0)
                .write(to: resources.appending(path: "\(language).lproj/InfoPlist.strings"))
        }
        return app
    }

    @Test("names come from each of the person's languages the bundle localizes, in their order, the first first and unchanged: en-IT and it-IT read Calendar and Calendario, Notes and Note; en alone reads the English; a loctable and strings files alike")
    func namesInThePersonsLanguages() throws {
        let root = URL.temporaryDirectory.appending(path: "p13-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.bundle("Calendar", id: "com.example.cal", in: root, loctable: [
            "en": ["CFBundleDisplayName": "Calendar", "CFBundleName": "Calendar"],
            "it": ["CFBundleDisplayName": "Calendario", "CFBundleName": "Calendario"],
            "de": ["CFBundleDisplayName": "Kalender", "CFBundleName": "Kalender"],
        ])
        _ = try Self.bundle("Notes", id: "com.example.notes", in: root, strings: [
            "en": ["CFBundleDisplayName": "Notes"], "it": ["CFBundleDisplayName": "Note"],
        ])
        let italianToo = LiveMacWorkspace(folders: [root], preferredLanguages: ["en-IT", "it-IT"])
        let apps = Dictionary(uniqueKeysWithValues: italianToo.installedApplications().map { ($0.bundleID, $0) })
        #expect(apps["com.example.cal"]?.names.first == "Calendar" && apps["com.example.cal"]?.names.contains("Calendario") == true
                && apps["com.example.cal"]?.names.contains("Kalender") == false, "\(String(describing: apps["com.example.cal"]?.names))")
        #expect(apps["com.example.notes"]?.names.first == "Notes" && apps["com.example.notes"]?.names.contains("Note") == true,
                "\(String(describing: apps["com.example.notes"]?.names))")
        let englishOnly = LiveMacWorkspace(folders: [root], preferredLanguages: ["en"])
        let english = Dictionary(uniqueKeysWithValues: englishOnly.installedApplications().map { ($0.bundleID, $0) })
        #expect(english["com.example.cal"]?.names.contains("Calendario") == false && english["com.example.notes"]?.names.contains("Note") == false)
        let italianFirst = LiveMacWorkspace(folders: [root], preferredLanguages: ["it-IT", "en-IT"])
        #expect(italianFirst.installedApplications().first { $0.bundleID == "com.example.cal" }?.names.first == "Calendario")
        // The launcher then finds the application by the Italian name, and by the English one as before.
        let reader = FakeTreeReader(isTrusted: true, windows: [:])
        let launcher = MacLauncher(workspace: italianToo, reader: reader)
        #expect(try launcher.resolve("Calendario").bundleID == "com.example.cal")
        #expect(try launcher.resolve("Note").bundleID == "com.example.notes")
        #expect(try launcher.resolve("Notes").bundleID == "com.example.notes")
        #expect(throws: MacLaunchFailure.notFound("Kalender")) { try launcher.resolve("Kalender") }
        #expect(throws: MacLaunchFailure.notFound("Calendario")) {
            try MacLauncher(workspace: englishOnly, reader: reader).resolve("Calendario")
        }
    }
}
