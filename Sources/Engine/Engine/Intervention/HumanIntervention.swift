import Foundation

/// HumanIntervention owns the temporary history of one human intervention, independently of input
/// delivery, perception, providers and persistent memory. Producers record immutable input/frame
/// payloads while one consumer reconstructs them. All mutations are serialized by this actor.
///
/// Record before forwarding an input request. A refused record must not be forwarded: doing so
/// would leave an unrecorded action in the application. Payloads remain retained until resolution
/// or explicit closure. The caller supplies a conservative byte charge, including retained frames;
/// this accounts payloads, not total process memory or the size of reconstruction findings.
///
/// This is a lifecycle primitive, not Driver authority. The composition must connect it to agent
/// suspension and common input guards. A new instance is required after resume or task completion.
public actor HumanIntervention<Payload: Sendable, Finding: Sendable> {

    public enum Phase: Sendable, Equatable {
        case observing
        case collecting
        case reconstructing
        case evaluating
        case awaitingClarification
        case resumed
        case taskCompleted
        case blocked
        case closed
    }

    public enum Resolution: Sendable {
        case resume
        case taskCompleted
        case needsClarification
    }

    public enum Failure: Error, Sendable, Equatable {
        case invalidLimit
        case invalidCost
        case capacityExceeded
        case invalidPhase
        case invalidWorkItem
        case staleRevision
        case analysisPending
    }

    /// Revision identifies one boundary in one intervention. It is a correlation token, not an
    /// input permission. New input or activity invalidates both reconstruction and review results.
    public struct Revision: Sendable, Equatable {
        fileprivate let owner: UUID
        fileprivate let value: UUID
    }

    /// WorkItem leases one original event to the consumer. The payload must describe the frame
    /// shown at production time, rather than a mutable reference to the latest preview image.
    public struct WorkItem: Sendable {
        public let sequence: UInt64
        public let payload: Payload
        fileprivate let owner: UUID
    }

    /// Review contains ordered findings and the explicitly observed final state. The composition
    /// renders a compact factual handoff from these values; raw payloads are not included here.
    public struct Review: Sendable {
        public let revision: Revision
        public let findings: [Finding]
        public let finalState: Finding
    }

    /// Status describes this intervention only. allowsAgentInput does not override other causes of
    /// suspension, authorize an input, or prove that a previously planned action is still valid.
    public struct Status: Sendable {
        public let phase: Phase
        public let recordedCount: Int
        public let analyzedCount: Int
        public let retainedBytes: Int

        public var allowsAgentInput: Bool {
            phase == .observing || phase == .resumed
        }
    }

    private let owner = UUID()
    private let maximumEvents: Int
    private let maximumRetainedBytes: Int
    private var version = UUID()
    private var phase: Phase = .observing
    private var payloads: [Payload] = []
    private var findings: [Finding] = []
    private var retainedBytes = 0
    private var inFlight: UInt64?

    public init(
        maximumEvents       : Int,
        maximumRetainedBytes: Int
    ) throws {
        guard maximumEvents > 0, maximumRetainedBytes > 0 else { throw Failure.invalidLimit }
        self.maximumEvents        = maximumEvents
        self.maximumRetainedBytes = maximumRetainedBytes
    }

    /// Records an input request without waiting for perception. Count and byte limits include
    /// already reconstructed history, because that history is retained for the current episode.
    /// Overflow preserves existing history and blocks the episode; no input is silently evicted.
    @discardableResult
    public func record(
        _ payload    : Payload,
        retainedBytes: Int
    ) throws -> UInt64 {
        switch phase {
            case .observing, .collecting, .reconstructing, .evaluating, .awaitingClarification:
                break
            case .resumed, .taskCompleted, .blocked, .closed:
                throw Failure.invalidPhase
        }
        guard retainedBytes >= 0 else { throw Failure.invalidCost }
        guard payloads.count < maximumEvents,
              retainedBytes <= maximumRetainedBytes - self.retainedBytes else {
            phase = .blocked
            version = UUID()
            throw Failure.capacityExceeded
        }
        payloads.append(payload)
        self.retainedBytes += retainedBytes
        phase = .collecting
        version = UUID()
        return UInt64(payloads.count)
    }

    /// Records relevant activity inside an existing intervention. Hover alone cannot start one.
    /// The UI decides which movements count; this core owns no inactivity timer or desktop reads.
    public func noteActivity() {
        switch phase {
            case .collecting, .reconstructing, .evaluating, .awaitingClarification:
                phase = .collecting
                version = UUID()
            case .observing, .resumed, .taskCompleted, .blocked, .closed:
                break
        }
    }

    /// Leases the next event in input order. A second consumer receives nil until the first item
    /// completes. A nil result says nothing about whether the human has finished intervening.
    public func next() -> WorkItem? {
        guard phase == .collecting || phase == .reconstructing,
              inFlight == nil, findings.count < payloads.count else { return nil }
        let sequence = UInt64(findings.count + 1)
        inFlight = sequence
        return WorkItem(
            sequence: sequence,
            payload : payloads[findings.count],
            owner   : owner
        )
    }

    /// Completes the leased event once. A finding can describe uncertainty or no observed effect;
    /// completing analysis does not establish that an input was delivered or achieved its purpose.
    public func complete(
        _ item      : WorkItem,
        with finding: Finding
    ) throws {
        try requireCurrent(item)
        findings.append(finding)
        inFlight = nil
    }

    /// Blocks the episode when the consumer cannot finish its leased work. The composition may
    /// inspect status and close explicitly; a partial sequence cannot become a successful review.
    public func fail(_ item: WorkItem) throws {
        try requireCurrent(item)
        inFlight = nil
        phase = .blocked
        version = UUID()
    }

    /// Marks the input boundary chosen by the caller's inactivity policy. Outstanding analysis can
    /// continue. The caller must wait for held gestures and capture a final state for this revision.
    public func endInput() throws -> Revision {
        guard phase == .collecting else { throw Failure.invalidPhase }
        phase = .reconstructing
        return revision
    }

    /// Starts agent evaluation only after ordered reconstruction and a final-state observation.
    /// The caller obtains finalState after endInput and passes the same revision back here; activity
    /// during that asynchronous observation makes this call refuse instead of presenting stale facts.
    public func beginReview(
        _ expected : Revision,
        finalState : Finding
    ) throws -> Review {
        try requireCurrent(expected)
        guard phase == .reconstructing else { throw Failure.invalidPhase }
        guard inFlight == nil, findings.count == payloads.count else { throw Failure.analysisPending }
        phase = .evaluating
        return Review(
            revision  : expected,
            findings  : findings,
            finalState: finalState
        )
    }

    /// Applies a decision about the reviewed version. Clarification keeps all input suspended.
    /// A decision after renewed human activity refuses; resume requires a new current review.
    public func resolve(
        _ expected   : Revision,
        as resolution: Resolution
    ) throws {
        try requireCurrent(expected)
        guard phase == .evaluating || phase == .awaitingClarification else { throw Failure.invalidPhase }
        switch resolution {
            case .needsClarification:
                phase = .awaitingClarification
            case .resume:
                releaseHistory()
                phase = .resumed
            case .taskCompleted:
                releaseHistory()
                phase = .taskCompleted
        }
    }

    /// Closes the intervention and releases owned storage without granting agent input. Work items
    /// or reviews retained by a caller have their own lifetime, but cannot mutate this closed actor.
    public func close() {
        releaseHistory()
        version = UUID()
        phase = .closed
    }

    public func status() -> Status {
        Status(
            phase        : phase,
            recordedCount: payloads.count,
            analyzedCount: findings.count,
            retainedBytes: retainedBytes
        )
    }

    private var revision: Revision {
        Revision(
            owner: owner,
            value: version
        )
    }

    private func requireCurrent(_ expected: Revision) throws {
        guard expected == revision else { throw Failure.staleRevision }
    }

    private func requireCurrent(_ item: WorkItem) throws {
        guard phase == .collecting || phase == .reconstructing,
              item.owner == owner, item.sequence == inFlight else { throw Failure.invalidWorkItem }
    }

    private func releaseHistory() {
        payloads.removeAll(keepingCapacity: false)
        findings.removeAll(keepingCapacity: false)
        retainedBytes = 0
        inFlight = nil
    }
}
