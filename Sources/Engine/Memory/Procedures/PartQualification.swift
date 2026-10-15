//
//  PartQualification.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore

/// PartQualification is the operational qualification A of one part under one version of the policy:
/// admitted, with the verifications it rests on, or refused, with every reason found. A says that the
/// part was declared completed, that its trace is complete, that the interpretation is coherent with
/// its calls and that every operation of it was positively verified within the method's scope. It does
/// not say that the user's goal was reached: closing an Export dialog is not a file on disk.
public struct PartQualification: Sendable, Equatable {

    /// Verdict is the policy's decision.
    public enum Verdict: String, Sendable, Equatable, Hashable, CaseIterable {
        case admitted, refused
    }

    /// Reason is one thing that keeps the part out of the operational catalogue.
    public enum Reason: String, Sendable, Equatable, Hashable, CaseIterable {
        case missingLabel            = "missing_label"
        case completionNotDeclared   = "completion_not_declared"
        case declaredFailed          = "declared_failed"
        case declaredLate            = "declared_late"
        case callIncomplete          = "call_incomplete"
        case callFailed              = "call_failed"
        case callCancelled           = "call_cancelled"
        case callInterrupted         = "call_interrupted"
        case recordingGap            = "recording_gap"
        case noVerification          = "no_verification"
        case verificationFailed      = "verification_failed"
        case verificationUnknown     = "verification_unknown"
        case verificationNotPositive = "verification_not_positive"
        case useMismatch             = "use_mismatch"
        case unverifiableUse         = "unverifiable_use"
        case missingInput            = "missing_input"
        case withheldLiteral         = "withheld_literal"
    }

    /// Finding is one reason, about the part or about one of its steps.
    public struct Finding: Sendable, Equatable, Hashable {
        public let reason: Reason
        public let stepPosition: Int?
        public let callEventID: String?

        public init(reason: Reason, stepPosition: Int? = nil, callEventID: String? = nil) {
            self.reason       = reason
            self.stepPosition = stepPosition
            self.callEventID  = callEventID
        }
    }

    /// Evidence is one verification the admission rests on.
    public struct Evidence: Sendable, Equatable, Hashable {
        public let stepPosition: Int
        public let callEventID: String
        public let verificationEventID: String

        public init(stepPosition: Int, callEventID: String, verificationEventID: String) {
            self.stepPosition        = stepPosition
            self.callEventID         = callEventID
            self.verificationEventID = verificationEventID
        }
    }

    public let partID: String
    public let policyVersion: String
    public let verdict: Verdict
    public let findings: [Finding]
    public let evidence: [Evidence]

    public init(partID: String, policyVersion: String, findings: [Finding], evidence: [Evidence]) {
        self.partID        = partID
        self.policyVersion = policyVersion
        self.verdict       = findings.isEmpty ? .admitted : .refused
        self.findings      = findings
        self.evidence      = findings.isEmpty ? evidence : []
    }

    /// Whether another evaluation decided exactly this: the same policy, verdict, reasons and evidence.
    public func decidesSame(as other: PartQualification) -> Bool {
        partID.utf8.elementsEqual(other.partID.utf8) && policyVersion.utf8.elementsEqual(other.policyVersion.utf8)
            && verdict == other.verdict && findings == other.findings && evidence == other.evidence
    }
}

/// QualificationPolicy is the rule that admits a part, a pure function of what the archive keeps about a
/// part: its label and declared outcome, the attempt's end and its result check, when the interpretation was
/// made, and for every step of it the call's state, its recording gaps, its verifications, the findings of
/// the interpretation, the bindings of the parameters it reads and the evidence an identical earlier run of
/// the same method gives it. A step part may still be admitted on its own, with its observed entry state as
/// its prerequisite.
///
/// **Version B (`qualification-b-1`, 14 October 2026).** A asked every operation of a part to be positively
/// verified on its own. On PhotoCraft 44% of the checks were unknown (a menu opening a remote panel, a field
/// that cannot be read back), so no procedure of nine was admitted and recall offered only loose steps,
/// though every output was right on disk. B keeps A's rule for steps and adds two kinds of evidence:
/// - the attempt's result check (`TaskResultCheck`): when Braus found on disk the file a completed task said it
///   produced, a procedure or subprocedure of it is not kept out by a step whose check is unknown or missing or
///   whose delivery was uncertain; another gesture than the one asked, a failed check, a call that did not
///   conclude still keep it out, and a result check that failed keeps it out whatever its steps say;
/// - an identical earlier run (`StepFacts.inherited`): a step whose own check is unknown is verified by the
///   positive check of the same step in the version this one repeats.
/// A version built since 14 October 2026 holds the method only (`ProcedureAssembly.leftOut`), so the retries A
/// refused a parent for are no part of it.
public enum QualificationPolicy {

    /// The version of the rule, kept with every evaluation.
    public static let version = "qualification-b-1"

    /// The conditions whose pass verifies the operation that was requested, within the method's scope:
    /// the state already present (no gesture), the state after the gesture, the value read back, a
    /// structural effect attributed to the gesture, a submenu opened, the window set changed by a menu
    /// command or a dialog button, the contextual item chosen. A pop-up that closed after a choice, a
    /// recovery gesture instead of the request, and a path with no oracle verify no requested operation.
    public static let positiveConditions: Set<OperationCheck.Condition> = [
        .requestedStateAlreadyPresent, .stateAfterGesture, .valueReadBack, .structuralEffect, .submenuOpened,
        .windowSetChanged, .menuItemChosen,
    ]

    /// VerificationFact is what the policy reads of one verification of a step's call.
    public struct VerificationFact: Sendable, Equatable {
        public let eventID: String
        public let condition: OperationCheck.Condition
        public let verdict: OperationCheck.Verdict
        public let performed: OperationCheck.Performed
        public let limits: [OperationCheck.Limit]

        public init(eventID: String, condition: OperationCheck.Condition, verdict: OperationCheck.Verdict,
                    performed: OperationCheck.Performed, limits: [OperationCheck.Limit]) {
            self.eventID   = eventID
            self.condition = condition
            self.verdict   = verdict
            self.performed = performed
            self.limits    = limits
        }

        /// Whether the verification positively verified the requested operation.
        public var isPositive: Bool {
            guard verdict == .passed, QualificationPolicy.positiveConditions.contains(condition) else { return false }
            guard !limits.contains(.deliveryUncertain) else { return false }
            switch performed {
                case .requested: return true
                case .none: return condition == .requestedStateAlreadyPresent
                case .substitute, .uncertain: return false
            }
        }
    }

    /// StepFacts is what the policy reads of one step of the part.
    public struct StepFacts: Sendable, Equatable {
        public let position: Int
        public let callEventID: String
        public let status: AgentCallStatus
        public let hasRecordingGap: Bool
        public let verifications: [VerificationFact]
        public let findings: [InterpretationFinding.Kind]
        public let keepsWithheldLiteral: Bool
        /// The parameters the step reads whose binding in the attempt is missing.
        public let missingInputs: [String]
        /// The positive check of the same step in the identical version this one repeats, when the step's own
        /// check is not positive: the call and verification of that earlier run.
        public let inherited: (callEventID: String, verificationEventID: String)?

        public init(position: Int, callEventID: String, status: AgentCallStatus, hasRecordingGap: Bool,
                    verifications: [VerificationFact], findings: [InterpretationFinding.Kind] = [],
                    keepsWithheldLiteral: Bool = false, missingInputs: [String] = [],
                    inherited: (callEventID: String, verificationEventID: String)? = nil) {
            self.position             = position
            self.callEventID          = callEventID
            self.status               = status
            self.hasRecordingGap      = hasRecordingGap
            self.verifications        = verifications
            self.findings             = findings
            self.keepsWithheldLiteral = keepsWithheldLiteral
            self.missingInputs        = missingInputs
            self.inherited            = inherited
        }

        public static func == (lhs: StepFacts, rhs: StepFacts) -> Bool {
            lhs.position == rhs.position && lhs.callEventID == rhs.callEventID && lhs.status == rhs.status
                && lhs.hasRecordingGap == rhs.hasRecordingGap && lhs.verifications == rhs.verifications
                && lhs.findings == rhs.findings && lhs.keepsWithheldLiteral == rhs.keepsWithheldLiteral
                && lhs.missingInputs == rhs.missingInputs && lhs.inherited?.callEventID == rhs.inherited?.callEventID
                && lhs.inherited?.verificationEventID == rhs.inherited?.verificationEventID
        }

        /// Whether the step's own checks leave its operation unproven without contradicting it: unknown or
        /// missing, or a gesture whose delivery was uncertain, never a failed check and never another gesture than the
        /// one asked. An uncertain delivery is unproven, not refuted: PhotoCraft answers a double click on a folder of
        /// its save panel with an error and opens the folder (14 October 2026).
        var isOnlyUnproven: Bool {
            guard status == .completed, !hasRecordingGap else { return false }
            return verifications.allSatisfy { fact in
                fact.verdict != .failed && fact.performed != .substitute && fact.condition != .recoveryInsteadOfRequest
                    && (fact.verdict == .unknown || fact.isPositive || fact.performed == .uncertain
                        || fact.limits.contains(.deliveryUncertain))
            }
        }
    }

    /// PartFacts is what the policy reads of the part itself.
    public struct PartFacts: Sendable, Equatable {
        public let part: ProcedurePart
        public let attemptEnd: DeclaredTaskStatus?
        public let interpretationState: InterpretationState
        /// The effective outcome of the part that contains this one (nil for the procedure).
        public let parentOutcome: DeclaredPartOutcome?
        /// The steps the part covers, in order.
        public let steps: [StepFacts]
        /// The attempt's result check, when its end named a result Braus could check (`TaskResultCheck`).
        public let result: VerificationVerdict?

        public init(part: ProcedurePart, attemptEnd: DeclaredTaskStatus?, interpretationState: InterpretationState,
                    parentOutcome: DeclaredPartOutcome? = nil, steps: [StepFacts], result: VerificationVerdict? = nil) {
            self.part                = part
            self.attemptEnd          = attemptEnd
            self.interpretationState = interpretationState
            self.parentOutcome       = parentOutcome
            self.steps               = steps
            self.result              = result
        }
    }

    /// The outcome a part is taken to declare: the one the agent stated for it; else, for the procedure,
    /// the one the attempt's end declared (completed, failed, or abandoned as not completed), and for any
    /// other part, completed when the part containing it is taken to be completed. A completion is never
    /// taken from a failed or undeclared parent, and a stated outcome is never overridden.
    public static func effectiveOutcome(of part: ProcedurePart, parent: DeclaredPartOutcome?,
                                        attemptEnd: DeclaredTaskStatus?) -> DeclaredPartOutcome {
        guard part.declaredOutcome == .notDeclared else { return part.declaredOutcome }
        if part.kind == .procedure {
            return switch attemptEnd {
                case .completed?: .completed
                case .failed?: .failed
                case .abandoned?: .notCompleted
                default: .notDeclared
            }
        }
        return parent == .completed ? .completed : .notDeclared
    }

    /// The qualification of a part: every reason found, in a fixed order (the part's, then each step's in
    /// order), or the admission with one verification per step.
    public static func evaluate(_ facts: PartFacts) -> PartQualification {
        var findings: [PartQualification.Finding] = []
        var evidence: [PartQualification.Evidence] = []
        func add(_ reason: PartQualification.Reason, _ step: StepFacts? = nil) {
            let finding = PartQualification.Finding(reason: reason, stepPosition: step?.position, callEventID: step?.callEventID)
            if !findings.contains(finding) { findings.append(finding) }
        }
        let part = facts.part
        if part.label == nil { add(.missingLabel) }
        switch effectiveOutcome(of: part, parent: facts.parentOutcome, attemptEnd: facts.attemptEnd) {
            case .completed:
                if facts.interpretationState == .interrupted { add(.declaredLate) }
                if part.kind == .procedure {
                    switch facts.attemptEnd {
                        case .completed?: break
                        case .failed?: add(.declaredFailed)
                        default: add(.completionNotDeclared)
                    }
                }
            case .failed:
                add(.declaredFailed)
            case .notCompleted, .notDeclared:
                add(.completionNotDeclared)
        }
        // A procedure or a subprocedure of a completed attempt whose result Braus found on disk is not kept out by a
        // step that is only unproven; a result that failed keeps it out (version B).
        let isMethod = part.kind != .step
        let resultProves = isMethod && facts.result == .passed
        if isMethod, facts.result == .failed { add(.verificationFailed) }
        for step in facts.steps {
            // A step only unproven by its own check and proven by an identical earlier run counts as verified.
            if let inherited = step.inherited, step.isOnlyUnproven, !step.verifications.contains(where: \.isPositive) {
                for finding in step.findings { add(finding == .useMismatch ? .useMismatch : .unverifiableUse, step) }
                if step.keepsWithheldLiteral { add(.withheldLiteral, step) }
                if !step.missingInputs.isEmpty { add(.missingInput, step) }
                evidence.append(PartQualification.Evidence(stepPosition: step.position, callEventID: inherited.callEventID,
                                                          verificationEventID: inherited.verificationEventID))
                continue
            }
            if resultProves, step.isOnlyUnproven {
                for finding in step.findings { add(finding == .useMismatch ? .useMismatch : .unverifiableUse, step) }
                if step.keepsWithheldLiteral { add(.withheldLiteral, step) }
                if !step.missingInputs.isEmpty { add(.missingInput, step) }
                if let positive = step.verifications.first(where: \.isPositive), step.verifications.allSatisfy(\.isPositive) {
                    evidence.append(PartQualification.Evidence(stepPosition: step.position, callEventID: step.callEventID,
                                                              verificationEventID: positive.eventID))
                }
                continue
            }
            switch step.status {
                case .completed: break
                case .started: add(.callIncomplete, step)
                case .failed: add(.callFailed, step)
                case .cancelled: add(.callCancelled, step)
                case .interrupted: add(.callInterrupted, step)
                case .planned, .skipped: add(.callIncomplete, step)
            }
            if step.hasRecordingGap { add(.recordingGap, step) }
            if step.verifications.isEmpty, !step.hasRecordingGap { add(.noVerification, step) }
            if step.verifications.contains(where: { $0.verdict == .failed }) { add(.verificationFailed, step) }
            if step.verifications.contains(where: { $0.verdict == .unknown }) { add(.verificationUnknown, step) }
            if step.verifications.contains(where: { $0.verdict == .passed && !$0.isPositive }) { add(.verificationNotPositive, step) }
            for finding in step.findings {
                add(finding == .useMismatch ? .useMismatch : .unverifiableUse, step)
            }
            if step.keepsWithheldLiteral { add(.withheldLiteral, step) }
            if !step.missingInputs.isEmpty { add(.missingInput, step) }
            if let positive = step.verifications.first(where: \.isPositive), step.verifications.allSatisfy(\.isPositive) {
                evidence.append(PartQualification.Evidence(stepPosition: step.position, callEventID: step.callEventID,
                                                          verificationEventID: positive.eventID))
            }
        }
        return PartQualification(partID: part.partID, policyVersion: version, findings: findings, evidence: evidence)
    }
}

/// PartOperationalState is a part's standing in use, appended over time: usable, to be evaluated again,
/// or retired for good, with the reason and who recorded it. No state means the qualification alone
/// decides; a retired part stays in the archive with its history and is never offered again.
public enum PartOperationalState: String, Sendable, Equatable, Hashable, CaseIterable {
    case usable
    case toReevaluate = "to_reevaluate"
    case retired
}
