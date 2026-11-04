@_exported import Capabilities
import CapabilityRegistrations
import ChatCore
import AppAdapters
import AppKit
import CryptoKit
import AutomationRuntime
import EngineCore
import Foundation
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
    public let profile: SessionProfile
    private var observedToolAttempts: [String: Int] = [:]
    public private(set) var guides: AppGuides?
    private var guidesPrepared = false
    public let session: any AutomationSessionOperating

    /// The routes beyond the Seat this instance was composed with: they decide the tools it serves
    /// (`toolDefinitions`) and whether `adapters` and `router` start set. Empty serves the Seat alone.
    public let channels: AutomationChannels

    /// The app adapters `app_capabilities` and `app_call` reach, without a session or a seat; nil
    /// without `.adapters`, where those tools are refused. Irreversible verbs are refused unless the host
    /// built them with a per-call approver.
    public var adapters: AppAdapters? { dispatcher.adapters }

    /// The routing rules `open_session` asks before any session opens (spec 2026-10-14-mac-driver-design,
    /// section 2); nil opens every app as asked. Set with `.web` or `.adapters`, the routes it can offer: a web page
    /// only with a web session (its context says whether there is one), an adapter only with the adapters (R02).
    public var router: TaskRouter? { dispatcher.router }

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

    /// The task declared through `plan` and not yet ended: its calls are attributed to it.
    public var openTask: OpenTask? { taskCycle.openTask }

    /// The candidate the last checkpoint or end answered that no interpretation has taken yet: until one does,
    /// nothing of that attempt is learned.
    public var pendingCandidate: String? { taskCycle.pendingCandidate }

    private let producerSecrets: ProducerSecrets
    private let sceneText: SceneTextPolicy
    private let formatter: ResultFormatter
    private let taskCycle: TaskCycleHandler
    let dispatcher: CallDispatcher
    private var cataloguePreparation: Task<Void, Never>?

    /// Retains providers and keeps capability contracts aligned with the adapters and routes served.
    /// Conflicting registered identifiers or inconsistent family ownership are composition errors and fail at startup.
    public init(
        session: any AutomationSessionOperating,
        channels: AutomationChannels = [],
        adapters: AppAdapters? = nil,
        router requestedRouter: TaskRouter? = nil,
        offersWeb: Bool = false,
        capabilities: [any CapabilityProviding]? = nil,
        profile requestedProfile: SessionProfile? = nil,
        recording: (any CapabilityRecording)? = nil,
        guardThreshold: GuardThreshold = .init(),
        guides: AppGuides? = nil,
        guideApp: (@MainActor (String) -> OpenedApp)? = nil,
        resolveGuideApp: @escaping @MainActor @Sendable (String) -> OpenedApp = {
            OpenedApp(bundleID: $0, version: nil, locale: Locale.current.identifier)
        }
    ) {
        // An omitted profile keeps the legacy status shape while using the app preset's permissions.
        let profile = requestedProfile ?? .app
        var composed = channels
        if adapters != nil { composed.insert(.adapters) }
        if offersWeb { composed.insert(.web) }
        let guides = profile.catalogue == .open ? nil : guides
        self.guides = guides
        self.profile = profile
        self.session = session
        self.channels = composed
        let adapters = adapters ?? (composed.contains(.adapters) ? AppAdapters.standard() : nil)
        let router: TaskRouter? = requestedRouter ?? (composed.isDisjoint(with: [.web, .adapters]) ? nil : TaskRouter())
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        let taskCycle = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter,
            profile: profile, reportsProfile: requestedProfile != nil)
        taskCycle.guardThreshold = guardThreshold
        taskCycle.memoryAccess = profile.memoryAccess
        taskCycle.appGuides = guides
        taskCycle.resolveGuideApp = guideApp ?? resolveGuideApp
        self.producerSecrets = secrets
        self.sceneText = sceneText
        self.formatter = formatter
        self.taskCycle = taskCycle
        let recording = recording ?? MemoryAccess.$current.withValue(taskCycle.memoryAccess) {
            session.memoryDirectory.map { CapabilityCallRecorder(memory: .shared(for: $0)) }
        }
        let dispatcher = CallDispatcher(session: session, channels: composed, adapters: adapters, router: router,
                                         secrets: secrets, sceneText: sceneText, taskCycle: taskCycle, formatter: formatter,
                                         capabilities: profile.catalogue == .open ? [] : (capabilities ?? RegisteredProviders.make()),
                                         recording: recording,
                                         list: ToolList(attendance: profile.attendance, level: profile.level), guides: guides,
                                         resolveGuideApp: guideApp ?? resolveGuideApp)
        self.dispatcher = dispatcher
        taskCycle.availableRecallChannels = { [weak dispatcher] in dispatcher?.registry.channelKeys ?? [] }
        prepareCapabilitySearch()
    }

    private func prepareCapabilitySearch() {
        cataloguePreparation?.cancel()
        if let directory = session.memoryDirectory {
            let entries = dispatcher.entries
            let dispatcher = self.dispatcher
            cataloguePreparation = MemoryAccess.$current.withValue(taskCycle.memoryAccess) {
                Task { [weak dispatcher] in
                    if let search = await CatalogueEmbedding.prepareSearch(
                        entries: entries, supportDirectory: directory.appendingPathComponent("Catalogue")
                    ) {
                        dispatcher?.installSearch(search)
                    }
                }
            }
        }
    }

    deinit { cataloguePreparation?.cancel() }

    /// Resolves a delegated name before a host applies its admission policy.
    public func resolvedCall(_ name: String, arguments: JSONValue) throws -> (name: String, arguments: JSONValue) {
        try dispatcher.resolvedCall(name, arguments: arguments)
    }

    /// Runs one tool call. Before anything of it is written (its transcript line, its record), the texts it would
    /// type are classified on a fresh perception (`scope(of:_:)`, W1): what the call withholds and the field each
    /// text step is bound to are its `CallScope`, bound from there to its last output, the error it throws included.
    public func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        recordToolAttempt(name)
        return try await callRecorded(name, arguments)
    }

    /// Counts one request at its host boundary, including requests refused before dispatch.
    public func recordToolAttempt(_ name: String) {
        let key = toolDefinitions.contains(where: { $0["name"].string == name }) || name == "memory_task"
            ? name : "<unlisted>"
        observedToolAttempts[key, default: 0] += 1
    }

    /// Applies the same admission and execution rules after the host has counted this attempt.
    public func callRecorded(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        return try await MemoryAccess.$current.withValue(taskCycle.memoryAccess) {
                if profile.level == .observe, name != "open_session", effectClass(of: name, arguments: arguments) != .read {
                    throw AutomationFailure(ModelText.text(.init(rawValue: "profile.observe_only.v1")))
                }
                try await prepareGuides()
                let result = try await dispatcher.call(name, arguments)
                var metadata = result["_meta"].object ?? [:]
                metadata["braus/content-complete"] = .bool(true)
                return result.adding("_meta", .object(metadata))
        }
    }

    /// Carries this instance's memory permissions through asynchronous host work.
    package func withRuntimeConfiguration<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        try await MemoryAccess.$current.withValue(taskCycle.memoryAccess) { try await body() }
    }

    /// Reports wired capabilities and attempts, independently of successful functional acceptance.
    public var configurationEvidence: JSONValue {
        .object([
            "contract": .string("braus-t2-single-path"),
            "features": .array(Self.runtimeFeatures.map(JSONValue.string)),
            "pending_experiments": .array([]),
            "tool_schema_sha256": (try? toolSchemaDigest()).map(JSONValue.string) ?? .null,
            "served_tools": .array(toolDefinitions.compactMap { $0["name"].string }.map(JSONValue.string)),
            "tool_loading": .string("upfront"),
            "tool_attempts_scope": .string("session"),
            "tool_attempts": .object(observedToolAttempts.mapValues { .number(Double($0)) }),
            "guide_scope": .string("private-only")
        ])
    }

    /// Hashes the actual served schema using the same canonical JSON as model requests.
    private func toolSchemaDigest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(JSONValue.array(toolDefinitions))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static let runtimeFeatures = ["batch_policy", "batch_tool", "brain_enrichment", "capability_find_call",
        "committing_input", "compact_outcome", "compact_recall", "compact_tool_surface", "internal_task_state",
        "plan_step_end", "qualified_seen_effect", "safe_scene_text", "scene_after_uncertain", "second_look",
        "structured_seat_state", "task_prompt"]

    /// The host preflight reads identity without exposing or calling a removed model tool.
    public func runtimeIdentity() async throws -> JSONValue {
        _ = try toolSchemaDigest()
        guard let directory = session.memoryDirectory else {
            throw MemoryTaskTool.Failure(code: "no_memory",
                message: ModelText.text(.init(rawValue: "task_cycle_handler__answer.directory.v1")))
        }
        return await MemoryAccess.$current.withValue(taskCycle.memoryAccess) {
            await taskCycle.statusAnswer(memory: MemoryService.shared(for: directory))
                .adding("profile", profile.status)
                .adding("runtime", configurationEvidence)
        }
    }

    public var toolList: ToolList { dispatcher.toolList }
    public var guidesEnabled: Bool { dispatcher.guidesEnabled }
    public var groupIndex: String { ToolCatalogue.groupIndex(dispatcher.entries) }

    /// Replaces only the search engine, retaining the frozen catalogue and authority.
    public func installCapabilitySearch(_ search: CapabilitySearch) { dispatcher.installSearch(search) }

    /// The fixed initial list for the composed profile and transport.
    public var toolDefinitions: [JSONValue] {
        dispatcher.toolDefinitions
    }

    /// The additional schemas permitted by this composition, independent of search ranking.
    /// Hosts may publish this frozen metadata through their protocol; execution still uses `call`.
    public var capabilityDefinitions: [JSONValue] {
        dispatcher.capabilityDefinitions
    }

    /// This instance's instructions: those of the channels it serves, as `toolDefinitions`.
    public var instructions: String { Self.instructions(for: channels) }

    /// Marks an explicit Stop, not a temporary human suspension. The host drains admitted calls
    /// before finishing this task, so a call already in flight retains its original attribution.
    public func markTaskInterrupted() { taskCycle.markTaskInterrupted(producer: producer) }

    /// Closes the stopped attempt without claiming success or interpreting a candidate.
    /// A failed write keeps both the task and the interruption pending for a later retry.
    public func finishInterruptedTask() async throws {
        try await MemoryAccess.$current.withValue(taskCycle.memoryAccess) { try await taskCycle.finishInterruptedTask() }
    }

    /// Closes an explicitly stopped task through the shared application and command line path.
    public func closeStoppedTask(_ cause: StopCause) async throws -> StoppedTask? {
        try await MemoryAccess.$current.withValue(taskCycle.memoryAccess) { try await taskCycle.closeStoppedTask(cause) }
    }

    /// Retains one sink. Committed changes are delivered synchronously on the main actor.
    public func observeTodo(_ sink: @escaping @MainActor @Sendable (TodoEvent) -> Void) {
        taskCycle.todoSink = sink
    }

    /// Retains one observer, called inline before each call returns or throws. Nil disables observation work.
    public func observeTaskState(_ sink: TaskStateSink?) {
        dispatcher.taskStateSink = sink
    }

    public func afterTurn() async {
        await MemoryAccess.$current.withValue(taskCycle.memoryAccess) { await taskCycle.afterTurn() }
    }

    /// Prepares profile guide files before calls use their indices and catalogue entry.
    public func prepareGuides() async throws {
        guard !guidesPrepared else { return }
        guard profile.catalogue != .open else { guidesPrepared = true; return }
        if guides == nil, !profile.options.guides.isEmpty {
            let prepared = try await AppGuides.load(sources: [GuideFiles(urls: profile.options.guides)],
                estimateTokens: { ($0.count + 3) / 4 }, similarity: { left, right in left == right ? 1 : 0 })
            try dispatcher.installProfileGuides(prepared)
            guides = prepared
            taskCycle.appGuides = prepared
            prepareCapabilitySearch()
        }
        guidesPrepared = true
    }

    public func forgetDeliveredMemory() { taskCycle.forgetDeliveredMemory() }

    /// Supplies the last archived task named by a restored conversation, without replaying any actions.
    public func restoreTaskReference(_ taskID: String?) { taskCycle.previousConversationTask = taskID }

    /// Supplies the next turn with the stopped task identity once, without replaying its action history.
    public func takeStoppedTaskNotice() -> String? { taskCycle.takeStoppedTaskNotice() }

    /// Consumes the notice only when the caller successfully renders it.
    public func withStoppedTaskNotice<T>(_ render: (String?) throws -> T) rethrows -> T {
        try taskCycle.withStoppedTaskNotice(render)
    }

    /// Reads task facts without consuming notices or scanning stored procedures.
    public func taskFacts(for bundleID: String?) async -> SeatTaskFacts {
        await taskCycle.taskFacts(for: bundleID)
    }

    /// What a host sends the agent after a turn that left a candidate it did not interpret, once per candidate;
    /// nil when there is none or it was asked already. Haiku 5.5 answered the person after an end and left the
    /// candidate, so nothing of a completed task was learned (canary of 14/10/2026).
    public func takeInterpretationReminder() -> String? { taskCycle.takeInterpretationReminder() }

    /// Interprets a completed task's candidate internally through the procedure producer.
    /// Returns nil when no completed candidate remains; this is not a model tool.
    public func interpretLeftCandidate() async -> (candidate: String, answer: JSONValue)? {
        await MemoryAccess.$current.withValue(taskCycle.memoryAccess) { await taskCycle.interpretLeftCandidate() }
    }

    /// Forgets the candidate the last conversation left uninterpreted, so a new conversation is reminded only of its
    /// own: the earlier one's interpretation would be refused as another producer's (14 October 2026). The candidate
    /// stays in the archive, uninterpreted, as the earlier conversation's.
    public func forgetConversation() { taskCycle.forgetConversation() }

    /// Reports the revisions the model's context still holds.
    public func contextHolds(_ hold: SceneContextHold) { sceneText.contextHolds(hold) }

    /// Builds a context boundary from the policy's own revision, atomically with applying it.
    @discardableResult
    public func contextHolds(after reason: SceneContextReset, keeping keptRevision: Int? = nil) -> SceneContextHold {
        sceneText.contextHolds(after: reason, keeping: keptRevision)
    }

    /// The latest whole scene sent to the model, for carrying into task state.
    public var latestScene: SceneAnswer? { sceneText.latest }

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
        return ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1"))
            + ToolCatalogue.routes(for: channels)
            + ModelText.text(.init(rawValue: "seat_line.general.v2"))
            + ToolCatalogue.web(for: channels)
            + ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.3"))
            + ToolCatalogue.files(for: channels)
            + ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.4"))
            + (channels.contains(.adapters) ? ModelText.text(.init(rawValue: "prompt.adapters.v1")) : "")
            + ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.5"))
            + "\n" + ToolCatalogue.taskInstructions
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
