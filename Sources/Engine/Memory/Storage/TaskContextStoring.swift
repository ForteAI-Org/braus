//
//  TaskContextStoring.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore

/// StoredTaskAttempt is an attempt read back with where its episode stands: running while
/// `in_progress`, then completed, failed, cancelled (abandoned) or interrupted (a resumption replaced
/// it). An attempt left `in_progress` by a process that ended stays so: incomplete, never completed.
public struct StoredTaskAttempt: Sendable {
    public let attempt: TaskAttempt
    public let status: TaskStatus
    public let endedAtMS: Int64?

    public init(attempt: TaskAttempt, status: TaskStatus, endedAtMS: Int64?) {
        self.attempt   = attempt
        self.status    = status
        self.endedAtMS = endedAtMS
    }
}

/// TaskContextStoring keeps the tasks agents communicate: their revisions, their attempts as episodes
/// of the memory, the checkpoints and ends they declare with their outputs. It stores what the agent
/// states and checks only references, ownership, revisions and order; it infers no goal, no label
/// and no success. Every write is one transaction and answers after its commit. A task belongs to the
/// producer that opened it: every operation names the producer and another one is refused.
public protocol TaskContextStoring: Sendable {

    /// Opens a task: its record, its first revision and its first attempt, in progress.
    func open(_ task: TaskRecord, revision: TaskRevision, attempt: TaskAttempt) async throws -> MemoryReceipt

    /// Adds a revision after the one the caller read (`expecting`): another current revision is
    /// `staleRevision`, a closed task `closed`. The same revision offered again is `alreadyApplied`.
    func revise(
        _ revision       : TaskRevision,
        expecting current: Int,
        by producer      : TaskProducer
    ) async throws -> MemoryReceipt

    /// Records a checkpoint, or the end that closes the attempt and the task with the declared status,
    /// at the task's current revision. A draft that declares the same as the attempt's last checkpoint
    /// answers that one with `alreadyApplied`: a retried call adds nothing.
    func checkpoint(
        _ draft      : TaskCheckpointDraft,
        attempt      : String,
        at recordedAtMS: Int64,
        by producer  : TaskProducer
    ) async throws -> (receipt: MemoryReceipt, checkpoint: TaskCheckpoint)

    /// Opens a new attempt of an open task, which resumes the last one: a running last attempt is
    /// marked interrupted at the new one's opening instant, in the same transaction.
    func resume(_ attempt: TaskAttempt) async throws -> MemoryReceipt

    /// The task, nil when none is stored under the id; `foreignTask` when it belongs to another producer.
    func task(_ taskID: String, for producer: TaskProducer) async throws -> TaskRecord?

    /// One revision of a task of the producer.
    func revision(_ revision: Int, of taskID: String, for producer: TaskProducer) async throws -> TaskRevision?

    /// The task's attempts by ordinal.
    func attempts(of taskID: String, for producer: TaskProducer) async throws -> [StoredTaskAttempt]

    /// An attempt's checkpoints and end by sequence.
    func checkpoints(of attemptID: String, for producer: TaskProducer) async throws -> [TaskCheckpoint]

    /// The calls attributed to an attempt, by the order they were attributed in.
    func calls(of attemptID: String, for producer: TaskProducer) async throws -> [String]
}

/// OperationFactStoring writes the essential facts of the operations, each group in one transaction
/// answered after its commit: a call confirmed before its effect (`open`), its samples, and its end
/// with its effect and verifications (`conclude`). Its writes are idempotent by identity: the same
/// facts offered again are `alreadyApplied`, another content under the same identity is a typed
/// conflict that writes nothing, so a producer retries a write with the same values and never
/// with a new gesture.
public protocol OperationFactStoring: Sendable {

    /// The call planned and started, its task attribution (an episode membership and the revision)
    /// and its withheld values, in one transaction.
    func open(_ opening: OperationOpening) async throws -> MemoryReceipt

    /// The batch started with its steps planned, attributed as a container of the attempt.
    func open(batch opening: BatchOpening) async throws -> MemoryReceipt

    /// A planned step of a batch started, attributed to the attempt as an operation.
    func start(step eventID: String, atMS: Int64, attribution: TaskCallAttribution?) async throws -> MemoryReceipt

    /// Samples of calls and the gaps withheld values left in them, all or none.
    func record(samples: [CaptureSample], redactions: [ValueRedaction]) async throws -> MemoryReceipt

    /// The call's end: its samples, terminal state and result, effect, verifications, withheld values
    /// and withdrawals, all or none.
    func conclude(_ conclusion: OperationConclusion) async throws -> MemoryReceipt

    func effect(of callEventID: String) async throws -> OperationEffect?

    func verifications(of callEventID: String) async throws -> [OperationVerification]

    func redactions(of eventID: String) async throws -> [ValueRedaction]

    /// The parts of the call's end the archive refused and the call was concluded without: a call with
    /// any is incomplete evidence.
    func recordingGaps(of callEventID: String) async throws -> [OperationRecordingGap]

    func attribution(of callEventID: String) async throws -> TaskCallAttribution?

    /// The route a routing session dispatched the call on, with a hand-back's reason (M05); nil when none was
    /// recorded.
    func route(of callEventID: String) async throws -> CallRoute?

    /// The rung the MacDriver's last gesture of the call took, with what it did and why rung 1 was passed over (M05);
    /// nil when the call sent no gesture of the MacDriver's, or none was recorded.
    func rung(of callEventID: String) async throws -> CallRung?

    /// The router's decision an `open_session` answered with its words, use or ask instead of opening, or open with a
    /// note (M05); nil when none was recorded.
    func advice(of callEventID: String) async throws -> CallRouteAdvice?

    /// The adapter verb the call invoked (M05), its invocation and not its success; nil when it invoked none.
    func adapterDispatch(of callEventID: String) async throws -> AdapterDispatch?


    /// The leaves of the call's structured result the record kept or withheld (P2-02), in pointer order.
    func resultFields(of callEventID: String) async throws -> [StructuredField]

    /// The leaves of the call's structured arguments, each a constant or a reference the archive decided (P2-02).
    func argumentFields(of callEventID: String) async throws -> [CallArgumentField]


    /// The data context the call attested (P2-05), its account as a minimal identifier; nil when none was recorded.
    func dataContext(of callEventID: String) async throws -> StoredDataContext?

    /// Appends a reconciliation of an earlier call (P2-06) at its next sequence; the call's end is never rewritten.
    func reconcile(_ reconciliation: CallReconciliation) async throws -> MemoryReceipt

    func reconciliations(of callEventID: String) async throws -> [CallReconciliation]

    /// The calls of a producer's stream whose effect is unknown and unresolved (P2-06): started and never ended under
    /// another executor than `executorID`, or concluded with an uncertain effect, with no fact resolving them since.
    func unresolvedCalls(source: MemoryEventSource, streamID: String, excludingExecutor executorID: String?)
        async throws -> [UnresolvedCall]

    /// The started calls that never ended under an executor other than `executorID`, with that executor (P2-06).
    func startedCalls(excludingExecutor executorID: String) async throws -> [(eventID: String, executorID: String)]
}

/// StoredDataContext is a call's data context as the archive keeps it (P2-05): the account only as its minimal identifier.
public struct StoredDataContext: Sendable, Equatable {
    public let service: String
    public let route: CallDataContext.Route
    public let profile: String?
    public let accountRef: String?
    public let accountSource: CallDataContext.AccountSource
    public let resourceKind: String?
    public let resource: String?

    public init(service: String, route: CallDataContext.Route, profile: String?, accountRef: String?,
                accountSource: CallDataContext.AccountSource, resourceKind: String?, resource: String?) {
        self.service       = service
        self.route         = route
        self.profile       = profile
        self.accountRef    = accountRef
        self.accountSource = accountSource
        self.resourceKind  = resourceKind
        self.resource      = resource
    }
}
