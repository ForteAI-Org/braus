@_exported import Capabilities
import CapabilityRegistrations
import AppAdapters
import AppKit
import CryptoKit
import AutomationRuntime
import EngineCore
import Foundation
import Switches
import os
import LocalMCP
import Memory
import PerceptionCore
#if BRAUS_PHASES
import PhaseSignposts
#endif
import PrivateSymbols
import SeatCore
import TaskRouting

/// CallProducer is who makes a set of tool calls, as the living memory records them: the source (the
/// app's worker, an external client, the command line), the stream that tells two producers of one
/// source apart, the trace the producer is in now (a message, a conversation), which it updates, and
/// the message being answered when the frontend has one, which a task names as its origin.
public struct CallProducer: Sendable, Equatable {
    public var source: MemoryEventSource
    public var streamID: String
    public var traceID: String?
    public var messageRef: String?

    public init(source: MemoryEventSource, streamID: String, traceID: String? = nil, messageRef: String? = nil) {
        self.source     = source
        self.streamID   = streamID
        self.traceID    = traceID
        self.messageRef = messageRef
    }
}

/// AutomationTools is the MCP adapter over an AutomationSessionOperating session. It validates a complete
/// request before effects, requires the current ephemeral session ID, and records authoritative outcomes
/// for the transcript.
public final class AutomationTools {
    public let session: any AutomationSessionOperating

    /// The routes beyond the Seat this instance was composed with: they decide the tools it serves
    /// (`toolDefinitions`) and whether `adapters` and `router` start set. Empty serves the Seat alone.
    public let channels: AutomationChannels

    /// The app adapters `app_capabilities` and `app_call` reach, without a session or a seat; nil
    /// without `.adapters`, where those tools are refused. Irreversible verbs are refused unless the host
    /// built them with a per-call approver.
    public var adapters: AppAdapters? {
        get { dispatcher.adapters }
        set { dispatcher.adapters = newValue }
    }

    /// The routing rules `open_session` asks before any session opens (spec 2026-10-14-mac-driver-design,
    /// section 2); nil opens every app as asked. Set with `.web` or `.adapters`, the routes it can offer: a web page
    /// only with a web session (its context says whether there is one), an adapter only with the adapters (R02).
    public var router: TaskRouter? {
        get { dispatcher.router }
        set { dispatcher.router = newValue }
    }

    public var record: ((String) throws -> Void)? {
        get { formatter.record }
        set { formatter.record = newValue }
    }

    /// Who makes the calls, as the living memory records them: the app's worker, an external client,
    /// the command line's chat. Each call is recorded under it, with the trace it names at that moment.
    public var producer: CallProducer {
        get { taskCycle.producer }
        set { taskCycle.producer = newValue }
    }

    /// The task the agent declared through `memory_task` and has not ended: its calls are attributed to it.
    public var openTask: OpenTask? { taskCycle.openTask }

    /// The candidate the last checkpoint or end answered that no interpretation has taken yet: until one does,
    /// nothing of that attempt is learned.
    public var pendingCandidate: String? { taskCycle.pendingCandidate }

    private let producerSecrets: ProducerSecrets
    private let sceneText: SceneTextPolicy
    private let formatter: ResultFormatter
    private let taskCycle: TaskCycleHandler
    private let dispatcher: CallDispatcher

    /// Retains providers and keeps capability contracts aligned with the adapters and routes served.
    /// Conflicting registered identifiers or inconsistent family ownership are composition errors and fail at startup.
    public init(
        session: any AutomationSessionOperating,
        channels: AutomationChannels = [],
        adapters: AppAdapters? = nil,
        offersWeb: Bool = false,
        capabilities: [any CapabilityProviding] = RegisteredProviders.make(),
        recording: (any CapabilityRecording)? = nil
    ) {
        var composed = channels
        if adapters != nil { composed.insert(.adapters) }
        if offersWeb { composed.insert(.web) }
        self.session = session
        self.channels = composed
        let adapters = adapters ?? (composed.contains(.adapters) ? AppAdapters.standard() : nil)
        let router: TaskRouter? = composed.isDisjoint(with: [.web, .adapters]) ? nil : TaskRouter()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        let taskCycle = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        self.producerSecrets = secrets
        self.sceneText = sceneText
        self.formatter = formatter
        self.taskCycle = taskCycle
        self.dispatcher = CallDispatcher(session: session, channels: composed, adapters: adapters, router: router,
                                         secrets: secrets, sceneText: sceneText, taskCycle: taskCycle, formatter: formatter,
                                         capabilities: capabilities, recording: recording)
    }

    /// Runs one tool call. Before anything of it is written (its transcript line, its record), the texts it would
    /// type are classified on a fresh perception (`scope(of:_:)`, W1): what the call withholds and the field each
    /// text step is bound to are its `CallScope`, bound from there to its last output, the error it throws included.
    public func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        try await dispatcher.call(name, arguments)
    }

    /// The tools this instance serves and accepts: `definitions(for:)` of what it can do now, with the
    /// adapter tools while `adapters` is set and `open_session`'s `named` while `router` is.
    public var toolDefinitions: [JSONValue] { dispatcher.toolDefinitions }

    /// This instance's instructions: those of the channels it serves, as `toolDefinitions`.
    public var instructions: String { ToolCatalogue.instructions(for: dispatcher.served) }

    /// Marks an explicit Stop, not a temporary human suspension. The host drains admitted calls
    /// before finishing this task, so a call already in flight retains its original attribution.
    public func markTaskInterrupted() { taskCycle.markTaskInterrupted(producer: producer) }

    /// Closes the stopped attempt without claiming success or interpreting a candidate.
    /// A failed write keeps both the task and the interruption pending for a later retry.
    public func finishInterruptedTask() async throws { try await taskCycle.finishInterruptedTask() }

    /// Supplies the next turn with the stopped task identity once, without replaying its action history.
    public func takeStoppedTaskNotice() -> String? { taskCycle.takeStoppedTaskNotice() }

    /// What a host sends the agent after a turn that left a candidate it did not interpret, once per candidate;
    /// nil when there is none or it was asked already. Haiku 5.5 answered the person after an end and left the
    /// candidate, so nothing of a completed task was learned (canary of 14/10/2026).
    public func takeInterpretationReminder() -> String? { taskCycle.takeInterpretationReminder() }

    /// Interprets, as Braus, the candidate of a completed task the agent left uninterpreted after its reminder
    /// (`ProcedureProducer.brausInterpretation`), through the same `memory_task interpret` as the agent's, so the
    /// transcript shows it. Answers the candidate and the answer, or nil when nothing was left or the task did not complete.
    public func interpretLeftCandidate() async -> (candidate: String, answer: JSONValue)? {
        await taskCycle.interpretLeftCandidate(call: call)
    }

    /// Forgets the candidate the last conversation left uninterpreted, so a new conversation is reminded only of its
    /// own: the earlier one's interpretation would be refused as another producer's (14 October 2026). The candidate
    /// stays in the archive, uninterpreted, as the earlier conversation's.
    public func forgetConversation() { taskCycle.forgetConversation() }

    /// Forgets every scene the model read, so the next scene of any window is sent whole: for a new
    /// turn or a compacted context, which may no longer hold those scenes.
    public func forgetScene() { sceneText.forgetScene() }

    /// A text the host writes beside these records, such as what a command line's own web search asks or reads
    /// (`WebToolRecords`), with what they withhold withheld: the producer's secrets and the credential shapes (M07).
    public func withheld(_ text: String) -> String { producerSecrets.withheld(text) }

    /// What an end answer asks before the agent answers the person. A document the task changed and kept only as a
    /// copy is still open with the change; the app quit when the session ends then stops on its save prompt in the
    /// person's seat, where the next task finds it. In the instructions alone it was not followed (PhotoCraft,
    /// Sonnet 5.5, 14/10/2026); at the end of the task it is the next thing to do.
    public static let closeChangedCopies = TaskCycleHandler.closeChangedCopies

    /// What the browser engine is to the person: Braus's own Chrome and profile, not theirs, with no window unless they
    /// show it; a sign-in there is theirs to make in its window; a failure there sends nowhere without asking. Only the
    /// person's Use My Chrome, or one of their Chrome profiles paired with Braus that they choose, makes it their own
    /// Chrome for a conversation, which every answer then says under browser.
    public static let browserEngineProfile = ToolCatalogue.browserEngineProfile

    /// How many posts or articles of a page are read: in one collect_posts call, never by observing and scrolling.
    public static let bulkReading = ToolCatalogue.bulkReading

    /// The base instructions every provider turn over these tools runs with, in the CLI and the app alike, for the
    /// channels composed (R09): where an app or a page is driven and how the web is reached say only what those
    /// channels do, in the words `open_session`'s description uses too (`routes(for:)`, `web(for:)`).
    public static func instructions(for channels: AutomationChannels) -> String {
        ToolCatalogue.instructions(for: channels)
    }

    /// The tools an instance composed with `channels` serves: `open_session` takes `named` only where the
    /// router has another route to offer (`.web`, `.adapters`, R02), and the adapter tools exist
    /// only with `.adapters`.
    public static func definitions(for channels: AutomationChannels) -> [JSONValue] {
        ToolCatalogue.definitions(for: channels)
    }

    /// Returns fixed MCP guidance, independent of the session's channels and current state.
    public static func mcpInstructions(_ form: MCPInstructionsForm) -> String {
        ToolCatalogue.mcpInstructions(form)
    }

    public nonisolated static func interruptionPolicy(for name: String) -> InterruptionPolicy {
        ToolCatalogue.interruptionPolicy(for: name)
    }

    /// Resolves interruption using this instance's registered capability contracts as well as the core.
    public func interruptionClass(of tool: String, arguments: JSONValue) -> InterruptionClass {
        dispatcher.registry.interruptionClass(of: tool, arguments: arguments)
    }

    /// Resolves the named capability's effect, including adapter verbs and delegated calls.
    public func effectClass(of tool: String, arguments: JSONValue) -> EffectClass {
        dispatcher.registry.effectClass(of: tool, arguments: arguments)
    }

    /// Allows parallel execution only for a contract that explicitly promises it.
    public func isParallelSafe(_ tool: String, arguments: JSONValue) -> Bool {
        dispatcher.registry.isParallelSafe(tool, arguments: arguments)
    }

    /// The element a target names when the model copied the scene's id mark: the id between the quotes of a
    /// trailing `id:'…'`, with or without what the scene printed before it (`[field] Name id:'control|name'`,
    /// an unlabeled icon's `id:'?|@4,0'`). The scene resolves a target by its exact id or by its label, never by
    /// the two written together, so the copied line named nothing. Any other target is returned as written.
    public nonisolated static func elementReference(_ target: String) -> String {
        ToolArguments.elementReference(target)
    }

    public var offersWeb: Bool { channels.contains(.web) }

    public static func definitions(offeringAdapters: Bool, offeringWeb: Bool = false) -> [JSONValue] {
        var channels: AutomationChannels = []
        if offeringAdapters { channels.insert(.adapters) }
        if offeringWeb { channels.insert(.web) }
        return definitions(for: channels)
    }

    public static func instructions(offeringAdapters: Bool, offeringWeb: Bool = false) -> String {
        var channels: AutomationChannels = []
        if offeringAdapters { channels.insert(.adapters) }
        if offeringWeb { channels.insert(.web) }
        return instructions(for: channels)
    }

    /// The base instructions of an instance composed with no channel beyond the Seat (`instructions(for:)`).
    public static var instructions: String { instructions(for: []) }

    /// The tools of an instance composed with no channel beyond the Seat (`definitions(for:)`).
    public static var definitions: [JSONValue] { definitions(for: []) }

    /// Interruption policy for every served tool. Unknown and adapter verbs remain protected.
    public typealias InterruptionPolicy = InterruptionClass

    /// MCPInstructionsForm selects the complete client guidance or its standalone opening line.
    public nonisolated enum MCPInstructionsForm: Sendable, Hashable {
        case firstLine
        case full
    }

    static func isChoiceRecordFault(_ error: MemoryStoreError) -> Bool {
        TaskCycleHandler.isChoiceRecordFault(error)
    }

    static var resultMissing: String { TaskCycleHandler.resultMissing }

    @concurrent
    nonisolated static func fingerprints(of inputs: JSONValue) async -> [String: TaskResultCheck.FileFacts] {
        await TaskCycleHandler.fingerprints(of: inputs)
    }

    static func completed(_ named: [MemoryTaskTool.ResultCheck], fingerprints: [String: TaskResultCheck.FileFacts],
                          outputs: JSONValue, minimization: ValueMinimization) -> [MemoryTaskTool.ResultCheck] {
        TaskCycleHandler.completed(named, fingerprints: fingerprints, outputs: outputs, minimization: minimization)
    }

    static func paths(in texts: [String]) -> [String] { TaskCycleHandler.paths(in: texts) }

    static func guards(for checks: [MemoryTaskTool.ResultCheck], fingerprints: [String: TaskResultCheck.FileFacts],
                       outputs: JSONValue, minimization: ValueMinimization) -> [MemoryTaskTool.ResultCheck] {
        TaskCycleHandler.guards(for: checks, fingerprints: fingerprints, outputs: outputs, minimization: minimization)
    }

    static func completionEvidence(_ checks: [MemoryTaskTool.ResultCheck], checked: JSONValue?) -> JSONValue {
        TaskCycleHandler.completionEvidence(checks, checked: checked)
    }

    static func candidate(_ summary: ProcedureProducer.CandidateSummary) -> JSONValue {
        TaskCycleHandler.candidate(summary)
    }

    static func interpreted(_ outcome: InterpretationOutcome, candidateID: String) -> JSONValue {
        TaskCycleHandler.interpreted(outcome, candidateID: candidateID)
    }

    static func callRequest(_ name: String, _ arguments: JSONValue) throws -> AgentCallRequest {
        try ToolArguments.callRequest(name, arguments)
    }

    static func minimized(_ value: JSONValue, by minimization: ValueMinimization) -> JSONValue {
        ProducerSecrets.minimized(value, by: minimization)
    }

    static func evidence(_ check: OperationCheck?, kind: ActOutcomeKind) -> JSONValue? {
        ResultFormatter.evidence(check, kind: kind)
    }

    static func dataContext(of resolved: (adapter: any AppAdapting, verb: AdapterVerb), arguments: JSONValue,
                            result: JSONValue?) -> CallDataContext {
        ResultFormatter.dataContext(of: resolved, arguments: arguments, result: result)
    }

    static func collection(_ collected: PostCollection) -> JSONValue { ResultFormatter.collection(collected) }
}

extension AutomationTools {
    /// Reports invalid switch selections once at the composition root's startup.
    public static func reportInvalidSwitches() {
        _ = ResultFormatter.usesOutcomeV2
        SwitchBoard.reportInvalidValues()
    }
}
