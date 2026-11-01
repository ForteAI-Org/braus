
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
import Turn
import WebDriver
import WebSession
/// ChatSession owns transcript persistence and the Seat scope around the shared runner.
@MainActor
final class ChatSession: TurnHosting {
    let knowledge: URL
    let broker: SeatBroker
    let desktop: BrokeredAutomationSession
    let tools: ChatTools
    var router: MCPRouter { runner.toolRouter }
    let web: WebAutomationSession?
    let channels: AutomationChannels
    private var finished = false
    var provider: CLIProvider { runner.commandProvider }
    private lazy var runner = TurnRunner(tools: tools, configuration: .init(
        workingDirectory: working, bridgeExecutable: URL(filePath: Self.executablePath),
        connectionFolder: temporary, allowsSuspension: false), host: self)
    private var eventFailure: (any Error)?
    let executable: URL
    let working: URL
    private let temporary: URL
    private let credential: ChildEnvironment.Credential
    private var signals: ChatSignals?
    private(set) var current: ChatTranscript?
    private(set) var shutdown: Task<Void, Never>?
    var closesTaskOnStop = false
    var interruption: ((Int32, Abandonment?, Int) async -> Void)?

    struct Abandonment {
        let task: String
        let closed: Bool
        let problem: String?
    }

    init(
        options   : ChatOptions,
        history   : URL,
        executable: URL,
        session   : ((BrokeredAutomationSession) -> any AutomationSessionOperating)? = nil
    ) throws {
        self.executable = executable
        credential = options.credential
        knowledge = options.knowledgeDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? EngineRuntime.sharedKnowledge()
        if options.allowUnvalidated {
            FacilityGate.researchOptInForUnvalidatedBuilds = true
            print("seat: research opt-in for an unvalidated macOS build")
        }
        let broker = SeatBroker(configuration: SeatBrokerConfiguration(
            allowUnvalidatedBuild: options.allowUnvalidated,
            recordingDirectory: knowledge.deletingLastPathComponent().appendingPathComponent("Runs", isDirectory: true)))
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
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("braus-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        working = history.appendingPathComponent("ProviderWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        tools.record = { [weak self] text in
            print("  \(text.prefix(240))")
            try self?.current?.append(.tool, text)
        }
    }

    func start() async throws {
        signals = ChatSignals { [unowned self] number in
            runner.stop(marksTaskInterrupted: false)
            shutdown = Task { [self] in
                await router.drain()
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
                do { try await runner.close() }
                catch { fputs("braus: turn cleanup failed: \(error)\n", stderr) }
                do { try current?.append(.interrupted, "Interrupted. Inspect the current app state before continuing.") }
                catch { fputs("braus: transcript save failed: \(error)\n", stderr) }
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

    func stop() {
        signals?.stop()
        signals = nil
        runner.stop(marksTaskInterrupted: false)
        if FileManager.default.fileExists(atPath: temporary.path) {
            do { try FileManager.default.removeItem(at: temporary) }
            catch { fputs("braus: could not remove temporary chat configuration: \(error)\n", stderr) }
        }
    }

    func adopt(_ transcript: ChatTranscript) {
        current = transcript
        transcript.withholding = { [tools] in tools.withheld($0) }
        let id = transcript.conversation.id.uuidString
        tools.producer = CallProducer(source: .cli, streamID: "chat-" + id, traceID: id)
        tools.forgetConversation()
    }

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

    static func line(for abandonment: Abandonment) -> String {
        abandonment.closed
            ? "Braus closed task \(abandonment.task) as abandoned: the conversation ended without memory_task end."
            : "Braus could not close task \(abandonment.task) as abandoned: \(abandonment.problem ?? "no answer")"
    }

    func turn(_ message: String) async throws {
        guard let transcript = current else { throw ChatMenu.problem("No conversation to run the turn in.") }
        eventFailure = nil
        let environment = try ChildEnvironment.build(
            inherited: ProcessInfo.processInfo.environment, provider: transcript.conversation.provider,
            credential: credential, keychain: SystemKeychain())
        let previous = transcript.lastUsage.flatMap { usage -> (session: String, tokens: ProviderUsage.Tokens)? in
            guard usage.isSessionTotal, let session = transcript.conversation.providerSessionID else { return nil }
            return (session, usage.tokens)
        }
        let request = TurnRequest(prompt: message, route: .commandLine(provider: transcript.conversation.provider,
            executable: executable, model: transcript.conversation.model, effort: nil,
            environment: environment, allowsWebSearch: false), sessionID: transcript.conversation.providerSessionID,
            previousSessionTotal: previous)
        do {
            var outcome: TurnOutcome?
            try await desktop.turn {
                outcome = try await runner.run(request) { [self] event in
                    do {
                        switch event {
                        case .provider(.activity(let text)):
                            print("\n\(text)\n")
                            try transcript.append(.user, text)
                        case .provider(let event): try transcript.event(event)
                        case .tool(let text):
                            print("  \(text.prefix(240))")
                            try transcript.append(.tool, text)
                        case .usage(let reported, let total): transcript.recordUsage(reported, total: total)
                        case .processStarted, .contextReset: break
                        }
                    } catch {
                        eventFailure = eventFailure ?? error
                        runner.stop(marksTaskInterrupted: false)
                    }
                }
            }
            if let eventFailure { throw eventFailure }
            if let outcome { transcript.recordOutcome(outcome) }
        } catch {
            throw eventFailure ?? error
        }
    }

    func admission(of tool: String, _ arguments: LocalMCP.JSONValue) -> String? { nil }

    func withinCallScope<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if let eventFailure { throw eventFailure }
        return try await body()
    }

    func turnBegan() {}
    func turnStopping() {}
    func seatLine() -> String? { desktop.turnStatus }

    func finish() async {
        guard !finished else { return }
        finished = true
        do { try await runner.close() }
        catch { fputs("braus: turn cleanup failed: \(error)\n", stderr) }
        await web?.close()
        await broker.queue.shutdown()
    }

    func releaseSeat() async {
        await runner.retire()
        await web?.close()
    }

    static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
