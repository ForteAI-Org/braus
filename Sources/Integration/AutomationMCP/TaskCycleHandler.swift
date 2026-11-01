import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// TaskCycleHandler owns the open task, candidates and explicit interruption, borrowing the producer records.
final class TaskCycleHandler {
    let session: any AutomationSessionOperating
    unowned let producerSecrets: ProducerSecrets
    unowned let formatter: ResultFormatter

    init(
        session: any AutomationSessionOperating,
        secrets: ProducerSecrets,
        formatter: ResultFormatter
    ) {
        self.session = session
        self.producerSecrets = secrets
        self.formatter = formatter
    }

    /// Who makes the calls, as the living memory records them: the app's worker, an external client,
    /// the command line's chat. Each call is recorded under it, with the trace it names at that moment.
    var producer = CallProducer(source: .app, streamID: "tools-\(UUID().uuidString)")

    /// The task the agent declared through `memory_task` and has not ended: its calls are attributed to it.
    var openTask: OpenTask?

    private var interruptedProducer: CallProducer?

    /// Marks an explicit Stop, not a temporary human suspension. The host drains admitted calls
    /// before finishing this task, so a call already in flight retains its original attribution.
    func markTaskInterrupted(producer: CallProducer) {
        if interruptedProducer == nil { interruptedProducer = producer }
    }

    /// Closes the stopped attempt without claiming success or interpreting a candidate.
    /// A failed write keeps both the task and the interruption pending for a later retry.
    func finishInterruptedTask() async throws {
        guard let interruptedProducer else { return }
        guard let current = openTask else {
            self.interruptedProducer = nil
            return
        }
        guard let directory = session.memoryDirectory else {
            throw AutomationFailure("The stopped task could not be closed because its memory is unavailable.")
        }
        let owner = try TaskProducer(source: interruptedProducer.source, streamID: interruptedProducer.streamID)
        let draft = try TaskCheckpointDraft(
            kind: .end,
            declared: .abandoned,
            note: "The person stopped execution. Actions may have taken effect; completion was not established."
        )
        _ = try await TaskChannel.checkpoint(current, draft, producer: owner, memory: MemoryService.shared(for: directory))
        openTask = nil
        pendingCandidate = nil
        remindedCandidate = nil
        self.interruptedProducer = nil
        stoppedTaskNotice = "Braus stopped task \(current.taskID) and closed its attempt as abandoned, not completed. "
            + "Begin a new task for the current request, including any remaining work toward the same goal. "
            + "The abandoned task cannot be resumed. Observe current effects first; never repeat an uncertain action."
        try formatter.transcribe("Braus stopped task", .object(["task": .string(current.taskID), "outcome": .string("abandoned")]))
    }

    private var stoppedTaskNotice: String?

    /// Supplies the next turn with the stopped task identity once, without replaying its action history.
    func takeStoppedTaskNotice() -> String? {
        defer { stoppedTaskNotice = nil }
        return stoppedTaskNotice
    }

    /// The candidate the last checkpoint or end answered that no interpretation has taken yet: until one does,
    /// nothing of that attempt is learned.
    var pendingCandidate: String?

    /// The last candidate the host reminded the agent of, so that it asks once.
    private var remindedCandidate: String?

    /// The candidates interpreted in this process: an end that answers one again, with the same facts as its
    /// checkpoint, asks for nothing more.
    var interpretedCandidates: Set<String> = []

    /// The disk as the open task's file inputs stood when it declared them, by path: what a check of a file changed,
    /// kept or removed compares with. In memory only; kept until the next task begins, for the interpretation.
    var fingerprints: [String: TaskResultCheck.FileFacts] = [:]

    /// What a host sends the agent after a turn that left a candidate it did not interpret, once per candidate;
    /// nil when there is none or it was asked already. Haiku 5.5 answered the person after an end and left the
    /// candidate, so nothing of a completed task was learned (canary of 14/10/2026).
    func takeInterpretationReminder() -> String? {
        guard let candidate = pendingCandidate, candidate != remindedCandidate else { return nil }
        remindedCandidate = candidate
        return "Braus: memory_task answered candidate \(candidate), and you did not interpret it, so nothing of that "
            + "task is learned. Call memory_task interpret with that candidate now, as its answer describes. Then "
            + "reply with one short line."
    }

    /// The line an answer with a candidate leads with.
    static func interpretNext(_ candidate: String) -> String {
        "Call memory_task interpret with candidate \(candidate) in your next call, before you answer the person: "
            + "until then nothing of this task is learned."
    }

    /// What an end answer asks before the agent answers the person. A document the task changed and kept only as a
    /// copy is still open with the change; the app quit when the session ends then stops on its save prompt in the
    /// person's seat, where the next task finds it. In the instructions alone it was not followed (PhotoCraft,
    /// Sonnet 5.5, 14/10/2026); at the end of the task it is the next thing to do.
    static let closeChangedCopies = "Before you answer the person: a document this task changed and saved only as a "
        + "copy (Save a Copy, Export) is still open with the change. Close it now from the File menu (Close) and "
        + "choose not to save (Don't Save). Leave any other window or prompt as it is."

    /// Interprets, as Braus, the candidate of a completed task the agent left uninterpreted after its reminder
    /// (`ProcedureProducer.brausInterpretation`), through the same `memory_task interpret` as the agent's, so the
    /// transcript shows it. Answers the candidate and the answer, or nil when nothing was left or the task did not complete.
    func interpretLeftCandidate(call: (String, JSONValue) async throws -> JSONValue) async -> (candidate: String, answer: JSONValue)? {
        guard let candidate = pendingCandidate, let directory = session.memoryDirectory,
              let producer = try? TaskProducer(source: self.producer.source, streamID: self.producer.streamID),
              let stated = try? await ProcedureProducer.brausInterpretation(
                  candidateID: candidate, producer: producer, memory: MemoryService.shared(for: directory)) else { return nil }
        var arguments: [String: JSONValue] = [
            "operation": .string("interpret"), "candidate": .string(candidate),
            "procedure": .object(["label": .string(stated.label), "outcome": .string("completed")]),
        ]
        if !stated.phases.isEmpty {
            arguments["phases"] = .array(stated.phases.map { phase in
                .object(["from": .number(Double(phase.first + 1)), "to": .number(Double(phase.last + 1)), "label": .string(phase.label)])
            })
        }
        guard let answer = try? await call(MemoryTaskTool.name, .object(arguments)) else { return nil }
        return (candidate, answer)
    }

    /// Forgets the candidate the last conversation left uninterpreted, so a new conversation is reminded only of its
    /// own: the earlier one's interpretation would be refused as another producer's (14 October 2026). The candidate
    /// stays in the archive, uninterpreted, as the earlier conversation's.
    func forgetConversation() {
        pendingCandidate = nil
        remindedCandidate = nil
    }

    /// Answers a `memory_task` call: decodes it, writes the task's declaration through `TaskChannel`, and
    /// keeps the open task its next calls are attributed to. It acts on no application and is not
    /// recorded as a call. A refusal is answered as a tool error with a code and the facts the agent
    /// needs (the current revision, the open task), never thrown as a failure of an action.
    func call(_ arguments: JSONValue) async throws -> JSONValue {
        // The request's secrets are the producer's before any line of it is written, the transcript's first.
        for text in MemoryTaskTool.declaredSecrets(in: arguments) where !producerSecrets.secrets.contains(text) { producerSecrets.secrets.append(text) }
        try formatter.transcribe("→ \(MemoryTaskTool.name)", Self.masked(arguments))
        let answered: JSONValue
        let isError: Bool
        do {
            answered = try await taskAnswer(arguments)
            isError  = false
        } catch let failure as MemoryTaskTool.Failure {
            answered = Self.taskFailure(failure)
            isError  = true
        } catch let error as TaskContextError {
            answered = Self.taskFailure(Self.failure(of: error))
            isError  = true
        } catch let error as ProcedureError {
            answered = Self.taskFailure(Self.failure(of: error))
            isError  = true
        } catch {
            answered = Self.taskFailure(MemoryTaskTool.Failure(code: "memory_unavailable",
                message: "Braus's memory did not record the task (\(MemoryService.describe(error))). App actions still "
                    + "require the memory; use status."))
            isError  = true
        }
        try formatter.transcribe("← \(MemoryTaskTool.name)", answered)
        return MCPRouter.toolResult(answered, isError: isError)
    }

}
