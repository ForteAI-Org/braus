//
//  VariantPrefix.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

/// VariantPrefix checks the common prefix a variant declares against the version it varies, on the
/// generalized definitions and never on labels or positions alone: every step before the divergence must
/// be the same operation, on the same application, with the same tool and, argument by argument, the
/// same literal, the same anchor or menu path, or a parameter of the same type in the same place (a
/// template of the same shape). New values of a parameter leave a prefix the same; a click and a double
/// click, another target, another key are another operation, and the prefix is refused.
///
/// The parameters of the two definitions must correspond one to one across the whole prefix, in
/// arguments and templates alike, with the same contract (type, direction, whether required, and the
/// kind, unit and sensitivity their details state): a parameter renamed is the same parameter, while one
/// parameter of the origin used where the variant uses two (or two of the origin where the variant uses
/// one) binds the steps otherwise, a value shared where values are independent, and is not shown to be
/// the same structure. Names and the free description of a role are never compared.
///
/// A step whose comparison cannot be decided (a value withheld from the record on either side, a literal
/// on one side where the other has a parameter, parameters that do not correspond) leaves the prefix
/// suggested, never verified: the variant keeps the reference to its origin, and nothing of the origin's
/// qualification passes to it either way.
public enum VariantPrefix {

    /// Status is what the check proved.
    public enum Status: String, Sendable, Equatable, Hashable, CaseIterable {
        /// Every step of the prefix is the same generalized operation.
        case verified
        /// No step contradicts the prefix, and at least one could not be compared.
        case suggested
    }

    /// Unproven is why a prefix is only suggested.
    public enum Unproven: String, Sendable, Equatable, Hashable, CaseIterable {
        /// A value withheld from the record on either side.
        case withheldLiteral = "withheld_literal"
        /// A step whose arguments cannot be compared (a literal against a parameter, a step that is missing).
        case unreadableStep = "unreadable_step"
        /// A variant built before prefixes were checked.
        case declaredBeforeVerification = "declared_before_verification"
        /// Parameters that do not correspond one to one, with the same contract, across the prefix: one
        /// shared where the other side has two, or a contract that differs.
        case parameterCorrespondence = "parameter_correspondence"
    }

    /// Check is the result of a prefix that was not contradicted.
    public struct Check: Sendable, Equatable {
        public let status: Status
        public let comparedSteps: Int
        public let reason: Unproven?

        public init(status: Status, comparedSteps: Int, reason: Unproven?) {
            self.status        = status
            self.comparedSteps = comparedSteps
            self.reason        = reason
        }
    }

    /// Comparison is what two steps are to each other.
    enum Comparison: Equatable {
        case same
        case different(String)
        case undecided(Unproven)
    }

    /// Correspondence is the one-to-one match between the variant's parameters and its origin's that the
    /// prefix has shown so far, with each side's contract.
    struct Correspondence {
        let variant: RouteDefinition
        let original: RouteDefinition
        let variantDetails: [String: ParameterDetail]
        let originalDetails: [String: ParameterDetail]
        private var forward: [String: String] = [:]
        private var backward: [String: String] = [:]

        init(variant: RouteDefinition, original: RouteDefinition, variantDetails: [ParameterDetail],
             originalDetails: [ParameterDetail]) {
            self.variant         = variant
            self.original        = original
            self.variantDetails  = Dictionary(variantDetails.map { ($0.parameterID, $0) }, uniquingKeysWith: { first, _ in first })
            self.originalDetails = Dictionary(originalDetails.map { ($0.parameterID, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// What a parameter of the variant is to a parameter of the origin in the same place: another type
        /// is another operation; one matched before to another parameter, or a contract that differs, is
        /// not shown the same; otherwise they correspond, from now on for the whole prefix.
        mutating func compare(_ id: String, _ originalID: String) -> Comparison {
            guard let mine = variant.parameters.first(where: { $0.parameterID == id }),
                  let theirs = original.parameters.first(where: { $0.parameterID == originalID }) else {
                return .undecided(.unreadableStep)
            }
            guard mine.valueType == theirs.valueType else { return .different("a parameter of another type") }
            switch (forward[id], backward[originalID]) {
                case (nil, nil):
                    forward[id] = originalID
                    backward[originalID] = id
                case (let matched?, let matchedBack?) where matched == originalID && matchedBack == id:
                    break
                default:
                    return .undecided(.parameterCorrespondence)
            }
            guard mine.direction == theirs.direction, mine.isRequired == theirs.isRequired else {
                return .undecided(.parameterCorrespondence)
            }
            if let detail = variantDetails[id], let other = originalDetails[originalID],
               detail.kind != other.kind || !EventFactText.same(detail.unit, other.unit) || detail.sensitivity != other.sensitivity {
                return .undecided(.parameterCorrespondence)
            }
            return .same
        }
    }

    /// Checks the steps before `divergence` of a variant against the version it varies, or throws the
    /// first step that contradicts the prefix. The details of either side's parameters, when given, are
    /// part of their contracts.
    public static func check(variant: RouteDefinition, of original: RouteDefinition, divergence: Int,
                             variantDetails: [ParameterDetail] = [], originalDetails: [ParameterDetail] = []) throws -> Check {
        guard divergence <= original.steps.count, divergence <= variant.steps.count else {
            throw ProcedureError.unknownReference("divergence \(divergence + 1) beyond the steps of the variant or its origin")
        }
        var correspondence = Correspondence(variant: variant, original: original, variantDetails: variantDetails,
                                            originalDetails: originalDetails)
        var unproven: Unproven?
        for position in 0..<divergence {
            let comparison = compare(variant.steps[position], original.steps[position], &correspondence)
            switch comparison {
                case .same: continue
                case .different(let why): throw ProcedureError.contradictedPrefix(step: position, why: why)
                case .undecided(let reason): unproven = unproven ?? reason
            }
        }
        return Check(status: unproven == nil ? .verified : .suggested, comparedSteps: divergence, reason: unproven)
    }

    static func compare(_ step: ProcedureStep, _ other: ProcedureStep, _ correspondence: inout Correspondence) -> Comparison {
        guard EventFactText.same(step.bundleID, other.bundleID) else { return .different("another application") }
        guard step.operations.count == other.operations.count else { return .different("another number of operations") }
        var unproven: Unproven?
        for (operation, otherOperation) in zip(step.operations, other.operations) {
            guard operation.tool == otherOperation.tool else { return .different("\(operation.tool.rawValue), not \(otherOperation.tool.rawValue)") }
            let arguments = operation.arguments.sorted { ($0.name, $0.position) < ($1.name, $1.position) }
            let others = otherOperation.arguments.sorted { ($0.name, $0.position) < ($1.name, $1.position) }
            guard arguments.map({ "\($0.name)#\($0.position)" }) == others.map({ "\($0.name)#\($0.position)" }) else {
                return .different("other arguments")
            }
            for (argument, otherArgument) in zip(arguments, others) {
                switch compare(argument.value, otherArgument.value, &correspondence) {
                    case .same: continue
                    case .different(let why): return .different("\(argument.name): \(why)")
                    case .undecided(let reason): unproven = unproven ?? reason
                }
            }
        }
        return unproven.map(Comparison.undecided) ?? .same
    }

    static func compare(_ value: OperationValue, _ other: OperationValue, _ correspondence: inout Correspondence) -> Comparison {
        switch (value, other) {
            case (.literal(let a), .literal(let b)):
                if case .text(let text) = a, text == ValueMinimization.marker { return .undecided(.withheldLiteral) }
                if case .text(let text) = b, text == ValueMinimization.marker { return .undecided(.withheldLiteral) }
                return a == b ? .same : .different("another value")
            case (.parameter(let a), .parameter(let b)):
                return correspondence.compare(a, b)
            case (.template(let a), .template(let b)):
                guard a.count == b.count else { return .different("a template of another shape") }
                var unproven: Unproven?
                for (segment, otherSegment) in zip(a, b) {
                    switch (segment, otherSegment) {
                        case (.literal(let x), .literal(let y)) where x == y: continue
                        case (.parameter(let x), .parameter(let y)):
                            switch correspondence.compare(x, y) {
                                case .same: continue
                                case .different: return .different("a template of another shape")
                                case .undecided(let reason): unproven = unproven ?? reason
                            }
                        default: return .different("a template of another shape")
                    }
                }
                return unproven.map(Comparison.undecided) ?? .same
            case (.anchor(let a), .anchor(let b)), (.menu(let a), .menu(let b)):
                return a == b ? .same : .different("another reference")
            case (.literal, .parameter), (.literal, .template), (.parameter, .literal), (.template, .literal):
                return .undecided(.unreadableStep)
            default:
                return .different("another kind of argument")
        }
    }
}
