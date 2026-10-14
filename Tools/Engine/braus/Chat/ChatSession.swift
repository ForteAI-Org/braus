//
//  ChatSession.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Darwin
import FileConversations
import Foundation
import LocalMCP
import Memory
import PrivateSymbols
import SeatBroker

/// ChatSession is the host of a chat in this process: the tools over one automation session and the shared memory,
/// the MCP host the provider's subprocess reaches through `braus mcp-bridge`, the provider adapter, and the stop on
/// Ctrl+C. One per process, since the Seat belongs to it until release or shutdown; the interactive chat and the
/// script run their turns on it, each with the transcript of the moment (`current`), which the tool lines and a stop
/// are written to and whose conversation the memory records the calls as.
@MainActor
final class ChatSession {
    /// Where the memory lives: `--knowledge`, or the one Knowledge directory the app shares.
    let knowledge: URL
    /// The app's broker in this process: the Seat's queue and display, and the launch of applications.
    let broker: SeatBroker
    /// The application session the app's workers have, so the chat opens what the app opens.
    let desktop: BrokeredAutomationSession
    let tools: ChatTools
    let router: MCPRouter
    let host: LocalMCPHost
    let provider = CLIProvider()
    let executable: URL
    let working: URL
    private let temporary: URL
    private let connectionFile: URL
    private var signals: ChatSignals?
    /// The transcript the tool lines and a stop are written to now.
    private(set) var current: ChatTranscript?
    /// The stop a Ctrl+C started; a turn that fails while it runs waits for it and returns.
    private(set) var shutdown: Task<Void, Never>?

    init(options: ChatOptions, history: URL, executable: URL) throws {
        self.executable = executable
        knowledge = options.knowledgeDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? EngineRuntime.sharedKnowledge()
        if options.allowUnvalidated {
            FacilityGate.researchOptInForUnvalidatedBuilds = true
            print("seat: research opt-in for an unvalidated macOS build")
        }
        // The same session the app's workers have (TeamModel): `apps` lists the installed applications, `open_session`
        // launches one that is not running on the Seat's display and records that the agent opened it, and the run's
        // frames go to `Runs` beside the knowledge. The command line's own `AutomationSession`, which the vertical
        // commands keep, adopts windows of running applications only.
        let broker = SeatBroker(configuration: SeatBrokerConfiguration(
            allowUnvalidatedBuild: options.allowUnvalidated,
            recordingDirectory: knowledge.deletingLastPathComponent().appendingPathComponent("Runs", isDirectory: true)))
        let desktop = BrokeredAutomationSession(broker: broker, workerID: UUID(), knowledgeDirectory: knowledge,
                                                allowsDestructive: options.allowDestructive)
        self.broker = broker
        self.desktop = desktop
        let tools = ChatTools(session: desktop)
        self.tools = tools
        router = MCPRouter(tools: ChatTools.definitions) { name, arguments in try await tools.call(name, arguments) }
        host = LocalMCPHost(router: router)
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("braus-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        connectionFile = temporary.appendingPathComponent("connection.json")
        working = history.appendingPathComponent("ProviderWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        tools.record = { [weak self] text in
            print("  \(text.prefix(240))")
            try self?.current?.append(.tool, text)
        }
    }

    /// Starts the MCP host the provider connects to and arms the stop on Ctrl+C and SIGTERM.
    func start() async throws {
        let endpoint = try await host.start()
        try JSONEncoder().encode(endpoint).write(to: connectionFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionFile.path)
        signals = ChatSignals { [unowned self] in
            router.pause()
            provider.cancel()
            shutdown = Task { [self] in
                await router.drain()
                await tools.session.close()
                await broker.queue.shutdown()
                await provider.waitUntilStopped()
                do { try current?.append(.interrupted, "Interrupted. Inspect the current app state before continuing.") }
                catch { fputs("braus: transcript save failed: \(error)\n", stderr) }
                host.stop()
                do { try FileManager.default.removeItem(at: temporary) }
                catch { fputs("braus: temporary cleanup failed: \(error)\n", stderr) }
                if let current {
                    print("\nStopped; conversation saved. Resume with --resume \(current.conversation.id.uuidString)")
                } else {
                    print("\nStopped.")
                }
                exit(130)
            }
        }
    }

    /// Stops the host and removes the private connection file; the Seat was released by the caller.
    func stop() {
        signals?.stop()
        signals = nil
        host.stop()
        do { try FileManager.default.removeItem(at: temporary) }
        catch { fputs("braus: could not remove temporary chat configuration: \(error)\n", stderr) }
    }

    /// Makes `transcript` the conversation of the next turns: the tool lines go to it, and the memory records the
    /// calls as its conversation's stream.
    func adopt(_ transcript: ChatTranscript) {
        current = transcript
        let id = transcript.conversation.id.uuidString
        tools.producer = CallProducer(source: .cli, streamID: "chat-" + id, traceID: id)
    }

    /// One turn of the provider on the current transcript, with the first scene of the turn sent whole again: a
    /// resumed provider context may have been compacted. The Seat is held for the whole turn, as a worker's is;
    /// between turns the session keeps it warm for a while, then gives it back.
    func turn(_ message: String) async throws {
        guard let transcript = current else { throw ChatMenu.problem("No conversation to run the turn in.") }
        tools.forgetScene()
        let turn = ProviderTurn(
            provider: transcript.conversation.provider, model: transcript.conversation.model,
            sessionID: transcript.conversation.providerSessionID, prompt: message,
            instructions: ChatTools.instructions, bridgeExecutable: Self.executablePath,
            connectionFile: connectionFile.path, workingDirectory: working.path
        )
        try await desktop.turn {
            try await provider.run(turn, executable: executable) { event in try transcript.event(event) }
        }
    }

    /// Ends the broker's queue once the last session was closed: the parked Seat takes its display down.
    func finish() async {
        await tools.session.close()
        await broker.queue.shutdown()
    }

    /// Releases the Seat and the application session, with the router paused while the calls in flight drain.
    func releaseSeat() async {
        router.pause()
        await router.drain()
        await tools.session.close()
        router.resume()
    }

    static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
