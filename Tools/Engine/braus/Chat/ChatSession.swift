import AppAdapters
import Memory

import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Darwin
import FileConversations
import Foundation
import LocalMCP
import MacSession
import ModelTransports
import PrivateSymbols
import Router
import SeatBroker
import Turn
import WebDriver
import WebSession
/// ChatSession owns transcript persistence and the Seat scope around the shared runner.
@MainActor
final class ChatSession: TurnHosting {
    let profile: SessionProfile
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
        workingDirectory: working, bridgeExecutable: bridgeExecutable,
        connectionFolder: temporary, allowsSuspension: profile.takeover, closesSessionOnEnd: false), host: self)
    private var eventFailure: (any Error)?
    let executable: URL
    private let bridgeExecutable: URL
    let working: URL
    private let temporary: URL
    private let credential: ChildEnvironment.Credential
    private let keychain: any KeychainReading
    private let makeTransport: @MainActor (ModelSelection, ProviderSettings) -> any ModelTransport
    private let requestedEffort: ReasoningEffort?
    private let catalogue: @MainActor (ModelProvider) async throws -> [String]
    private let selectionNotice: @MainActor (String) -> Void
    private struct SelectionKey: Hashable {
        let provider: ModelProvider
        let model: String?
    }
    private var selections: [SelectionKey: (model: String?, effort: ReasoningEffort?)] = [:]
    private let anthropicHost: String
    private var protectedCredentials: Set<String> = []
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
        bridgeExecutable: URL? = nil,
        session   : ((BrokeredAutomationSession) -> any AutomationSessionOperating)? = nil,
        adapters  : AppAdapters? = nil,
        keychain  : any KeychainReading = SystemKeychain(),
        makeTransport: @escaping @MainActor (ModelSelection, ProviderSettings) -> any ModelTransport = {
            $0.transport(settings: $1)
        },
        catalogue: @escaping @MainActor (ModelProvider) async throws -> [String] = {
            try await ProviderCatalog.models($0, settings: ProviderSettings())
        },
        selectionNotice: @escaping @MainActor (String) -> Void = { print($0) }
    ) throws {
        guard options.sessionProfile.options.seatWarmSeconds >= 0 else {
            throw ChatMenu.problem("The Seat idle duration must be nonnegative.")
        }
        self.profile = options.sessionProfile
        requestedEffort = options.effort
        self.catalogue = catalogue
        self.selectionNotice = selectionNotice
        self.executable = executable
        self.bridgeExecutable = bridgeExecutable ?? URL(filePath: Self.executablePath)
        credential = options.credential
        self.keychain = keychain
        self.makeTransport = makeTransport
        anthropicHost = options.anthropicHost
        knowledge = options.sessionProfile.archive ?? EngineRuntime.sharedKnowledge()
        if options.allowUnvalidated {
            FacilityGate.researchOptInForUnvalidatedBuilds = true
            print("seat: research opt-in for an unvalidated macOS build")
        }
        let broker = SeatBroker(configuration: SeatBrokerConfiguration(
            allowUnvalidatedBuild: options.allowUnvalidated,
            recordingDirectory: knowledge.deletingLastPathComponent().appendingPathComponent("Runs", isDirectory: true)))
        let owner = UUID()
        let desktop = BrokeredAutomationSession(broker: broker, workerID: owner, knowledgeDirectory: knowledge,
                                                allowsDestructive: options.allowDestructive, grantee: BrokeredSeat.grantee,
                                                idleWindow: .seconds(options.sessionProfile.options.seatWarmSeconds))
        self.broker = broker
        self.desktop = desktop
        let web = options.channels.contains(.web) ? Self.chatChrome(options: options, history: history,
                                                                    knowledge: knowledge) : nil
        self.web = web
        channels = options.channels
        let driven = try session?(desktop)
            ?? Self.session(desktop: desktop, options: options, knowledge: knowledge, owner: owner, web: web)
        let tools = ChatTools(session: driven, channels: options.channels, adapters: adapters, profile: options.sessionProfile)
        self.tools = tools
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("braus-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        working = history.appendingPathComponent("ProviderWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        tools.record = { [weak self] text in
            let shown = self?.current?.shown(text) ?? text
            print("  \(shown.prefix(240))")
            try self?.current?.append(.tool, shown)
        }
    }

    func start() async throws {
        try await tools.prepareGuides()
        signals = ChatSignals { [unowned self] number in
            runner.stop(marksTaskInterrupted: false)
            shutdown = Task { [self] in
                await router.drain()
                if true {
                    let agentEntries = current?.conversation.entries.count ?? 0
                    let closed = await abandonOpenTask(cause: .signal(number))
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
        transcript.withholding = { [weak self, tools] text in
            var shown = tools.withheld(text)
            for credential in self?.protectedCredentials ?? [] {
                shown = shown.replacingOccurrences(of: credential, with: "[withheld]")
            }
            return shown
        }
        let id = transcript.conversation.id.uuidString
        tools.producer = CallProducer(source: .cli, streamID: "chat-" + id, traceID: id)
        tools.forgetConversation()
        tools.restoreTaskReference(ChatScript.taskIDs(in: transcript.conversation.entries).last)
    }

    func abandonOpenTask(cause: StopCause = .conversationEnded) async -> Abandonment? {
        guard let task = tools.openTask?.taskID else { return nil }
        do {
            _ = try await tools.closeStoppedTask(cause)
            return Abandonment(task: task, closed: true, problem: nil)
        } catch {
            return Abandonment(task: task, closed: false, problem: MemoryService.describe(error))
        }
    }

    static func line(for abandonment: Abandonment) -> String {
        if abandonment.closed {
            return ModelText.text(.init(rawValue: "task_cycle.stopped.v2"))
        }
        return abandonment.closed
            ? "Braus closed task \(abandonment.task) as abandoned: the conversation ended without end."
            : "Braus could not close task \(abandonment.task) as abandoned: \(abandonment.problem ?? "no answer")"
    }

    func turn(_ message: String) async throws {
        guard let transcript = current else { throw ChatMenu.problem("No conversation to run the turn in.") }
        eventFailure = nil
        let previous = transcript.lastUsage.flatMap { usage -> (session: String, tokens: ProviderUsage.Tokens)? in
            guard usage.isSessionTotal, let session = transcript.conversation.providerSessionID else { return nil }
            return (session, usage.tokens)
        }
        let request: TurnRequest
        if let name = transcript.conversation.modelProvider {
            guard let provider = ModelProvider(rawValue: name), [.anthropic, .gemini, .ollama].contains(provider) else {
                throw ChatMenu.problem("Unknown model provider in the saved conversation.")
            }
            var settings = ProviderSettings(anthropicHost: anthropicHost)
            if provider != .ollama {
                if case .keychain(let key) = credential {
                    let value = try keychain.password(service: key.service)
                    guard !value.isEmpty else { throw ProviderKeychainKey.Failure.empty(service: key.service) }
                    protectedCredentials.insert(value)
                    if provider == .anthropic { settings.anthropicAPIKey = value }
                    else { settings.geminiAPIKey = value }
                } else if credential != .none {
                    throw ChatMenu.problem("The model loop reads credentials only from --provider-key-service.")
                }
            }
            let resolved = try await selection(provider: provider, model: transcript.conversation.model)
            guard let model = resolved.model else { throw ChatMenu.problem("Use --model to select a local model.") }
            let selection = ModelSelection(provider: provider, model: model, effort: resolved.effort ?? .medium)
            var entries = transcript.conversation.entries
            if entries.last?.kind == .user, entries.last?.text == message { entries.removeLast() }
            let history = entries.compactMap { entry -> TurnMessage? in
                switch entry.kind {
                case .user: TurnMessage(role: .user, text: entry.text)
                case .assistant: TurnMessage(role: .assistant, text: entry.text)
                default: nil
                }
            }
            request = TurnRequest(prompt: message,
                route: .modelLoop(transport: makeTransport(selection, settings), contextWindow: nil), history: history)
        } else {
            let environment = try ChildEnvironment.build(
                inherited: ProcessInfo.processInfo.environment, provider: transcript.conversation.provider,
                credential: credential, keychain: keychain)
            let provider: ModelProvider = transcript.conversation.provider == .claude ? .claudeCode : .codex
            let resolved = try await selection(provider: provider, model: transcript.conversation.model)
            request = TurnRequest(prompt: message, route: .commandLine(provider: transcript.conversation.provider,
                executable: executable, model: resolved.model, effort: resolved.effort?.rawValue,
                environment: environment, allowsWebSearch: profile.options.harnessWebSearch), sessionID: transcript.conversation.providerSessionID,
                previousSessionTotal: previous)
        }
        do {
            var outcome: TurnOutcome?
            try await desktop.turn {
                outcome = try await runner.run(request) { [self] event in
                    do {
                        switch event {
                        case .provider(.activity(let text)):
                            print("\n\(transcript.shown(text))\n")
                            try transcript.append(.user, transcript.shown(text))
                        case .provider(let event): try transcript.event(event)
                        case .tool(let text):
                            print("  \(transcript.shown(text).prefix(240))")
                            try transcript.append(.tool, transcript.shown(text))
                        case .usage(let reported, let total): transcript.recordUsage(reported, total: total)
                        case .todo(let change):
                            let label = change.kind == .drafted ? "Plan" : "Plan updated"
                            let line = label + ": " + change.rows.map { $0.id.rawValue + " " + $0.status.rawValue }.joined(separator: ", ")
                            print("  \(line)")
                            try transcript.append(.tool, line)
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

    /// Resolves the effective effort only after the route has selected a concrete model when required.
    static func resolvedEffort(
        provider: ModelProvider,
        model: String?,
        requested: ReasoningEffort?
    ) throws -> (model: String?, effort: ReasoningEffort?) {
        let commandLine = provider == .claudeCode || provider == .codex
        if commandLine && requested == nil { return (model, nil) }
        guard let model, !model.isEmpty else { throw ChatMenu.problem("Use --model to select a model for effort.") }
        let supported = ModelSelection.supportedEfforts(provider: provider, model: model)
        if let requested, supported.contains(requested) { return (model, requested) }
        if commandLine { return (model, nil) }
        return (model, supported.contains(.medium) ? .medium : supported.first)
    }

    func selection(
        provider: ModelProvider,
        model: String?
    ) async throws -> (model: String?, effort: ReasoningEffort?) {
        let key = SelectionKey(provider: provider, model: model)
        if let saved = selections[key] { return saved }
        let commandLine = provider == .claudeCode || provider == .codex
        var resolvedModel = model
        if resolvedModel == nil && (!commandLine || requestedEffort != nil) {
            if commandLine {
                do { resolvedModel = try await catalogue(provider).first }
                catch { print("Could not list models for \(provider.title): \(error). Using its fixed default.") }
            }
            resolvedModel = resolvedModel ?? provider.defaultModels.first
        }
        let resolved = try Self.resolvedEffort(provider: provider, model: resolvedModel, requested: requestedEffort)
        if requestedEffort != nil, model == nil, let selected = resolved.model {
            selectionNotice("Model: \(selected)")
        }
        if let requestedEffort, requestedEffort != resolved.effort {
            let effective = resolved.effort?.rawValue ?? (commandLine ? "provider default (effort omitted)" : "no effort parameter")
            print("Effort \(requestedEffort.rawValue) is unavailable for \(resolved.model ?? "default"); using \(effective).")
        }
        selections[key] = resolved
        return resolved
    }

    func admission(of tool: String, _ arguments: LocalMCP.JSONValue) -> String? { nil }

    func withinCallScope<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if let eventFailure { throw eventFailure }
        return try await body()
    }

    func turnBegan() {}
    func turnStopping() {}
    func seatFacts() -> SeatFacts? { desktop.turnStatus }

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
