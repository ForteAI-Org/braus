import AppKit
@testable import AutomationRuntime
import Foundation
import MacDriver
@testable import MacSession
import PerceptionCore
import Router
import Synchronization
@testable import SeatBroker
import SeatDriving
import Testing

/// I03: one owner drives an app at a time, by its bundle ID, on the native route, on the seat and across Braus
/// processes. A session's hold is its own: giving it back, or the session going away, never frees another's, and the
/// last hold given back frees the app for any other process. Offline: a temporary lock folder per test, the MacDriver
/// on fakes, the seat's opening supplied in place of the broker's (nothing is adopted, no display is raised), and a
/// `perl` process taking the same lock as another Braus process would, stopped only by its recorded process ID.
@MainActor
@Suite("I03: app claims", .serialized, .timeLimit(.minutes(1)))
struct AppClaimsTests {

    static let notes = MacSessionTests.notes.bundleID

    /// One test's temporary folders: the lock folder and the sessions' knowledge, removed once the test let every
    /// hold go.
    struct Root {
        let url = FileManager.default.temporaryDirectory.appending(path: "braus-claims-test-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        var namespace: URL { url.appending(path: "claims", directoryHint: .isDirectory) }
        func knowledge() -> URL { url.appending(path: "knowledge-\(UUID().uuidString)", directoryHint: .isDirectory) }
    }

    /// Runs `body` in a root of its own, removed after `body` returned or threw, so its claims, holds and sessions
    /// are gone.
    static func inRoot(_ body: (Root) async throws -> Void) async throws {
        let root = Root()
        do { try await body(root) } catch {
            try? FileManager.default.removeItem(at: root.url)
            throw error
        }
        try? FileManager.default.removeItem(at: root.url)
        #expect(!FileManager.default.fileExists(atPath: root.url.path))
    }

    static func refusal(_ result: Result<AppClaims.Hold, AppClaims.Refusal>) -> AppClaims.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    /// Waits, a few milliseconds at a time and for at most two seconds, until `condition` holds.
    static func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: Holds

    @Test("one owner's holds are each their own: dropping one keeps the app exclusive, dropping the last frees it")
    func holdsAreEachTheirOwn() async throws {
        try await Self.inRoot { root in
            let claims = AppClaims(namespace: root.namespace)
            var first : AppClaims.Hold? = try claims.acquire(Self.notes, owner: "worker-a").get()
            var second: AppClaims.Hold? = try claims.acquire(Self.notes, owner: "worker-a").get()
            #expect(Self.refusal(claims.acquire(Self.notes, owner: "worker-b")) == .heldHere)
            #expect(first != nil)
            first = nil
            #expect(Self.refusal(claims.acquire(Self.notes, owner: "worker-b")) == .heldHere, "the other hold remains")
            #expect(claims.isHeld(Self.notes) && second != nil)
            second = nil
            #expect(!claims.isHeld(Self.notes))
            let other = try claims.acquire(Self.notes, owner: "worker-b").get()
            #expect(other.bundleID == Self.notes)
        }
    }

    @Test("a bundle ID is a file name inside the lock folder: no separator, no parent, nothing but safe characters")
    func fileNamesStayInTheFolder() {
        for id in ["../../etc/passwd", "a/b", "..", "com.example.notes", "é ü"] {
            let name = AppClaims.fileName(of: id)
            #expect(!name.contains("/") && name != "..lock" && name.hasSuffix(".lock"), "\(id) → \(name)")
            #expect(name.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-%")
                    .contains($0)
            })
        }
        #expect(AppClaims.fileName(of: "com.example.notes") == "com.example.notes.lock")
    }

    @Test("a link in place of the lock file is not followed: the claim is refused, the link's target untouched")
    func aLinkIsNotFollowed() async throws {
        try await Self.inRoot { root in
            let folder = root.namespace
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = root.url.appending(path: "elsewhere")
            try Data("kept".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: folder.appending(path: AppClaims.fileName(of: Self.notes)),
                                                       withDestinationURL: target)
            let claims = AppClaims(namespace: folder)
            guard case .unavailable? = Self.refusal(claims.acquire(Self.notes, owner: "worker-a")) else {
                Issue.record("a linked lock file was followed")
                return
            }
            #expect(try Data(contentsOf: target) == Data("kept".utf8))
        }
    }

    // MARK: Another process

    /// A `perl` process taking the lock file of `bundleID` in `folder` as another Braus process would. It is ended
    /// only through the process this test started, by its recorded process ID, and always waited for.
    final class OtherProcess {
        static let script = """
            use Fcntl qw(:flock O_RDWR O_CREAT);
            sysopen(my $f, $ARGV[0], O_RDWR|O_CREAT) or exit 2;
            exit 3 unless flock($f, LOCK_EX|LOCK_NB);
            exit 0 if $ARGV[1] eq "try";
            $| = 1; print "locked\\n"; <STDIN>;
            """

        let process = Process()
        let input   = Pipe()
        let output  = Pipe()

        /// Whether the lock could be taken by another process now; it lets it go at once.
        static func tryLock(_ folder: URL, _ bundleID: String) async throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", script, folder.appending(path: AppClaims.fileName(of: bundleID)).path, "try"]
            try process.run()
            await ended(process)
            return process.terminationStatus == 0
        }

        /// Waits at most two seconds for `process` to end, then kills it by its recorded ID and waits for it.
        static func ended(_ process: Process) async {
            if !(await AppClaimsTests.until { !process.isRunning }) {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        /// Starts a process that holds the lock until its input closes or it is killed.
        init(holding bundleID: String, in folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", Self.script, folder.appending(path: AppClaims.fileName(of: bundleID)).path,
                                 "hold"]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            // The line comes once the lock is taken; an end of file, when the process ended without it.
            let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            guard line == "locked\n" else {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw AutomationFailure("the fixture did not lock: \(line)")
            }
        }

        /// Ends the process normally, by closing its input, and waits for it.
        func exit() async {
            try? input.fileHandleForWriting.close()
            await Self.ended(process)
        }

        /// Kills the process by the ID recorded when it started, as a crash would end it, and waits for it.
        func crash() {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        /// Whatever happened in the test: the process is ended and waited for.
        func end() {
            if process.isRunning { crash() }
        }
    }

    @Test("another process cannot take the app while a hold lives here; dropping one of two holds keeps it out; the last frees it")
    func anotherProcessWaitsForTheLastHold() async throws {
        try await Self.inRoot { root in
            let folder = root.namespace
            let claims = AppClaims(namespace: folder)
            var first : AppClaims.Hold? = try claims.acquire(Self.notes, owner: "worker-a").get()
            var second: AppClaims.Hold? = try claims.acquire(Self.notes, owner: "worker-a").get()
            #expect(try await !OtherProcess.tryLock(folder, Self.notes))
            #expect(first != nil)
            first = nil
            #expect(try await !OtherProcess.tryLock(folder, Self.notes), "one of the owner's holds still lives")
            #expect(second != nil)
            second = nil
            #expect(try await OtherProcess.tryLock(folder, Self.notes), "the last hold dropped frees the app")
            let file = folder.appending(path: AppClaims.fileName(of: Self.notes))
            #expect(FileManager.default.fileExists(atPath: file.path), "the lock file stays for whoever waits on it")
        }
    }

    @Test("an app another process holds is refused here, and free once that process exits or crashes")
    func anotherProcessHoldsUntilItEnds() async throws {
        try await Self.inRoot { root in
            let claims = AppClaims(namespace: root.namespace)
            for ending in ["exit", "crash"] {
                let other = try OtherProcess(holding: Self.notes, in: root.namespace)
                defer { other.end() }
                #expect(Self.refusal(claims.acquire(Self.notes, owner: "worker-a")) == .heldElsewhere, "\(ending)")
                #expect(!claims.isHeld(Self.notes))
                if ending == "exit" { await other.exit() } else { other.crash() }
                let hold = try claims.acquire(Self.notes, owner: "worker-a").get()
                #expect(hold.bundleID == Self.notes, "\(ending)")
            }
        }
    }

    // MARK: The native route and the seat

    /// What the seat's opening was asked for: nothing is adopted, the Dock's process stands in for the app.
    final class Seated {
        var opened: [String] = []
    }

    static func native(_ claims: AppClaims, _ root: Root, owner: AnyHashable,
                       tree: MacTreeNode = MacSessionTests.rich) -> (MacAutomationSession, TreeStub, WorkspaceStub) {
        let reader = TreeStub(tree), workspace = WorkspaceStub()
        let roles = MacRoles(reader: reader, actor: reader, delivery: NoDelivery(), person: nil,
                             notifications: QuietNotifications(), controls: NoControls(),
                             serverWindows: { _ in [(number: 7, frame: MacSessionTests.frame)] })
        return (MacAutomationSession(knowledgeDirectory: root.knowledge(), roles: roles, workspace: workspace,
                                     leases: claims, leaseOwner: owner), reader, workspace)
    }

    static func seat(_ claims: AppClaims, _ root: Root, worker: UUID, _ seated: Seated,
                     seating: (@MainActor () async throws -> Void)? = nil) throws
        -> (SeatBroker, BrokeredAutomationSession) {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = SceneSnapshot(bundleID: notes, appName: "Notes", windowTitle: "Notes",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let broker = SeatBroker()
        let session = BrokeredAutomationSession(
            broker            : broker,
            workerID          : worker,
            knowledgeDirectory: root.knowledge(),
            allowsDestructive : false,
            claims            : claims,
            resolving         : { word in word == "Notes" || word == notes ? notes : word },
            missingGrant      : { nil },
            requestGrants     : {},
            seating           : { _, bundleID, _ in
                seated.opened.append(bundleID)
                try await seating?()
                return (TargetApp(pid: dock, bundleID: bundleID, name: "Notes", bundleURL: nil, windows: []),
                        SeatTarget())
            },
            perceiving        : { _, _ in scene }
        )
        return (broker, session)
    }

    @Test("the native route holding an app: another worker's seat is refused before it opens anything, and opens it once the app is given back")
    func nativeFirstRefusesTheSeat() async throws {
        try await Self.inRoot { root in
            let claims = AppClaims(namespace: root.namespace)
            let seated = Seated()
            let (native, _, _) = Self.native(claims, root, owner: AnyHashable(UUID()))
            let (broker, seat) = try Self.seat(claims, root, worker: UUID(), seated)
            _ = try await native.open(application: "Notes", window: nil)
            do {
                _ = try await seat.open(application: "Notes", window: nil)
                Issue.record("the seat opened an app another owner drives")
            } catch let refusal as AutomationFailure {
                #expect(refusal.description.contains("being driven by another Braus worker or client"), "\(refusal)")
            }
            #expect(seated.opened.isEmpty && seat.id == nil, "nothing launched or adopted on the seat")
            #expect(broker.queue.entries.isEmpty, "the seat was given back")
            await native.close()
            _ = try await seat.open(application: "Notes", window: nil)
            #expect(seated.opened == [Self.notes] && seat.id != nil)
            await seat.close()
            #expect(!claims.isHeld(Self.notes), "closing the seat gave the app back")
        }
    }

    @Test("the seat holding an app: another worker's native route is refused with nothing launched or sent, and opens it once the seat closes")
    func seatFirstRefusesTheNativeRoute() async throws {
        try await Self.inRoot { root in
            let claims = AppClaims(namespace: root.namespace)
            let seated = Seated()
            let (_, seat) = try Self.seat(claims, root, worker: UUID(), seated)
            let (native, tree, workspace) = Self.native(claims, root, owner: AnyHashable(UUID()))
            _ = try await seat.open(application: "Notes", window: nil)
            do {
                _ = try await native.open(application: "Notes", window: nil)
                Issue.record("the native route opened an app another owner drives")
            } catch let refusal as AutomationFailure {
                #expect(refusal.description.contains("being driven by another Braus worker or client"), "\(refusal)")
            }
            #expect(native.id == nil)
            #expect(workspace.running.withLock { $0.isEmpty } && tree.steps.withLock { $0.isEmpty },
                    "nothing reached it")
            await seat.close()
            _ = try await native.open(application: "Notes", window: nil)
            #expect(native.id != nil)
            await native.close()
            #expect(!claims.isHeld(Self.notes))
        }
    }

    @Test("a native handoff to the same worker's seat keeps the app claimed throughout: no other owner can take it between")
    func handoffKeepsTheClaim() async throws {
        try await Self.inRoot { root in
            let claims = AppClaims(namespace: root.namespace)
            let worker = UUID()
            let seated = Seated()
            var duringSeating: AppClaims.Refusal?
            let (native, _, _) = Self.native(claims, root, owner: AnyHashable(worker), tree: MacSessionTests.sparse)
            let (_, seat) = try Self.seat(claims, root, worker: worker, seated) {
                duringSeating = Self.refusal(claims.acquire(Self.notes, owner: "another-worker"))
            }
            let router = RoutingAutomationSession(native: native, desktop: seat)
            _ = try await router.open(application: "Notes", window: nil)
            #expect(router.lastHandoff != nil && seated.opened == [Self.notes], "handed to the seat")
            #expect(duringSeating == .heldHere, "the native hold lasted until the seat held the app")
            #expect(Self.refusal(claims.acquire(Self.notes, owner: "another-worker")) == .heldHere)
            await router.close()
            #expect(!claims.isHeld(Self.notes), "the native hold went with the handoff, the seat's with its close")
        }
    }

    @Test("an open cancelled while the seat opens the app gives the claim back, as a session that goes away does")
    func cancelledOrDroppedGivesTheClaimBack() async throws {
        try await Self.inRoot { root in
            let claims = AppClaims(namespace: root.namespace)
            let seated = Seated()
            let (broker, seat) = try Self.seat(claims, root, worker: UUID(), seated) {
                try await Task.sleep(for: .seconds(30))
            }
            let opening = Task { try await seat.open(application: "Notes", window: nil) }
            defer { opening.cancel() }
            try #require(await Self.until { !seated.opened.isEmpty }, "the seat's opening was reached")
            #expect(claims.isHeld(Self.notes))
            opening.cancel()
            _ = await opening.result
            #expect(seat.id == nil && broker.queue.entries.isEmpty)
            #expect(!claims.isHeld(Self.notes), "the cancelled open gave the app back")

            var native: MacAutomationSession? = Self.native(claims, root, owner: AnyHashable(UUID())).0
            _ = try await native?.open(application: "Notes", window: nil)
            #expect(claims.isHeld(Self.notes))
            native = nil
            #expect(!claims.isHeld(Self.notes), "a session that went away without closing let its hold go")
        }
    }
}
