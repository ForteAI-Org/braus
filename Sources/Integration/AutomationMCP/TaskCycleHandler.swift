import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import os

/// TaskCycleHandler owns the open task, candidates and explicit interruption, borrowing the producer records.
final class TaskCycleHandler {
    let profile: SessionProfile
    let reportsProfile: Bool
    var access: MemoryAccess { memoryAccess }
    let session: any AutomationSessionOperating
    unowned let producerSecrets: ProducerSecrets
    unowned let formatter: ResultFormatter

    init(
        session: any AutomationSessionOperating,
        secrets: ProducerSecrets,
        formatter: ResultFormatter,
        profile: SessionProfile = .app,
        reportsProfile: Bool = true
    ) {
        self.profile = profile
        self.reportsProfile = reportsProfile
        self.session = session
        self.producerSecrets = secrets
        self.formatter = formatter
    }

    /// Who makes the calls, as the living memory records them: the app's worker, an external client,
    /// the command line's chat. Each call is recorded under it, with the trace it names at that moment.
    var producer = CallProducer(source: .app, streamID: "tools-\(UUID().uuidString)")

    /// The task declared by the current plan and not ended; its calls are attributed to its rows.
    var openTask: OpenTask?

    var todo: Todo?
    var todoSink: (@MainActor @Sendable (TodoEvent) -> Void)?
    var bufferedCalls: [CallAttribution] = []
    var bufferedGestures: [TodoGesture] = []
    struct RowOpening {
        let expectation: TaskResultCheck.Expectation
        let openedAtMS: Int64
        let before: TaskResultCheck.FileFacts?
    }
    var rowOpenings: [TodoRowID: RowOpening] = [:]
    var todoRecordedAtMS: Int64 = 0
    var rowExpectationTimes: [TodoRowID: Int64] = [:]

    /// The active row's volatile predicates, for readers that need its declared file result.
    var currentRowExpectations: [TaskResultCheck.Expectation] {
        guard let row = todo?.rows.first(where: { $0.status == .inProgress }),
              let expected = rowChecks[row.id]?.read ?? row.expected else { return [] }
        return [expected]
    }

    var rowChecks: [TodoRowID: MemoryTaskTool.ResultCheck] = [:]
    var deliveredRows: Set<TodoRowID> = []
    var rowMemory: [TodoRowID: RowMemory] = [:]
    var stoppedReference: StoppedTask?
    var previousConversationTask: String?
    var planGuardArmed = false
    var gesturesWithoutPlan = 0
    var lastGestureUncertain: Bool?
    var guardThreshold = GuardThreshold()

    var memoryAccess: MemoryAccess = .readLearn
    var appGuides: AppGuides?
    var resolveGuideApp: @MainActor (String) -> OpenedApp = {
        OpenedApp(bundleID: $0, version: nil, locale: Locale.current.identifier)
    }
    var availableRecallChannels: @MainActor () -> Set<String> = { [] }
    var planRevisionWritten: (@MainActor () async throws -> Void)?
    var planMemoryBudget = RecallRendering.answerBudget
    var deliveredOffers: [TodoRowID: [RecallRendering.OfferedPart]] = [:]
    var deliveredComposition: [TodoRowID: [String: RecallChoice.CompositionPart]] = [:]
    var deliveredPlanParts: [TodoRowID: String] = [:]
    var deliveredGuideApps: Set<String> = []
    var activePlan: UUID?
    var interruptionIdentity = UUID()
    private var isPlanning = false
    private var planWaiters: [CheckedContinuation<Void, Never>] = []

    /// Serializes plan commits while leaving Stop free to invalidate the active call.
    func acquirePlan() async {
        if isPlanning { await withCheckedContinuation { planWaiters.append($0) } }
        else { isPlanning = true }
    }

    func releasePlan() {
        if planWaiters.isEmpty { isPlanning = false }
        else { planWaiters.removeFirst().resume() }
    }

    var interruptedProducer: CallProducer?

    /// Marks an explicit Stop, not a temporary human suspension. The host drains admitted calls
    /// before finishing this task, so a call already in flight retains its original attribution.
    func markTaskInterrupted(producer: CallProducer) {
        activePlan = nil
        interruptionIdentity = UUID()
        if interruptedProducer == nil { interruptedProducer = producer }
    }

    /// Closes the stopped attempt without claiming success or interpreting a candidate.
    /// A failed write keeps both the task and the interruption pending for a later retry.
    func finishInterruptedTask() async throws {
        guard interruptedProducer != nil else { return }
        _ = try await closeStoppedTask(.person)
        interruptedProducer = nil
    }

    var stoppedTaskNotice: String?

    /// Keeps the stopped notice pending if rendering fails.
    func withStoppedTaskNotice<T>(_ render: (String?) throws -> T) rethrows -> T {
        let result = try render(stoppedTaskNotice)
        stoppedTaskNotice = nil
        return result
    }

    /// Supplies the next turn with the stopped task identity once, without replaying its action history.
    func takeStoppedTaskNotice() -> String? {
        defer { stoppedTaskNotice = nil }
        return stoppedTaskNotice
    }

    /// Reads the open task and the procedure count allowed by the session profile.
    func taskFacts(for bundleID: String?) async -> SeatTaskFacts {
        SeatTaskFacts(isOpen: openTask != nil, learnedForApp: await learnedForPlanApp(bundleID))
    }

    /// The candidate the last checkpoint or end answered that no interpretation has taken yet: until one does,
    /// nothing of that attempt is learned.
    var pendingCandidate: String?

    /// The candidates interpreted in this process: an end that answers one again, with the same facts as its
    /// checkpoint, asks for nothing more.
    var interpretedCandidates: Set<String> = []

    /// The disk as the open task's file inputs stood when it declared them, by path: what a check of a file changed,
    /// kept or removed compares with. In memory only; kept until the next task begins, for the interpretation.
    var fingerprints: [String: TaskResultCheck.FileFacts] = [:]

    /// What a host sends the agent after a turn that left a candidate it did not interpret, once per candidate;
    /// nil when there is none or it was asked already. Haiku 5.5 answered the person after an end and left the
    /// candidate, so nothing of a completed task was learned (canary of 14/10/2026).
    func takeInterpretationReminder() -> String? { nil }

    /// What an end answer asks before the agent answers the person. A document the task changed and kept only as a
    /// copy is still open with the change; the app quit when the session ends then stops on its save prompt in the
    /// person's seat, where the next task finds it. In the instructions alone it was not followed (PhotoCraft,
    /// Sonnet 5.5, 14/10/2026); at the end of the task it is the next thing to do.
    static let closeChangedCopies = ModelText.text(.init(rawValue: "task_cycle_handler.closeChangedCopies.v1"))
        + ModelText.text(.init(rawValue: "task_cycle_handler.closeChangedCopies.v1.2"))
        + ModelText.text(.init(rawValue: "task_cycle_handler.closeChangedCopies.v1.3"))

    /// Learns a completed candidate at the internal producer boundary, without a model-tool call.
    func interpretLeftCandidate() async -> (candidate: String, answer: JSONValue)? {
        guard access.learns else { pendingCandidate = nil; return nil }
        guard let candidate = pendingCandidate else { return nil }
        do {
            let (memory, owner) = try cycleMemory()
            guard let stated = try await ProcedureProducer.brausInterpretation(
                candidateID: candidate, producer: owner, memory: memory) else { return nil }
            var parts = [try PartStatement(reference: .procedure, label: stated.label, outcome: .completed)]
            for phase in stated.phases {
                parts.append(try PartStatement(reference: .phase(first: phase.first, last: phase.last),
                    label: phase.label, outcome: nil))
            }
            let statement = try ProcedureInterpretation(candidateID: candidate, parts: parts)
            let outcome = try await ProcedureProducer.interpret(statement, producer: owner, memory: memory)
            interpretedCandidates.insert(candidate)
            if pendingCandidate == candidate { pendingCandidate = nil }
            await RecallService.shared(for: memory).schedule()
            return (candidate, MCPRouter.toolResult(Self.interpreted(outcome, candidateID: candidate)))
        } catch {
            let diagnostic = producerSecrets.withheld(MemoryService.describe(error))
            Logger(subsystem: "dev.forte.Braus", category: "TaskCycle").error("Task interpretation failed: \(diagnostic, privacy: .private)")
            return nil
        }
    }

    /// Forgets the candidate the last conversation left uninterpreted, so a new conversation is reminded only of its
    /// own: the earlier one's interpretation would be refused as another producer's (14 October 2026). The candidate
    /// stays in the archive, uninterpreted, as the earlier conversation's.
    func forgetConversation() {
        pendingCandidate = nil
        forgetDeliveredMemory()
        previousConversationTask = nil
        stoppedReference = nil
        stoppedTaskNotice = nil
    }

}
