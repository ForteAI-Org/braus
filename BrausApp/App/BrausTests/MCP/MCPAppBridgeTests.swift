import CLIProviders
import Darwin
import Foundation
import LocalMCP
import Testing
@testable import Braus

/// Exercises the bundled process, live loopback host and engine adapter using synthetic controls. Whatever the
/// outcome (a failed requirement, a thrown error, a cancellation), the fixture's own resources are released and that
/// release is verified before the test returns: the host stopped, the synthetic client ended, the bridge it spawned
/// ended by its recorded identity (pid, start time and executable: never a pid alone), the folder removed. Nothing
/// else on the machine is touched; a release that cannot be verified fails the test and keeps the folder as evidence.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPAppBridgeTests {
    @Test func bundledBridgeUsesCurrentEngineAndRevocationEndsAnIdleClient() async throws {
        let fixture = try Fixture()
        var failure: (any Error)?
        do { try await fixture.run() } catch { failure = error }
        let problems = await fixture.shutdown()
        #expect(problems.isEmpty, "\(problems)")
        fixture.expectNothingLeft()
        if let failure { throw failure }
    }

    /// A controlled error thrown once the host, the client and its bridge are really up: the same shutdown, verified;
    /// a second shutdown finds nothing left to do.
    @Test func aThrowAfterTheStartLeavesNothingBehind() async throws {
        struct Interrupted: Error {}
        let fixture = try Fixture()
        var failure: (any Error)?
        do { try await fixture.run(afterReady: { throw Interrupted() }) } catch { failure = error }
        #expect(failure is Interrupted, "\(String(describing: failure))")
        let problems = await fixture.shutdown()
        #expect(problems.isEmpty, "\(problems)")
        let again = await fixture.shutdown()
        #expect(again.isEmpty, "\(again)")
        fixture.expectNothingLeft()
    }

    /// The run's task cancelled once the host, the client and its bridge are up, as the suite's time limit would do:
    /// the cancellation surfaces inside the run, the shutdown runs outside the cancelled task and is verified.
    @Test func aCancellationAfterTheStartLeavesNothingBehind() async throws {
        let fixture = try Fixture()
        let run = Task { @MainActor in
            try await fixture.run(afterReady: { try await Task.sleep(for: .seconds(30)) })
        }
        // A readiness that fails (timeout, throw, cancellation) still cancels, joins and releases; its error is
        // thrown after the verified release, and the cancellation is asserted only when readiness was reached.
        var notReady: (any Error)?
        do { try await fixture.waitForReady() } catch { notReady = error }
        run.cancel()
        let result = await run.result
        if notReady == nil {
            var cancelled = false
            if case .failure(let error) = result { cancelled = error is CancellationError }
            #expect(cancelled, "\(result)")
        }
        let problems = await fixture.shutdown()
        #expect(problems.isEmpty, "\(problems)")
        fixture.expectNothingLeft()
        if let notReady { throw notReady }
    }

    /// The test's own resources, held so that `shutdown` reaches them on every path: the folder, the host model, the
    /// synthetic client process and the identity of the bridge that client spawned.
    @MainActor
    private final class Fixture {
        let root: URL
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/braus-bridge")
        let desktop = SyntheticMCPDesktop()
        private(set) var model: MCPConnectionsModel?
        private(set) var process: Process?
        private(set) var bridge: ChildProcessIdentity?
        private(set) var closed = 0
        private var hostStopped = false

        var ready: URL { root.appendingPathComponent("ready") }
        var pidFile: URL { root.appendingPathComponent("bridge.pid") }
        var seenFile: URL { root.appendingPathComponent("bridge.seen") }

        init() throws {
            root = URL.temporaryDirectory.appendingPathComponent("mcp-app-bridge-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// The whole exercise. `afterReady` runs once the host is up, the bridge identified and the client at `ready`
        /// (its select done), before the revocation: where the other tests let an error or a cancellation in.
        func run(afterReady: () async throws -> Void = {}) async throws {
            let model = MCPConnectionsModel(directory: root, executable: executable) { [self] profile, activity in
                let session = ExternalMCPSession(profile: profile, session: desktop, activity: activity)
                return MCPHostSession(router: session.router) { await session.close(); self.closed += 1 }
            }
            self.model = model
            await model.prepare()
            let profile = MCPClientProfile(name: "Synthetic transport")
            model.add(profile)
            await model.waitForIdle()
            model.setEnabled(true, for: profile.id)
            await model.waitForIdle()
            #expect(model.clients.first?.isListening == true)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/python3")
            process.arguments = ["-c", MCPAppBridgeTests.client, executable.path,
                                 model.configuration(for: profile.id).connection.path,
                                 try #require(desktop.id).uuidString, ready.path, pidFile.path, seenFile.path]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            self.process = process
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            // The handshake: the client records its bridge's pid and waits; the identity is taken while the client
            // still holds that bridge, and only then is the client let go.
            var identity: ChildProcessIdentity?
            while identity == nil, process.isRunning, ContinuousClock.now < deadline {
                if let pid = Self.recordedPID(pidFile) { identity = ChildProcessIdentity(running: pid) }
                if identity == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
            bridge = try #require(identity, "the bridge's identity was not taken while the client held it")
            try "seen".write(to: seenFile, atomically: true, encoding: .utf8)
            while !FileManager.default.fileExists(atPath: ready.path), process.isRunning,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(FileManager.default.fileExists(atPath: ready.path))
            #expect(desktop.selections == 1)
            try await afterReady()
            model.revoke(profile.id)
            await model.waitForIdle()
            while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!process.isRunning)
            if !process.isRunning {
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                #expect(process.terminationStatus == 0, "Synthetic client failed: \(text)")
                #expect(text.contains("task_and_revocation_passed"))
            }
            #expect(closed == 1)
            #expect(desktop.id == nil)
        }

        /// Waits, from outside the run, for the client to reach `ready`.
        func waitForReady() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(FileManager.default.fileExists(atPath: ready.path), "the client never reached ready")
        }

        /// Releases what the test made and verifies each release, bounded, and insensitive to the caller's
        /// cancellation: the host stopped and no client listening; the synthetic client ended (SIGTERM, which its
        /// handler turns into the `finally` that kills its bridge, then SIGKILL); the bridge ended, each signal sent
        /// only to a process whose identity is the one recorded; then the folder removed. What could not be verified
        /// comes back as a problem and the folder is kept as evidence. A second call finds nothing left to do.
        func shutdown() async -> [String] {
            var problems: [String] = []
            if let model {
                if !hostStopped { await model.shutdown(); hostStopped = true }
                if model.clients.contains(where: \.isListening) { problems.append("a host client still listens") }
            }
            if let process, process.isRunning {
                process.terminate()
                let terminated = await settled(within: .seconds(5), until: { !process.isRunning })
                if !terminated {
                    kill(process.processIdentifier, SIGKILL)
                    let killed = await settled(within: .seconds(5), until: { !process.isRunning })
                    if !killed { problems.append("the synthetic client \(process.processIdentifier) did not end") }
                }
            }
            if let bridge, Self.stillRuns(bridge) {
                // With its client gone the bridge has launchd as its parent, and endIfOrphaned signals it only if it
                // is still that very process. The fallback checks the identity again right before its signal.
                var ended = bridge.endIfOrphaned()
                if ended { ended = await settled(within: .seconds(5), until: { !Self.stillRuns(bridge) }) }
                if !ended {
                    if Self.stillRuns(bridge) { kill(bridge.pid, SIGKILL) }
                    let killed = await settled(within: .seconds(5), until: { !Self.stillRuns(bridge) })
                    if !killed { problems.append("the bridge \(bridge.pid) did not end") }
                }
            }
            if problems.isEmpty {
                if FileManager.default.fileExists(atPath: root.path) {
                    do { try FileManager.default.removeItem(at: root) }
                    catch { problems.append("the folder was not removed: \(error)") }
                }
            } else {
                problems.append("kept as evidence: \(root.path)")
            }
            return problems
        }

        /// What a verified shutdown leaves: no client process, no process with the bridge's identity, no listening
        /// host client, no folder.
        func expectNothingLeft() {
            #expect(process?.isRunning != true)
            if let bridge { #expect(!Self.stillRuns(bridge)) }
            #expect(model?.clients.contains(where: \.isListening) != true)
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }

        /// Whether the process at the identity's pid is still the very process recorded (same start time and
        /// executable), not a later one given the same pid.
        nonisolated static func stillRuns(_ identity: ChildProcessIdentity) -> Bool {
            ChildProcessIdentity(running: identity.pid) == identity
        }

        nonisolated static func recordedPID(_ file: URL) -> pid_t? {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
            return pid
        }

        /// Polls `condition` every 20 ms for up to `limit`, pausing on a dispatch timer rather than a task sleep so
        /// that a cancelled task waits all the same; whether the condition was met.
        private func settled(within limit: Duration, until condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: limit)
            while !condition() {
                guard ContinuousClock.now < deadline else { return false }
                await Self.pause()
            }
            return true
        }

        nonisolated static func pause() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
            }
        }
    }

    /// The synthetic client. Its SIGTERM handler exits, so the `finally` that kills its bridge runs when the test ends
    /// it; everything after the bridge exists is inside that `try`, the pid record and the handshake included: the
    /// client records the bridge's pid and goes on only once the host has taken the bridge's identity.
    private static let client = #"""
    import json, pathlib, select, signal, subprocess, sys, time
    bridge, endpoint, session, ready, pidfile, seen = sys.argv[1:]
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    child = subprocess.Popen([bridge, 'mcp-bridge', '--connection', endpoint],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        pathlib.Path(pidfile).write_text(str(child.pid))
        for _ in range(500):
            if pathlib.Path(seen).exists():
                break
            time.sleep(0.02)
        else:
            raise AssertionError('the host never took the bridge identity')
        counter = 0
        def rpc(method, params):
            global counter
            counter += 1
            message = {'jsonrpc': '2.0', 'id': counter, 'method': method, 'params': params}
            child.stdin.write((json.dumps(message) + '\n').encode())
            child.stdin.flush()
            assert select.select([child.stdout], [], [], 5)[0], 'MCP response timeout'
            response = json.loads(child.stdout.readline())
            assert response['id'] == counter and 'error' not in response, response
            return response['result']
        def tool(name, args):
            result = rpc('tools/call', {'name': name, 'arguments': args})
            assert not result.get('isError'), result
            assert 'structuredContent' not in result, 'Do not duplicate current main tool output'
            return json.loads(result['content'][0]['text'])
        rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                           'clientInfo': {'name': 'synthetic-client', 'version': '1'}})
        tools = rpc('tools/list', {})['tools']
        assert any(t['name'] == 'select' for t in tools)
        # G76 D1: memory_task, the task the agent declares, is the one memory tool an external client sees.
        assert any(t['name'] == 'memory_task' for t in tools)
        assert not any(t['name'].startswith(('browser_', 'watch_', 'task_'))
                       or (t['name'].startswith('memory_') and t['name'] != 'memory_task') for t in tools)
        tool('select', {'session': session, 'control': 'Mono', 'item': 'Stereo'})
        pathlib.Path(ready).write_text('ready')
        assert child.wait(timeout=10) == 1, 'Host revocation must disconnect the idle bridge'
        assert b'Braus disconnected' in child.stderr.read()
        print('task_and_revocation_passed')
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
    """#
}
