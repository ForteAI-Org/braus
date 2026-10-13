//
//  VariantPrefixTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import Testing

/// A variant's common prefix is the same structure only when the two versions' parameters correspond one
/// to one across it, in arguments and templates alike, with the same contract (review F04b): a renamed
/// parameter is the same parameter; one shared by two steps against two independent ones, or the
/// reverse, is not shown the same and leaves the prefix suggested; a parameter of another type is another
/// operation.
@Suite("A variant's prefix keeps its parameters' correspondence")
struct VariantPrefixTests {

    /// What a step types: a parameter, or a template of literal and parameter segments.
    enum Typed {
        case parameter(String)
        case template([TemplateSegment])
    }

    static func parameter(_ id: String, type: ParameterValueType = .text, direction: ParameterDirection = .input,
                          required: Bool = true) -> RouteParameter {
        RouteParameter(parameterID: id, name: id, direction: direction, valueType: type, isRequired: required)
    }

    static func step(_ position: Int, _ typed: Typed) -> ProcedureStep {
        let value: OperationValue = switch typed {
            case .parameter(let id): .parameter(id)
            case .template(let segments): .template(segments)
        }
        return ProcedureStep(stepID: "step-\(position)", position: position, goalText: "Enter text", bundleID: "com.example.Review",
                             operations: [StepOperation(operationID: "op-\(position)", position: 0, tool: .typeText, arguments: [
                                OperationArgument(name: "target", position: 0, value: .literal(.text("Field \(position)"))),
                                OperationArgument(name: "text", position: 0, value: value),
                                OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true))),
                             ])])
    }

    static func definition(_ id: String, _ parameters: [RouteParameter], _ typed: [Typed]) -> RouteDefinition {
        RouteDefinition(routeID: id, name: id, createdAtMS: 1, parameters: parameters,
                        steps: typed.enumerated().map { step($0.offset, $0.element) })
    }

    static func check(_ variant: RouteDefinition, _ original: RouteDefinition, details: [ParameterDetail] = [],
                      originalDetails: [ParameterDetail] = []) throws -> VariantPrefix.Check {
        try VariantPrefix.check(variant: variant, of: original, divergence: original.steps.count, variantDetails: details,
                                originalDetails: originalDetails)
    }

    static let correspondence = VariantPrefix.Check(status: .suggested, comparedSteps: 2, reason: .parameterCorrespondence)

    @Test("a parameter renamed is the same parameter, used once or in every step it was used in")
    func renamed() throws {
        let shared = Self.definition("o", [Self.parameter("file")], [.parameter("file"), .parameter("file")])
        let renamed = Self.definition("v", [Self.parameter("document")], [.parameter("document"), .parameter("document")])
        #expect(try Self.check(renamed, shared) == VariantPrefix.Check(status: .verified, comparedSteps: 2, reason: nil))
        let two = Self.definition("o", [Self.parameter("a"), Self.parameter("b")], [.parameter("a"), .parameter("b")])
        let twoRenamed = Self.definition("v", [Self.parameter("y"), Self.parameter("x")], [.parameter("x"), .parameter("y")])
        #expect(try Self.check(twoRenamed, two).status == .verified, "the declaration order of parameters is no part of it")
    }

    @Test("one parameter shared by two steps is not two independent ones, nor the reverse, nor a correspondence that crosses")
    func splitMergedCrossed() throws {
        let shared = Self.definition("o", [Self.parameter("file")], [.parameter("file"), .parameter("file")])
        let split = Self.definition("v", [Self.parameter("input"), Self.parameter("output")], [.parameter("input"), .parameter("output")])
        #expect(try Self.check(split, shared) == Self.correspondence)
        #expect(try Self.check(shared, split) == Self.correspondence, "two independent inputs merged into one")
        let original = Self.definition("o", [Self.parameter("a"), Self.parameter("b")], [.parameter("a"), .parameter("b"), .parameter("a")])
        let crossed = Self.definition("v", [Self.parameter("x"), Self.parameter("y")], [.parameter("x"), .parameter("y"), .parameter("y")])
        #expect(try VariantPrefix.check(variant: crossed, of: original, divergence: 3).reason == .parameterCorrespondence)
        #expect(try VariantPrefix.check(variant: crossed, of: original, divergence: 2).status == .verified,
                "a prefix that stops before the crossing step is the same")
    }

    @Test("templates share the correspondence of the whole prefix: a repeated segment keeps its parameter, and a template agrees with a plain use")
    func templates() throws {
        let name: (String) -> TemplateSegment = { .parameter($0) }
        let original = Self.definition("o", [Self.parameter("name"), Self.parameter("extension")], [
            .template([name("name"), .literal("."), name("extension")]),
            .template([name("name"), .literal("_copy."), name("extension")]),
        ])
        let renamed = Self.definition("v", [Self.parameter("base"), Self.parameter("suffix")], [
            .template([name("base"), .literal("."), name("suffix")]),
            .template([name("base"), .literal("_copy."), name("suffix")]),
        ])
        #expect(try Self.check(renamed, original).status == .verified)
        let split = Self.definition("v", [Self.parameter("base"), Self.parameter("other"), Self.parameter("suffix")], [
            .template([name("base"), .literal("."), name("suffix")]),
            .template([name("other"), .literal("_copy."), name("suffix")]),
        ])
        #expect(try Self.check(split, original) == Self.correspondence)
        let plainThenTemplate = Self.definition("o", [Self.parameter("file")], [.parameter("file"), .template([name("file"), .literal(".bak")])])
        let independent = Self.definition("v", [Self.parameter("input"), Self.parameter("output")],
                                          [.parameter("input"), .template([name("output"), .literal(".bak")])])
        #expect(try Self.check(independent, plainThenTemplate) == Self.correspondence)
    }

    @Test("a parameter whose contract differs is not shown the same: direction, whether required, kind, unit, sensitivity; another type is another operation")
    func contract() throws {
        let original = Self.definition("o", [Self.parameter("file")], [.parameter("file"), .parameter("file")])
        let output = Self.definition("v", [Self.parameter("file", direction: .output)], [.parameter("file"), .parameter("file")])
        #expect(try Self.check(output, original) == Self.correspondence)
        let optional = Self.definition("v", [Self.parameter("file", required: false)], [.parameter("file"), .parameter("file")])
        #expect(try Self.check(optional, original) == Self.correspondence)
        func detail(_ kind: TaskValueKind = .text, unit: String? = nil, _ sensitivity: TaskValueSensitivity = .ordinary) -> ParameterDetail {
            ParameterDetail(parameterID: "file", role: "any wording of the role", kind: kind, unit: unit, sensitivity: sensitivity,
                            producedByPartID: nil)
        }
        #expect(try Self.check(original, original, details: [detail()], originalDetails: [detail()]).status == .verified)
        let other = ParameterDetail(parameterID: "file", role: "another wording", kind: .text, unit: nil, sensitivity: .ordinary,
                                    producedByPartID: nil)
        #expect(try Self.check(original, original, details: [other], originalDetails: [detail()]).status == .verified,
                "the free description of a role is not compared")
        for (mine, theirs) in [(detail(.file), detail()), (detail(unit: "px"), detail(unit: "pt")), (detail(.text, .secret), detail())] {
            #expect(try Self.check(original, original, details: [mine], originalDetails: [theirs]) == Self.correspondence)
        }
        let number = Self.definition("v", [Self.parameter("file", type: .integer)], [.parameter("file"), .parameter("file")])
        #expect(throws: ProcedureError.self) { try Self.check(number, original) }
    }
}
