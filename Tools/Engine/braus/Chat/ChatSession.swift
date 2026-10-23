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
import MacSession
import Memory
import PrivateSymbols
import Router
import SeatBroker
import TaskRouting
import WebDriver
import WebSession

/// ChatSession is the host of a chat in this process: the tools over one automation session and the shared memory,
/// the MCP host the provider's subprocess reaches through `braus mcp-bridge`, the provider adapter, and the stop on
/// Ctrl+C. One per process, since the Seat belongs to it until release or shutdown; the interactive chat and the
/// script run their turns on it, each with the transcript of the moment (`current`), which the tool lines and a stop
/// are written to and whose conversation the memory records the calls as.
///
/// A turn's authority is the turn's own (I02), as a worker's is in the app: each turn starts a loopback host of its
/// own, with an endpoint, a token and a connection file of its own, and the router admits calls only while the turn
/// runs. Once the turn ends, however it ends, the router is paused and drained, that host stops with every
/// connection it served, and its file goes, so a client or a file of an earlier turn or conversation acts on nothing
/// later. Nothing resumes the router between turns.
///
/// Beyond the Seat, the chat composes only the routes `--channels` names, as the app's workers do (P10): `native`,
/// `adapters` and `web` (the chat's own headless Chrome, `chatChrome`).
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
    /// The chat's own Chrome (`--channels web`); nil without the channel.
    let web: WebAutomationSession?
    /// The routes `--channels` names.
    let channels: AutomationChannels
    /// Whether `finish` ran: it runs once.
    private var finished = false
    /// The running turn's loopback host and connection file; nil between turns.
    private var host: LocalMCPHost?
    private var connectionFile: URL?
    let provider = CLIProvider()
    let executable: URL
    let working: URL
    /// The reasoning effort every turn asks of the provider, nil for its default.
    private let effort: String?
    private let temporary: URL
    private var signals: ChatSignals?
    /// The transcript the tool lines and a stop are written to now.
    private(set) var current: ChatTranscript?
    /// The stop a Ctrl+C started; a turn that fails while it runs waits for it and returns.
    private(set) var shutdown: Task<Void, Never>?
    /// Whether a stop closes the task it cut as abandoned: a script's run has no one to resume it, an interactive chat
    /// keeps it open for `--resume`.
    var closesTaskOnStop = false
    /// What a script writes of the request a stop cut (its evidence), told the signal, what Braus closed and how many of
    /// the transcript's entries came before Braus's own calls.
    var interruption: ((Int32, Abandonment?, Int) async -> Void)?

    /// Abandonment is a task Braus closed as abandoned because the conversation did not end it: whether the close was
    /// recorded, and the archive's answer when it was not.
    struct Abandonment {
        let task: String
        let closed: Bool
        let problem: String?
    }

    /// `session` composes the session the tools drive over the desktop, in place of `ChatSession.session`: a seam for
    /// the tests, which drive no Seat.
    init(
        options   : ChatOptions,
        history   : URL,
        executable: URL,
        session   : ((BrokeredAutomationSession) -> any AutomationSessionOperating)? = nil
    ) throws {
        self.executable = executable
        effort = options.effort
        knowledge = options.knowledgeDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? EngineRuntime.sharedKnowledge()
        if options.allowUnvalidated {
            FacilityGate.researchOptInForUnvalidatedBuilds = true
            print("seat: research opt-in for an unvalidated macOS build")
        }
        // The same session the app's workers have (TeamModel): `apps` lists the installed applications, `open_session`
        // launches one that is not running on the Seat's display and records that the agent opened it, and the run's
        // frames go to `Runs` beside the knowledge. A missing permission names the terminal, as `BrokeredSeat` does.
        let broker = SeatBroker(configuration: SeatBrokerConfiguration(
            allowUnvalidatedBuild: options.allowUnvalidated,
            recordingDirectory: knowledge.deletingLastPathComponent().appendingPathComponent("Runs", isDirectory: true)))
        // One owner for the chat's native session and its Seat, so a handoff between them keeps the app (AppClaims).
        let owner = UUID()
        let desktop = BrokeredAutomationSession(broker: broker, workerID: owner, knowledgeDirectory: knowledge,
                                                allowsDestructive: options.allowDestructive, grantee: BrokeredSeat.grantee)
        self.broker = broker
        self.desktop = desktop
        let web = options.channels.contains(.web) ? Self.chatChrome(options: options, history: history,
                                                                    knowledge: knowledge) : nil
        self.web = web
        channels = options.channels
        let driven = try session?(desktop)
            ?? Self.session(desktop: desktop, options: options, knowledge: knowledge, owner: owner, web: web)
        let tools = ChatTools(session: driven, channels: options.channels)
        self.tools = tools
        router = MCPRouter(tools: tools.toolDefinitions) { name, arguments in
            return try await tools.call(name, arguments)
        }
        // Calls are admitted only during a turn, through that turn's own host.
        router.pause()
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("braus-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        working = history.appendingPathComponent("ProviderWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // A chat's tasks always search what was learned; a run that must not use it turns the Recall off itself.
        tools.recallAlwaysOn = true
        tools.record = { [weak self] text in
            print("  \(text.prefix(240))")
            try self?.current?.append(.tool, text)
        }
    }

    /// The session the chat's tools drive: the Seat's alone, or with `native` the MacDriver first and the Seat when it
    /// gives an app back, and with `web` the chat's own Chrome for addresses (`RoutingAutomationSession`).
    private static func session(
        desktop  : BrokeredAutomationSession,
        options  : ChatOptions,
        knowledge: URL,
        owner    : UUID,
        web      : WebAutomationSession?
    ) throws -> any AutomationSessionOperating {
        guard !options.channels.isDisjoint(with: [.native, .web]) else { return desktop }
        return RoutingAutomationSession(
            native : options.channels.contains(.native)
                ? MacAutomationSession(knowledgeDirectory: knowledge, allowsDestructive: options.allowDestructive,
                                       leaseOwner: owner)
                : nil,
            desktop: desktop,
            web    : web
        )
    }

    /// The chat's own Chrome: headless, on a profile of the chat's own under its history folder (`Chrome`), never one
    /// of the person's; `--chrome` names the executable. Neither
    /// the person's own Chrome nor a paired Chrome profile is reached from the command line: the profiles' hub is the
    /// app's, and no other process can join it, so a page asked of either is refused with nothing opened.
    static func chatChrome(options: ChatOptions, history: URL, knowledge: URL) -> WebAutomationSession {
        WebAutomationSession(
            knowledgeDirectory   : knowledge,
            launchOptions        : ChromeLaunchOptions(
                executableURL      : options.chromeExecutable.map { URL(fileURLWithPath: $0) }
                    ?? ChromeLaunchOptions.applicationsChrome,
                userDataDirectory  : history.appendingPathComponent("Chrome", isDirectory: true),
                isHeadless         : true
            ),
            allowsDestructive    : options.allowDestructive,
            connectPersonalChrome: {
                throw AutomationFailure("braus chat opens pages only in its own Chrome, never the person's: nothing "
                                        + "was opened.")
            }
        )
    }

    /// Arms the stop on Ctrl+C and SIGTERM. The MCP host the provider connects to is each turn's own (`turn`).
    func start() async throws {
        signals = ChatSignals { [unowned self] number in
            router.pause()
            provider.cancel()
            shutdown = Task { [self] in
                await router.drain()
                // Unattended, the task the stop cut is closed with the stop as its cause and the request's evidence is
                // written, before anything slower: a run stopped at its time limit (SIGTERM, then SIGKILL 5 s later) left
                // the task open and no summary (14 October 2026).
                if closesTaskOnStop {
                    let agentEntries = current?.conversation.entries.count ?? 0
                    let closed = await abandonOpenTask(note: "The process was stopped by signal \(number) before memory_task "
                                                             + "end: Braus closed the task as abandoned.")
                    if let closed { print(Self.line(for: closed)) }
                    await interruption?(number, closed, agentEntries)
                    await MemoryService.closeAll()
                }
                await tools.session.close()
                await web?.close()
                await broker.queue.shutdown()
                await provider.waitUntilStopped()
                do { try current?.append(.interrupted, "Interrupted. Inspect the current app state before continuing.") }
                catch { fputs("braus: transcript save failed: \(error)\n", stderr) }
                await endTurnHost()
                do { try FileManager.default.removeItem(at: temporary) }
                catch { fputs("braus: temporary cleanup failed: \(error)\n", stderr) }
                if let current {
                    print("\nStopped; conversation saved. Resume with --resume \(current.conversation.id.uuidString)")
                } else {
                    print("\nStopped.")
                }
                await MemoryService.closeAll()
                exit(128 + number)
            }
        }
    }

    /// Stops a turn's host still running and removes the private connection files; the Seat was released by the caller.
    func stop() {
        signals?.stop()
        signals = nil
        router.pause()
        host?.stop()
        host = nil
        connectionFile = nil
        do { try FileManager.default.removeItem(at: temporary) }
        catch { fputs("braus: could not remove temporary chat configuration: \(error)\n", stderr) }
    }

    /// Makes `transcript` the conversation of the next turns: the tool lines go to it, the memory records the calls as
    /// its conversation's stream, and its replies, failures and errors are withheld as the tools withhold (M07).
    func adopt(_ transcript: ChatTranscript) {
        current = transcript
        transcript.withholding = { [tools] in tools.withheld($0) }
        let id = transcript.conversation.id.uuidString
        tools.producer = CallProducer(source: .cli, streamID: "chat-" + id, traceID: id)
        tools.forgetConversation()
    }

    /// Ends as abandoned the task the current conversation left open, and forgets its candidate, so the next conversation of
    /// a script can begin its own: a conversation that stopped while the Seat waited for the person left its task open, and
    /// the next one could neither begin a task nor end the one it found, which another producer owned (14 October 2026).
    /// An abandoned task learns no procedure. Answers the task and whether the archive recorded the end, or nil when
    /// none was open.
    func abandonOpenTask(note: String = "The conversation ended without memory_task end: Braus closed the task as "
                             + "abandoned so the next one can begin.") async -> Abandonment? {
        guard let status = try? await tools.call("memory_task", .object(["operation": .string("status")])) else { return nil }
        let found = ChatScript.payload(of: status)
        guard found["status"].string == "open", let task = found["task"].string else { return nil }
        let answer = (try? await tools.call("memory_task", .object(["operation": .string("end"), "outcome": .string("abandoned"),
                                                                   "note": .string(note)]))).map(ChatScript.payload(of:))
        _ = tools.takeInterpretationReminder()
        let closed = answer?["status"].string == "ended"
        return Abandonment(task: task, closed: closed,
                           problem: closed ? nil : answer.map(ChatScript.text) ?? "memory_task end answered nothing")
    }

    /// The line the console and the transcript say of an abandonment.
    static func line(for abandonment: Abandonment) -> String {
        abandonment.closed
            ? "Braus closed task \(abandonment.task) as abandoned: the conversation ended without memory_task end."
            : "Braus could not close task \(abandonment.task) as abandoned: \(abandonment.problem ?? "no answer")"
    }

    /// One turn of the provider on the current transcript, with the first scene of the turn sent whole again: a
    /// resumed provider context may have been compacted. The Seat is held for the whole turn, as a worker's is;
    /// between turns the session keeps it warm for a while, then gives it back. A turn that ends with a learning
    /// candidate the agent did not interpret gets one more round asking for it (`takeInterpretationReminder`).
    func turn(_ message: String) async throws {
        guard let transcript = current else { throw ChatMenu.problem("No conversation to run the turn in.") }
        tools.forgetScene()
        let connectionFile = try await startTurnHost()
        router.resume()
        do {
            try await run(message, in: transcript, connectionFile: connectionFile)
        } catch {
            await endTurn()
            throw error
        }
        await endTurn()
    }

    /// The turn's provider runs, with its reminder, through `connectionFile`.
    private func run(_ message: String, in transcript: ChatTranscript, connectionFile: URL) async throws {
        let instructions = tools.instructions
        let turn = ProviderTurn(
            provider: transcript.conversation.provider, model: transcript.conversation.model,
            sessionID: transcript.conversation.providerSessionID, prompt: message,
            instructions: instructions, bridgeExecutable: Self.executablePath,
            connectionFile: connectionFile.path, workingDirectory: working.path, effort: effort
        )
        try await desktop.turn {
            try await provider.run(turn, executable: executable) { event in try transcript.event(event) }
            // A candidate the agent left uninterpreted is never learned: it is asked for once, in the same provider
            // session and turn, with the Seat still held. The transcript keeps the request as Braus's own words.
            guard let reminder = tools.takeInterpretationReminder() else { return }
            print("\n\(reminder)\n")
            try transcript.append(.user, reminder)
            let follow = ProviderTurn(
                provider: transcript.conversation.provider, model: transcript.conversation.model,
                sessionID: transcript.conversation.providerSessionID, prompt: reminder,
                instructions: instructions, bridgeExecutable: Self.executablePath,
                connectionFile: connectionFile.path, workingDirectory: working.path, effort: effort
            )
            try await provider.run(follow, executable: executable) { event in try transcript.event(event) }
        }
    }

    /// Ends the broker's queue once the last session was closed: the parked Seat takes its display down. The chat's
    /// Chrome quits.
    func finish() async {
        guard !finished else { return }
        finished = true
        await tools.session.close()
        await web?.close()
        await broker.queue.shutdown()
    }

    /// Releases the Seat and the application session, with the router paused while the calls in flight drain. It
    /// stays paused: only a turn admits calls again.
    func releaseSeat() async {
        router.pause()
        await router.drain()
        await tools.session.close()
        await web?.close()
    }

    /// Starts the turn's own loopback host, with a token, and writes its own connection file (0600): what an earlier
    /// turn's child was given authorizes nothing in this one. A start that fails releases what it made.
    private func startTurnHost() async throws -> URL {
        let served = LocalMCPHost(router: router)
        host = served
        let file = temporary.appendingPathComponent("connection-\(UUID().uuidString).json")
        connectionFile = file
        do {
            let endpoint = try await served.start()
            try JSONEncoder().encode(endpoint).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            await endTurnHost()
            throw error
        }
        return file
    }

    /// Ends the turn, however it ended: nothing more is admitted, a call in flight finishes, and the turn's host and
    /// connection file go.
    private func endTurn() async {
        router.pause()
        await router.drain()
        await endTurnHost()
    }

    /// Stops the turn's host with every connection it served, once what they still served ended, and removes its
    /// connection file, so neither authorizes anything again.
    private func endTurnHost() async {
        let served = host
        host = nil
        await served?.stopAndDrain()
        if let connectionFile {
            self.connectionFile = nil
            try? FileManager.default.removeItem(at: connectionFile)
        }
    }

    static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
