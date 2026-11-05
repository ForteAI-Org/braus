import Memory
import AppAdapters
import AgentLoop
import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Foundation
import LocalMCP
import ModelTransports
import TaskRouting
import Turn

/// WorkerAgentHost supplies application approval scope and storage values to the shared runner.
@MainActor
final class WorkerAgentHost: TurnHosting {
    /// Keeps the application's existing UUID handoff interface.
    struct HumanInterventionSuspended: Error { let token: UUID }
    private let workingDirectory: URL
    private let bridgeExecutable: URL
    private let tools: AutomationTools
    let profile: SessionProfile
    private let usesProfileWebSearch: Bool
    private let agents: (ModelProvider) throws -> (ChatProvider, URL)
    private let transports: (ModelSelection) -> any ModelTransport
    private let contextWindows: (ModelSelection) -> Int?
    private let readSeatLine: @MainActor () -> SeatFacts?
    private let scriptedWorker: @MainActor () throws -> ScriptedWorkerRun?
    /// The running turn's isolated script, if it is one.
    private var scripted: ScriptedWorkerRun?
    /// The latest isolated script's outcome, read only after the turn and its recorder have ended.
    private(set) var scriptedReport: ScriptedWorkerRun.Report?
    private let barrier: ActionBarrier
    private let approvals: AdapterApprovals?
    private let approvalScope: UUID
    private lazy var runner = TurnRunner(tools: tools, configuration: .init(
        workingDirectory: workingDirectory, bridgeExecutable: bridgeExecutable, allowsSuspension: profile.takeover), host: self)

    var callProducer: CallProducer {
        get { tools.producer }
        set { tools.producer = newValue }
    }
    var servedTools: [JSONValue] { runner.servedTools }
    var isRunning: Bool { runner.isRunning }

    convenience init(
        workingDirectory: URL,
        bridgeExecutable: URL,
        session         : () -> any AutomationSessionOperating,
        channels        : AutomationChannels = [],
        transports      : @escaping (ModelSelection) -> any ModelTransport = { $0.transport() },
        contextWindows  : @escaping (ModelSelection) -> Int?               = { _ in nil },
        seatLine        : @escaping @MainActor () -> SeatFacts?            = { nil },
        adapterApprover : (any AdapterApproving)?                          = nil,
        approvals       : AdapterApprovals?                                = nil,
        offersWeb       : Bool                                             = false,
        profile         : SessionProfile?                                  = nil
    ) {
        self.init(
            workingDirectory: workingDirectory,
            bridgeExecutable: bridgeExecutable,
            session         : session,
            channels        : channels,
            agents          : Self.agent(for:),
            transports      : transports,
            contextWindows  : contextWindows,
            seatLine        : seatLine,
            adapterApprover : adapterApprover,
            approvals       : approvals,
            offersWeb       : offersWeb,
            profile         : profile
        )
    }

    init(
        workingDirectory: URL,
        bridgeExecutable: URL,
        session         : () -> any AutomationSessionOperating,
        channels        : AutomationChannels = [],
        agents          : @escaping (ModelProvider) throws -> (ChatProvider, URL),
        transports      : @escaping (ModelSelection) -> any ModelTransport = { $0.transport() },
        contextWindows  : @escaping (ModelSelection) -> Int?               = { _ in nil },
        seatLine        : @escaping @MainActor () -> SeatFacts?            = { nil },
        adapters        : AppAdapters?                                     = nil,
        barrier         : ActionBarrier                                    = ActionBarrier(),
        adapterApprover: (any AdapterApproving)? = nil,
        approvals: AdapterApprovals? = nil,
        approvalScope: UUID = UUID(),
        offersWeb: Bool = false,
        scriptedWorker: @escaping @MainActor () throws -> ScriptedWorkerRun? = ScriptedWorkerRun.openIfRequested,
        profile: SessionProfile? = nil
    ) {
        let composedProfile = profile ?? .app
        self.profile = composedProfile
        self.usesProfileWebSearch = profile != nil
        self.scriptedWorker = scriptedWorker
        self.approvals        = approvals
        self.workingDirectory = workingDirectory
        self.bridgeExecutable = bridgeExecutable
        self.agents           = agents
        self.transports       = transports
        self.contextWindows   = contextWindows
        self.readSeatLine     = seatLine
        self.approvalScope = approvalScope
        let driven = session()
        let tools  = AutomationTools(session: driven, channels: channels,
                                     adapters: channels.contains(.adapters) ? (adapters ?? .standard(approver: adapterApprover)) : nil,
                                     offersWeb: offersWeb, profile: composedProfile)
        self.tools = tools
        self.barrier = barrier
    }

    static let appInstructions = TurnInstructions.appText
    static let webInstructions = TurnInstructions.webText
    static let textOnlyInstructions = TurnInstructions.textOnly
    static let humanInterventionInstructions = TurnInstructions.humanInterventionInstructions
    static let codexCompactionPrompt = "Braus compacted this conversation. Reply only: ok"

    static func instructions(role: String?, hasTools: Bool = true, searchesWeb: Bool = false,
                             offersWeb: Bool = false, tools: String = AutomationTools.instructions,
                             toolNames: [String] = []) -> String {
        TurnRunner.systemPrompt(role: role, hasTools: hasTools, searchesWeb: searchesWeb,
            offersWeb: offersWeb, tools: tools, toolNames: toolNames)
    }
    static func changedInstructions(_ instructions: String) -> String { TurnInstructions.changedNotice(instructions) }

    func admission(of tool: String, _ arguments: JSONValue) -> String? { barrier.refusal(of: tool, arguments) }
    func withinCallScope<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await ApprovalScope.$current.withValue(approvalScope) { try await body() }
    }
    func turnBegan() { approvals?.admit(scope: approvalScope) }
    func turnStopping() { approvals?.refuse(scope: approvalScope) }
    func seatFacts() -> SeatFacts? { readSeatLine() }

    /// The pictures the model was shown go on the tool line too, after the tool's own records.
    func answered(tool: String, result: JSONValue) throws {
        if let pictures = ToolPictures.record(tool: tool, result: result) { try tools.record?(pictures) }
    }

    func recordResult(_ call: ToolCall, _ result: JSONValue, startedAt: ContinuousClock.Instant) throws {
        try scripted?.record(
            call     : call,
            result   : result,
            startedAt: startedAt
        )
    }

    func run(
        prompt: String,
        selection: ModelSelection,
        sessionID: String?,
        role: String?,
        history: [TurnMessage] = [],
        lastUsage: TurnUsage? = nil,
        allowsWebSearch: Bool? = nil,
        reviewingHumanIntervention: Bool = false,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        onEvent: @escaping @MainActor (WorkerAgentEvent) -> Void
    ) async throws {
        try await tools.prepareGuides()
        let searchesWeb = usesProfileWebSearch ? profile.options.harnessWebSearch : (allowsWebSearch ?? false)
        scriptedReport = nil
        do {
            scripted = try scriptedWorker()
        } catch {
            scriptedReport = ScriptedWorkerRun.Report(errors: [String(describing: error)])
            await tools.session.close()
            throw error
        }
        defer {
            scriptedReport = scripted?.report
            scripted = nil
        }
        let request = try request(prompt: prompt, selection: selection, sessionID: sessionID, role: role,
            history: history, lastUsage: lastUsage, allowsWebSearch: searchesWeb,
            reviewingHumanIntervention: reviewingHumanIntervention, environment: inheritedEnvironment)
        var session = sessionID
        do {
            _ = try await runner.run(request) { event in
                switch event {
                case .provider(let event):
                    if case .session(let id) = event { session = id }
                    onEvent(.provider(event))
                case .tool(let text): onEvent(.tool(text))
                case .todo(let change):
                    let label = change.kind == .drafted ? "Plan" : "Plan updated"
                    onEvent(.tool(label + ": " + change.rows.map {
                        $0.id.rawValue + " " + $0.status.rawValue
                    }.joined(separator: ", ")))
                case .processStarted(let identity): onEvent(.processStarted(identity))
                case .contextReset: break
                case .usage(let reported, let total):
                    onEvent(.usage(Self.turnUsage(reported, selection: selection, session: session,
                        lastUsage: lastUsage, rollout: nil, total: total)))
                }
            }
            scripted?.finish()
        } catch let suspended as TurnSuspended {
            scripted?.finish(error: suspended)
            throw HumanInterventionSuspended(token: suspended.token.id)
        } catch {
            scripted?.finish(error: error)
            throw error
        }
    }

    private func request(
        prompt: String, selection: ModelSelection, sessionID: String?, role: String?, history: [TurnMessage],
        lastUsage: TurnUsage?, allowsWebSearch: Bool, reviewingHumanIntervention: Bool,
        environment: [String: String]
    ) throws -> TurnRequest {
        let route: TurnRequest.Route
        if let scripted {
            route = .modelLoop(transport: scripted.transport, contextWindow: contextWindows(selection))
        } else if WorkerAnswer(provider: selection.provider) == .modelLoop {
            route = .modelLoop(transport: transports(selection), contextWindow: contextWindows(selection))
        } else {
            let (provider, executable) = try agents(selection.provider)
            let efforts = ModelSelection.supportedEfforts(provider: selection.provider, model: selection.model)
            route = .commandLine(provider: provider, executable: executable,
                model: selection.model.isEmpty ? nil : selection.model,
                effort: efforts.contains(selection.effort) ? selection.effort.rawValue : nil,
                environment: CodexCLIClient.environment(from: environment), allowsWebSearch: allowsWebSearch)
        }
        return TurnRequest(prompt: prompt, route: route, sessionID: sessionID, history: history, role: role,
            reviewingHumanIntervention: reviewingHumanIntervention,
            previousSessionTotal: lastUsage.flatMap { usage in
                guard let session = usage.session, let total = usage.sessionTotal else { return nil }
                return (session, total)
            }, previousContextTokens: lastUsage?.session == sessionID ? lastUsage?.contextTokens : nil)
    }

    func compact(
        selection: ModelSelection,
        sessionID: String?,
        role: String?,
        trigger: ContextCompaction.Trigger,
        history: [TurnMessage] = [],
        lastUsage: TurnUsage? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (compaction: ContextCompaction, usage: TurnUsage?) {
        guard try ScriptedWorkerRun.scriptURL(
            isolation  : .current,
            environment: ProcessInfo.processInfo.environment
        ) == nil else {
            throw AutomationFailure("Context compaction is unavailable during a scripted worker run.")
        }
        let request = try request(prompt: "", selection: selection, sessionID: sessionID, role: role, history: history,
            lastUsage: lastUsage, allowsWebSearch: false, reviewingHumanIntervention: false, environment: inheritedEnvironment)
        let result = try await runner.compact(request, trigger: trigger == .manual ? .manual : .automatic)
        return (ContextCompaction(provider: selection.provider, trigger: trigger, preTokens: result.preTokens,
            postTokens: result.postTokens, contextWindow: result.contextWindow, summary: result.summary),
            result.reported.map { Self.turnUsage($0, selection: selection, session: sessionID,
                lastUsage: lastUsage, rollout: nil, total: result.usage) })
    }

    static func turnUsage(
        _ reported: ProviderUsage, selection: ModelSelection, session: String?,
        lastUsage: TurnUsage?, rollout: CodexRollout.Reading?, total: TurnTokenUsage? = nil
    ) -> TurnUsage {
        let previous = lastUsage.flatMap { usage -> (session: String, tokens: ProviderUsage.Tokens)? in
            guard let session = usage.session, let total = usage.sessionTotal else { return nil }
            return (session, total)
        }
        return TurnUsage(provider: selection.provider,
            model: reported.model ?? (selection.model.isEmpty ? nil : selection.model), session: session,
            turn: total?.tokens ?? TurnTokenUsage.own(reported, session: session, previous: previous),
            sessionTotal: reported.isSessionTotal ? reported.tokens : nil,
            contextTokens: reported.contextTokens ?? rollout?.contextTokens,
            contextWindow: reported.contextWindow ?? rollout?.contextWindow,
            rateLimits: reported.rateLimits.isEmpty ? rollout?.rateLimits ?? [] : reported.rateLimits)
    }

    func withheld(_ text: String) -> String { tools.withheld(text) }
    @discardableResult
    func suspendForHumanIntervention() throws -> UUID { try runner.suspend().id }
    func endHumanIntervention(_ token: UUID) throws { try runner.end(.init(id: token)) }
    func stop() { runner.stop(marksTaskInterrupted: true) }
    func waitForHumanInterventionCleanup() async { await runner.waitForCleanup() }
    func waitForCallsToDrain(within limit: Duration) async -> Bool { await runner.waitForCallsToDrain(within: limit) }
    func retire() async { await runner.retire() }
    func close() async throws { try await runner.close() }

    static func turn(
        prompt              : String,
        provider            : ChatProvider,
        selection           : ModelSelection,
        sessionID           : String?,
        role                : String?,
        bridgeExecutable    : URL,
        connectionFile      : URL,
        workingDirectory    : URL,
        inheritedEnvironment: [String: String],
        isCompaction        : Bool = false,
        allowsWebSearch     : Bool = false,
        offersWeb           : Bool = false,
        tools               : String = AutomationTools.instructions,
        toolNames           : [String] = []
    ) -> ProviderTurn {
        let searchesWeb = allowsWebSearch && !isCompaction
        let efforts = ModelSelection.supportedEfforts(provider: selection.provider, model: selection.model)
        return ProviderTurn(
            provider        : provider,
            model           : selection.model.isEmpty ? nil : selection.model,
            sessionID       : sessionID,
            prompt          : prompt,
            instructions    : instructions(
                role       : role,
                searchesWeb: searchesWeb,
                offersWeb  : offersWeb,
                tools      : tools,
                toolNames  : toolNames
            ),
            bridgeExecutable: bridgeExecutable.path,
            connectionFile  : connectionFile.path,
            workingDirectory: workingDirectory.path,
            effort          : efforts.contains(selection.effort) ? selection.effort.rawValue : nil,
            environment     : CodexCLIClient.environment(from: inheritedEnvironment),
            isCompaction    : isCompaction,
            allowsWebSearch : searchesWeb
        )
    }

    /// Resolves the signed-in command line for a provider.
    nonisolated static func agent(for provider: ModelProvider) throws -> (ChatProvider, URL) {
        switch (provider, WorkerAnswer(provider: provider)) {
        case (_, .modelLoop):
            throw AutomationFailure("\(provider.title) responds through Braus’s own loop and has no command line.")
        case (.claudeCode, .agent):
            return (.claude, try ClaudeCLIClient.executableURL())
        case (.codex, .agent):
            return (.codex, try CodexCLIClient.executableURL())
        case (.anthropic, .agent), (.gemini, .agent), (.ollama, .agent):
            throw AutomationFailure("\(provider.title) is marked as an agent, and this host has no command "
                                    + "line for it.")
        }
    }

}

struct WorkerLoopInstructions: LoopInstructionComposing {
    let toolNames: [String]

    init(toolNames: [String] = []) { self.toolNames = toolNames }

    func systemText(role: String?, hasTools: Bool, tools: String) -> String {
        TurnRunner.systemPrompt(role: role, hasTools: hasTools, tools: tools,
            toolNames: toolNames)
    }
}
