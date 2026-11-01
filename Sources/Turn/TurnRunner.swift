import AgentLoop
import AutomationMCP
import AutomationRuntime
import Capabilities
import ChatCore
import CLIProviders
import Foundation
import Dispatch
import LocalMCP
import ModelTransports

/// TurnRunner owns turn execution, private endpoints and suspension independently of host UI and storage.
/// The host is borrowed weakly and retained for admitted calls. Transitions are serialized on the main actor.
@MainActor
public final class TurnRunner {
    private let tools: AutomationTools
    private let configuration: TurnConfiguration
    private weak var hosting: (any TurnHosting)?
    private let provider = CLIProvider()
    private let removeConnectionFile: (URL) throws -> Void
    private let takeReminder: @MainActor () -> String?
    private var servedHost: LocalMCPHost?
    private var temporary: URL?
    private var connectionFile: URL?
    private var loop: ModelToolLoop?
    private var loopCounter: TurnRoundCounter?
    private var commandRounds = 0
    private var episode: SuspensionToken?
    private var cleanup: Task<Void, Never>?
    private var runEndWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCompacting = false
    private var isStopRequested = false
    private var onEvent: (@MainActor (TurnRunEvent) -> Void)?
    private var calls: [UUID: TurnCall] = [:]
    private var reportedSession: String?
    private var web = WebToolRecords()
    private var pendingUsage: ProviderUsage?
    private var lastReported: ProviderUsage?
    private var usageEmitted = false
    private var totalUsage: TurnTokenUsage?
    private var previousTotal: (session: String, tokens: ProviderUsage.Tokens)?
    private var rollout: (session: String, file: URL)?
    public private(set) var contextState = ContextState()
    public private(set) var toolCalls = 0
    public var rounds: Int { loopCounter?.count ?? commandRounds }
    public var isRunning: Bool { onEvent != nil }
    package var toolRouter: MCPRouter { router }
    package var commandProvider: CLIProvider { provider }
    public var servedTools: [JSONValue] { tools.toolDefinitions }

    private lazy var router = MCPRouter(
        tools: tools.toolDefinitions,
        instructions: AutomationTools.mcpInstructions(.firstLine)
    ) { [unowned self] name, arguments in
        try await call(name, arguments)
    }

    public convenience init(tools: AutomationTools, configuration: TurnConfiguration, host: any TurnHosting) {
        self.init(tools: tools, configuration: configuration, host: host,
                  reminder: { tools.takeInterpretationReminder() })
    }

    /// Supplies controlled interpretation and endpoint removal boundaries for lifecycle tests.
    init(tools: AutomationTools, configuration: TurnConfiguration, host: any TurnHosting,
         reminder: @escaping @MainActor () -> String?,
         removeConnectionFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.removeConnectionFile = removeConnectionFile
        takeReminder = reminder
        self.tools = tools
        self.configuration = configuration
        hosting = host
        router.pause()
        let previousRecord = tools.record
        tools.record = { [weak self] text in
            if let onEvent = self?.onEvent { onEvent(.tool(text)) }
            else { try previousRecord?(text) }
        }
    }

    /// Runs once, preserving event order and finishing admitted calls before failure or suspension is thrown.
    public func run(
        _ request: TurnRequest,
        onEvent: @escaping @MainActor (TurnRunEvent) -> Void
    ) async throws -> TurnOutcome {
        try admit()
        guard hosting != nil else { throw CancellationError() }
        self.onEvent = onEvent
        isStopRequested = false
        commandRounds = 0
        loopCounter = nil
        toolCalls = 0
        totalUsage = nil
        usageEmitted = false
        lastReported = nil
        pendingUsage = nil
        reportedSession = nil
        previousTotal = request.previousSessionTotal
        let started = ContinuousClock.now
        defer { ended() }
        hosting?.turnBegan()
        try await tools.finishInterruptedTask()
        if isStopRequested { throw CancellationError() }
        reset(.turnStart)
        let seatParts = [tools.takeStoppedTaskNotice(), hosting?.seatLine(),
                         request.reviewingHumanIntervention ? TurnInstructions.humanInterventionInstructions : nil]
            .compactMap { $0 }
        let seat = seatParts.isEmpty ? nil : seatParts.joined(separator: "\n\n")
        switch request.route {
        case .modelLoop(let transport, let window):
            let counter = TurnRoundCounter()
            loopCounter = counter
            let loop = ModelToolLoop(
                call: { [unowned self] in try await call($0, $1) },
                reminder: takeReminder,
                definitions: AutomationTools.definitions,
                instructions: TurnLoopInstructions()
            )
            self.loop = loop
            defer { self.loop = nil }
            do {
                try await loop.run(
                    transport: CountedTurnTransport(transport: transport, counter: counter, budget: request.budget),
                    role: request.role,
                    history: request.history,
                    prompt: request.prompt,
                    seat: seat,
                    contextWindow: window,
                    baseTools: tools.toolDefinitions,
                    instructions: tools.instructions
                ) { event in
                    if case .usage(let reported) = event {
                        self.lastReported = reported
                        let own = TurnTokenUsage(reported.tokens)
                        self.totalUsage = own
                        onEvent(.usage(reported, own))
                    } else { onEvent(.provider(event)) }
                }
                if isStopRequested { throw CancellationError() }
            } catch {
                if let episode, error is CancellationError {
                    reset(.personHadApp)
                    throw TurnSuspended(token: episode)
                }
                episode = nil
                if configuration.closesSessionOnEnd { await tools.session.close() }
                do { try await tools.finishInterruptedTask() }
                catch { recordCleanupFailure(error) }
                throw error
            }
        case .commandLine(let chatProvider, let executable, _, _, let environment, _):
            guard FileManager.default.isExecutableFile(atPath: configuration.bridgeExecutable.path) else {
                throw AutomationFailure("Braus is missing a required support component. The message was not sent. "
                                        + "Details: \(configuration.bridgeExecutable.path)")
            }
            let connection = try await start()
            let instructions = instructions(for: request)
            var message = seat.map { $0 + "\n\n" + request.prompt } ?? request.prompt
            if let session = request.sessionID, deliveredInstructions(to: session) != instructions {
                message = TurnInstructions.changedNotice(instructions) + message
            }
            web = WebToolRecords()
            do {
                if isStopRequested { throw CancellationError() }
                router.resume()
                try await runProcess(request, prompt: message, session: request.sessionID,
                                     connection: connection, executable: executable)
                if isStopRequested { throw CancellationError() }
                if let asked = takeReminder(), let session = reportedSession ?? request.sessionID {
                    if isStopRequested { throw CancellationError() }
                    onEvent(.provider(.activity(asked)))
                    try await runProcess(request, prompt: asked, session: session,
                                         connection: connection, executable: executable)
                }
                if isStopRequested { throw CancellationError() }
                router.pause()
                await router.drain()
                await cleanUpTurnHost()
                if let session = reportedSession ?? request.sessionID {
                    record(instructions, deliveredTo: session)
                }
                await reportUsage(provider: chatProvider, session: reportedSession ?? request.sessionID,
                                  environment: environment)
                if isStopRequested { throw CancellationError() }
            } catch let primary {
                if episode != nil, primary is CancellationError { router.suspendForHumanIntervention() }
                else { router.pause() }
                await router.drain()
                await provider.waitUntilStopped()
                await cleanUpTurnHost()
                accountPending(session: reportedSession ?? request.sessionID)
                await reportUsage(provider: chatProvider, session: reportedSession ?? request.sessionID,
                                  environment: environment)
                if let episode, primary is CancellationError {
                    reset(.personHadApp)
                    throw TurnSuspended(token: episode)
                }
                episode = nil
                if configuration.closesSessionOnEnd { await tools.session.close() }
                do { try await tools.finishInterruptedTask() }
                catch { recordCleanupFailure(error) }
                throw primary
            }
        }
        return TurnOutcome(usage: totalUsage, lastReported: lastReported,
                           session: reportedSession ?? request.sessionID, rounds: rounds,
                           toolCalls: toolCalls, duration: started.duration(to: .now))
    }

    private func runProcess(
        _ request: TurnRequest,
        prompt: String,
        session: String?,
        connection: URL,
        executable: URL
    ) async throws {
        commandRounds += 1
        let turn = providerTurn(request, prompt: prompt, session: session, connection: connection)
        try await provider.run(turn, executable: executable,
                               onStart: { self.onEvent?(.processStarted($0)) }) { event in
            if case .session(let id) = event { self.reportedSession = id }
            switch event {
            case .usage(let usage): self.pendingUsage = usage
            case .web:
                for line in try self.web.lines(for: event, withholding: self.tools.withheld) { self.onEvent?(.tool(line)) }
            default: self.onEvent?(.provider(event))
            }
        }
        accountPending(session: reportedSession ?? session)
    }

    private func accountPending(session: String?) {
        guard let pendingUsage else { return }
        self.pendingUsage = nil
        let own = TurnTokenUsage(TurnTokenUsage.own(pendingUsage, session: session, previous: previousTotal))
        totalUsage = totalUsage.map { $0 + own } ?? own
        lastReported = pendingUsage
        if pendingUsage.isSessionTotal, let session { previousTotal = (session, pendingUsage.tokens) }
    }

    private func reportUsage(provider: ChatProvider, session: String?, environment: [String: String]) async {
        guard !usageEmitted, var reported = lastReported, let totalUsage else { return }
        usageEmitted = true
        if provider == .codex, let session,
           let tail = await rolloutTail(of: session, environment: environment),
           let reading = CodexRollout.reading(from: tail) {
            reported.contextTokens = reported.contextTokens ?? reading.contextTokens
            reported.contextWindow = reported.contextWindow ?? reading.contextWindow
            if reported.rateLimits.isEmpty { reported.rateLimits = reading.rateLimits }
        }
        onEvent?(.usage(reported, totalUsage))
    }

    private func admit() throws(TurnRefusal) {
        guard episode == nil, cleanup == nil else { throw .personHasControl }
        guard !isRunning else { throw .turnRunning }
    }

    private func ended() {
        onEvent = nil
        let waiters = runEndWaiters
        runEndWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func reset(_ reason: ContextState.Reason) {
        contextState.reset(reason)
        tools.forgetScene()
        onEvent?(.contextReset(reason))
    }

    private func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        guard episode == nil, !isStopRequested else { throw CancellationError() }
        guard let hosting else { throw CancellationError() }
        if let refusal = hosting.admission(of: name, arguments) { throw AutomationFailure(refusal) }
        let id = UUID()
        let interruption = AutomationCallInterruption()
        let task = Task {
            try await AutomationCallInterruption.$current.withValue(interruption) {
                try await hosting.withinCallScope { try await self.tools.call(name, arguments) }
            }
        }
        toolCalls += 1
        calls[id] = TurnCall(tool: name, task: task, interruption: interruption)
        defer { calls[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func interruptReads() {
        let listed = Set(servedTools.compactMap { $0["name"].string })
        for call in calls.values where !call.interruption.wasInterrupted {
            let policy = AutomationTools.interruptionPolicy(for: call.tool)
            guard policy == .readOnly || (policy == .openingScene && call.interruption.isReadingOpeningScene)
            else { continue }
            call.interruption.interruptForHumanControl()
            TurnCall.logInterruption(listed.contains(call.tool) ? call.tool : "unlisted")
            call.task.cancel()
        }
    }

    /// Refuses new work and cancels reads while allowing an admitted action to finish.
    @discardableResult
    public func suspend() throws(TurnRefusal) -> SuspensionToken {
        guard configuration.allowsSuspension else { throw .suspensionUnavailable }
        guard cleanup == nil else { throw .previousEpisodeReleasing }
        if let episode { return episode }
        guard !isRunning || !isStopRequested else { throw .previousTurnStopping }
        let token = SuspensionToken(id: UUID())
        episode = token
        isStopRequested = true
        reset(.personHadApp)
        hosting?.turnStopping()
        router.suspendForHumanIntervention()
        interruptReads()
        loop?.suspendForHumanIntervention()
        provider.cancel(preservingFailure: true)
        return token
    }

    public func end(_ token: SuspensionToken) throws(TurnRefusal) {
        guard episode == token, !isRunning, calls.isEmpty else { throw .staleEpisode }
        reset(.personHadApp)
        episode = nil
    }

    public func waitForCallsToDrain(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !calls.isEmpty {
            interruptReads()
            guard ContinuousClock.now < deadline else { return false }
            // This wait joins cleanup even when its caller has already been cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
        }
        return true
    }

    public func stop(marksTaskInterrupted: Bool) {
        if marksTaskInterrupted, !isCompacting { tools.markTaskInterrupted() }
        let wasSuspended = episode != nil
        episode = nil
        guard isRunning else {
            if wasSuspended {
                cleanup = Task {
                    if configuration.closesSessionOnEnd { await tools.session.close() }
                    cleanup = nil
                }
            }
            return
        }
        isStopRequested = true
        hosting?.turnStopping()
        if let loop { loop.stop(); return }
        router.pause()
        provider.cancel()
    }

    public func waitForCleanup() async {
        if isRunning { await withCheckedContinuation { runEndWaiters.append($0) } }
        await cleanup?.value
    }

    public func retire() async {
        await cleanup?.value
        episode = nil
        router.pause()
        await router.drain()
        await cleanUpTurnHost()
        await tools.session.close()
    }

    private var cleanupFailure: (any Error)?

    public func close() async throws {
        await cleanup?.value
        episode = nil
        isStopRequested = true
        loop?.stop()
        hosting?.turnStopping()
        router.pause()
        provider.cancel()
        if isRunning { await withCheckedContinuation { runEndWaiters.append($0) } }
        await router.drain()
        await tools.session.close()
        await provider.waitUntilStopped()
        try await endTurnHost()
        if let temporary {
            self.temporary = nil
            if FileManager.default.fileExists(atPath: temporary.path) {
                try FileManager.default.removeItem(at: temporary)
            }
        }
        if let cleanupFailure { throw cleanupFailure }
    }

    private func instructions(for request: TurnRequest) -> String {
        let searchesWeb: Bool
        if case .commandLine(_, _, _, _, _, let allowed) = request.route { searchesWeb = allowed }
        else { searchesWeb = false }
        return TurnInstructions.compose(role: request.role, searchesWeb: searchesWeb, tools: tools.instructions)
    }

    func providerTurn(
        _ request: TurnRequest,
        prompt: String,
        session: String?,
        connection: URL,
        compaction: Bool = false
    ) -> ProviderTurn {
        guard case .commandLine(let provider, _, let model, let effort, let environment, let web) = request.route
        else { preconditionFailure("A provider child requires a command line route.") }
        return ProviderTurn(provider: provider, model: model, sessionID: session, prompt: prompt,
                            instructions: TurnInstructions.compose(role: request.role,
                                searchesWeb: web && !compaction, offersWeb: compaction && tools.offersWeb, tools: tools.instructions),
                            bridgeExecutable: configuration.bridgeExecutable.path, connectionFile: connection.path,
                            workingDirectory: configuration.workingDirectory.path, effort: effort,
                            environment: environment, isCompaction: compaction, allowsWebSearch: web && !compaction)
    }

    private struct DeliveredInstructions: Codable {
        let session: String
        let instructions: String
    }
    private var instructionRecord: URL { configuration.workingDirectory.appending(path: "codex-instructions.json") }

    /// A missing or unreadable record means the session must receive its instructions again.
    private func deliveredInstructions(to session: String) -> String? {
        guard FileManager.default.fileExists(atPath: instructionRecord.path) else { return nil }
        do {
            let record = try JSONDecoder().decode(DeliveredInstructions.self, from: Data(contentsOf: instructionRecord))
            return record.session == session ? record.instructions : nil
        } catch {
            TurnDiagnostics.instructionRecord(error)
            return nil
        }
    }

    /// A failed record write is reported and causes a reminder on the next turn.
    private func record(_ instructions: String, deliveredTo session: String) {
        do {
            try JSONEncoder().encode(DeliveredInstructions(session: session, instructions: instructions))
                .write(to: instructionRecord, options: .atomic)
        } catch { TurnDiagnostics.instructionRecord(error) }
    }

    private func start() async throws -> URL {
        let files = FileManager.default
        do {
            try files.createDirectory(at: configuration.workingDirectory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let directory: URL
            if let temporary { directory = temporary }
            else {
                directory = configuration.connectionFolder
                    ?? files.temporaryDirectory.appending(path: "braus-turn-\(UUID().uuidString)")
                try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
                temporary = directory
            }
            let served = LocalMCPHost(router: router)
            servedHost = served
            let endpoint = try await served.start()
            let file = directory.appending(path: "connection-\(UUID().uuidString).json")
            connectionFile = file
            try JSONEncoder().encode(endpoint).write(to: file, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch let primary {
            await cleanUpTurnHost()
            if let temporary {
                self.temporary = nil
                do { try files.removeItem(at: temporary) }
                catch { recordCleanupFailure(error) }
            }
            throw primary
        }
    }

    private func recordCleanupFailure(_ error: any Error) {
        cleanupFailure = cleanupFailure ?? error
        TurnDiagnostics.cleanup(error)
    }

    private func cleanUpTurnHost() async {
        do { try await endTurnHost() }
        catch { recordCleanupFailure(error) }
    }

    private func endTurnHost() async throws {
        let served = servedHost
        servedHost = nil
        await served?.stopAndDrain()
        if let connectionFile {
            self.connectionFile = nil
            if FileManager.default.fileExists(atPath: connectionFile.path) {
                try removeConnectionFile(connectionFile)
            }
        }
    }
}

private struct TurnLoopInstructions: LoopInstructionComposing {
    func systemText(role: String?, hasTools: Bool, tools: String) -> String {
        TurnInstructions.compose(role: role, hasTools: hasTools, tools: tools)
    }
}

extension TurnRunner {
    /// Compacts without tools, under the same admission and cleanup rules as a normal turn.
    public func compact(_ request: TurnRequest, trigger: CompactionTrigger) async throws -> CompactionOutcome {
        try admit()
        onEvent = { _ in }
        isStopRequested = false
        isCompacting = true
        defer { isCompacting = false; ended() }
        reset(.compaction)
        switch request.route {
        case .modelLoop(let transport, let window):
            let loop = ModelToolLoop(
                call: { _, _ in throw AutomationFailure("A summary calls no tool.") },
                definitions: AutomationTools.definitions,
                instructions: TurnLoopInstructions()
            )
            self.loop = loop
            defer { self.loop = nil }
            let written = try await loop.summarize(transport: transport, history: request.history)
            return CompactionOutcome(trigger: trigger, preTokens: written.tokens?.input,
                postTokens: written.tokens?.output, contextWindow: window, summary: written.summary,
                reported: written.tokens.map { ProviderUsage(tokens: $0, contextWindow: window) },
                usage: written.tokens.map(TurnTokenUsage.init))
        case .commandLine(let chatProvider, let executable, _, _, let environment, _):
            guard let session = request.sessionID else {
                throw AutomationFailure("There is nothing to compact yet: this conversation has no provider session.")
            }
            guard FileManager.default.isExecutableFile(atPath: configuration.bridgeExecutable.path) else {
                throw AutomationFailure("Braus is missing a required support component. Details: \(configuration.bridgeExecutable.path)")
            }
            let connection = try await start()
            let turn = providerTurn(request, prompt: ModelText.text(.init(rawValue: "turn.compacted")),
                                    session: session, connection: connection, compaction: true)
            let started = Date()
            var boundary: (pre: Int?, post: Int?)?
            var reported: ProviderUsage?
            var lastWords: String?
            do {
                if isStopRequested { throw CancellationError() }
                try await provider.run(turn, executable: executable) { event in
                    switch event {
                    case .compacted(let pre, let post): boundary = (pre, post)
                    case .usage(let usage): reported = usage
                    case .assistant(let text): lastWords = text
                    default: break
                    }
                }
                await cleanUpTurnHost()
            } catch let primary {
                router.pause()
                await router.drain()
                await provider.waitUntilStopped()
                await cleanUpTurnHost()
                throw primary
            }
            switch chatProvider {
            case .claude:
                guard let boundary else {
                    throw AutomationFailure(lastWords ?? "Claude Code finished without compacting the conversation.")
                }
                return CompactionOutcome(trigger: trigger, preTokens: boundary.pre, postTokens: boundary.post,
                    contextWindow: reported?.contextWindow, summary: nil, reported: nil, usage: nil)
            case .codex:
                guard let tail = await rolloutTail(of: session, environment: environment),
                      CodexRollout.compacts(in: tail, since: started) else {
                    throw AutomationFailure("Codex answered without compacting the conversation.")
                }
                let reading = CodexRollout.reading(from: tail)
                if var count = reported {
                    count.contextTokens = count.contextTokens ?? reading?.contextTokens
                    count.contextWindow = count.contextWindow ?? reading?.contextWindow
                    if count.rateLimits.isEmpty { count.rateLimits = reading?.rateLimits ?? [] }
                    reported = count
                }
                return CompactionOutcome(trigger: trigger, preTokens: request.previousContextTokens,
                    postTokens: reading?.contextTokens, contextWindow: reading?.contextWindow, summary: nil,
                    reported: reported, usage: reported.map {
                        TurnTokenUsage(TurnTokenUsage.own($0, session: session, previous: request.previousSessionTotal))
                    })
            }
        }
    }

    private func rolloutTail(of session: String, environment: [String: String]) async -> Data? {
        let known = rollout?.session == session ? rollout?.file : nil
        let sessions = CodexRollout.sessions(environment: environment)
        let found = await Task.detached {
            let file = known ?? CodexRollout.file(of: session, in: sessions)
            return file.map { (file: $0, tail: CodexRollout.tail(of: $0)) }
        }.value
        guard let found else { return nil }
        rollout = (session, found.file)
        return found.tail
    }
}
