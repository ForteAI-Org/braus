//
//  ProcedureReading.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

/// InterpretationOutcome is what recording an interpretation did: whether it was new or the stored one
/// again, the revision it holds, the version it built, the uses the calls did not confirm, and the
/// qualification of every part of the version.
public struct InterpretationOutcome: Sendable {
    public let receipt: MemoryReceipt
    public let revision: Int
    public let routeID: String
    public let findings: [InterpretationFinding]
    public let qualifications: [PartQualification]

    public init(receipt: MemoryReceipt, revision: Int, routeID: String, findings: [InterpretationFinding],
                qualifications: [PartQualification]) {
        self.receipt        = receipt
        self.revision       = revision
        self.routeID        = routeID
        self.findings       = findings
        self.qualifications = qualifications
    }
}

/// StoredProcedureVersion is a version read back whole: the version as built, where the attempt stood
/// when it was interpreted, the contract of each part, each part's current qualification under the
/// policy in force and its latest operational state, and whether a later version superseded it.
public struct StoredProcedureVersion: Sendable {
    public let version: ProcedureVersion
    public let interpretationState: InterpretationState
    public let contract: [PartContractItem]
    /// The latest evaluation of each part, by part id.
    public let qualifications: [String: PartQualification]
    /// The latest operational state of each part that has one, by part id.
    public let states: [String: PartOperationalState]
    public let isCurrent: Bool
    /// For a variant, what the check of its declared common prefix proved; nil for a version that varies none.
    public let variantPrefix: VariantPrefix.Check?
    /// The state a part's first step started from, by part id, for a part whose contract states it unknown
    /// because the step's sample was not placed in a state when the version was built and has been since
    /// (a late association): the contract stays as built, this says what is known now and why.
    public let lateEntryStates: [String: String]

    public init(version: ProcedureVersion, interpretationState: InterpretationState, contract: [PartContractItem],
                qualifications: [String: PartQualification], states: [String: PartOperationalState], isCurrent: Bool,
                variantPrefix: VariantPrefix.Check? = nil, lateEntryStates: [String: String] = [:]) {
        self.version             = version
        self.interpretationState = interpretationState
        self.contract            = contract
        self.qualifications      = qualifications
        self.states              = states
        self.isCurrent           = isCurrent
        self.variantPrefix       = variantPrefix
        self.lateEntryStates     = lateEntryStates
    }
}

/// CataloguePart is one part of the operational catalogue, as a later reader (the Recall's index)
/// takes it from the authoritative store: a part of a version no later version superseded, whose
/// latest qualification under a policy in force admits it and whose state does not keep it out. It
/// carries its own label, interval, application, contract, the parameters it reads and produces with
/// their roles, the source it was learned from and the evidence it rests on, so an index can be rebuilt
/// from these rows alone, without repeating any task.
public struct CataloguePart: Sendable {

    /// Parameter is one parameter the part reads or produces: its id and name, direction and type, the
    /// role, base kind and unit the agent gave, whether it is a secret.
    public struct Parameter: Sendable {
        public let parameter: RouteParameter
        public let detail: ParameterDetail

        public init(parameter: RouteParameter, detail: ParameterDetail) {
            self.parameter = parameter
            self.detail    = detail
        }
    }

    public let part: ProcedurePart
    public let procedureLabel: String
    public let candidateID: String
    public let taskID: String
    public let attemptID: String
    public let revision: Int
    public let contract: [PartContractItem]
    public let parameters: [Parameter]
    public let qualification: PartQualification
    public let state: PartOperationalState?
    /// The entry state the contract states unknown, known since by a late association, or nil.
    public let lateEntryState: String?

    public init(part: ProcedurePart, procedureLabel: String, candidateID: String, taskID: String, attemptID: String, revision: Int,
                contract: [PartContractItem], parameters: [Parameter], qualification: PartQualification,
                state: PartOperationalState?, lateEntryState: String? = nil) {
        self.part           = part
        self.procedureLabel = procedureLabel
        self.candidateID    = candidateID
        self.taskID         = taskID
        self.attemptID      = attemptID
        self.revision       = revision
        self.contract       = contract
        self.parameters     = parameters
        self.qualification  = qualification
        self.state          = state
        self.lateEntryState = lateEntryState
    }
}

/// ProcedureCatalogueCursor pages the catalogue by part id, as bytes: the next page starts after it.
public struct ProcedureCatalogueCursor: Sendable, Equatable {
    public let afterPartID: String

    public init(afterPartID: String) {
        self.afterPartID = afterPartID
    }
}
