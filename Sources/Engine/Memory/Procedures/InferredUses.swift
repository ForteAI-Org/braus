//
//  InferredUses.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import EngineCore
import Foundation

/// InferredUses completes an interpretation with the uses its calls show and it did not state: an argument recorded
/// with exactly the value of one of the task's inputs, or with the scene's mark of it, or with that value and a file
/// extension after it, reads that input. The agent states the uses it means; a value it typed or clicked without stating
/// it stayed a literal, so a reuse delivered the old value with no condition (D7, review R4, 14 October 2026: the file's
/// row `control|foto_3.png`, the name typed in a save panel, the width typed in a field).
///
/// What it reads is what the version's assembly then checks like any stated use: the value rendered from the input must
/// be what the call recorded, so an inferred use is never a mismatch. It reads only the arguments that carry a value,
/// the text typed, the item chosen, the value set, never one that names an element: a field or a command whose label is
/// the same text as a value keeps its role (a button Export and a file named Export), so a row clicked by a file's name
/// is still the agent's to state. It reads only inputs with a visible value (never a secret), only values long enough to
/// be the input's and not a coincidence (3 characters, or 2 digits), and only a value one input alone has. A parameter
/// the interpretation already states for that input is used; else one is added with the input's name, role and kind.
enum InferredUses {

    /// The arguments of each tool whose value may be one of the task's inputs: values, never elements.
    static let arguments: [AgentTool: Set<String>] = [
        .act: ["value"], .select: ["item"], .typeText: ["text"], .insertText: ["text"], .contextMenu: ["item"],
    ]

    static func completing(_ interpretation: ProcedureInterpretation, steps: [ProcedureAssembly.StepFacts],
                           taskInputs: [TaskValue]) throws -> ProcedureInterpretation {
        // The inputs a value may name: visible, long enough, and the only one with that value.
        let visible = taskInputs.compactMap { input -> (input: TaskValue, value: String)? in
            guard input.sensitivity != .secret, case .text(let value) = input.content else { return nil }
            let digits = value.allSatisfy(\.isNumber)
            guard value.count >= 3 || (digits && value.count >= 2) else { return nil }
            return (input, value)
        }
        let counts = Dictionary(grouping: visible, by: \.value).mapValues(\.count)
        let candidates = visible.filter { counts[$0.value] == 1 }
        guard !candidates.isEmpty else { return interpretation }

        var parameters = interpretation.parameters
        var uses = interpretation.uses
        let stated = Set(uses.map { "\($0.stepPosition)#\($0.argumentName)#\($0.argumentPosition)" })
        /// The parameter that reads an input: the one stated with its name, or with its value, else a new one.
        func parameter(for input: TaskValue, value: String) throws -> String? {
            if let named = parameters.first(where: { $0.name.utf8.elementsEqual(input.name.utf8) }) {
                return named.direction == .output ? nil : named.name
            }
            if let same = parameters.first(where: { parameter in
                guard parameter.direction != .output, case .text(let given)? = parameter.content else { return false }
                return given.utf8.elementsEqual(value.utf8)
            }) {
                return same.name
            }
            guard parameters.count < ProcedureInterpretationContract.maximumItems,
                  input.name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), !input.name.isEmpty else { return nil }
            let role = input.role.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? input.name
            parameters.append(try ParameterStatement(name: input.name, role: role, kind: input.kind == .missing ? .text : input.kind))
            return input.name
        }
        for step in steps {
            guard let names = arguments[step.request.tool] else { continue }
            for argument in step.request.arguments where names.contains(argument.name) {
                guard uses.count < ProcedureInterpretationContract.maximumItems else { break }
                let key = "\(step.position)#\(argument.name)#\(argument.position)"
                guard !stated.contains(key), !step.withheldArguments.contains("\(argument.name)#\(argument.position)"),
                      case .text(let recorded) = argument.value else { continue }
                // The first tier one input alone answers: the value itself, else the value and a file extension.
                let exact = candidates.filter { recorded.utf8.elementsEqual($0.value.utf8) }
                let extended = candidates.filter { Self.extensionAfter($0.value, in: recorded) != nil }
                let found: (input: TaskValue, value: String, suffix: String?)?
                if exact.count == 1 { found = (exact[0].input, exact[0].value, nil) }
                else if exact.isEmpty, extended.count == 1 {
                    found = (extended[0].input, extended[0].value, Self.extensionAfter(extended[0].value, in: recorded))
                } else { found = nil }
                guard let found, let name = try parameter(for: found.input, value: found.value) else { continue }
                let pieces: [UsePiece] = [.parameter(name)] + (found.suffix.map { [.literal($0)] } ?? [])
                uses.append(try UseStatement(stepPosition: step.position, argumentName: argument.name,
                                             argumentPosition: argument.position, pieces: pieces))
            }
        }
        guard uses.count != interpretation.uses.count else { return interpretation }
        return try ProcedureInterpretation(candidateID: interpretation.candidateID, revision: interpretation.revision,
                                           parts: interpretation.parts, parameters: parameters, uses: uses,
                                           variantOf: interpretation.variantOf, divergencePosition: interpretation.divergencePosition)
    }

    /// The file extension `recorded` adds after `value` (".jpg" for "foto_mail" in "foto_mail.jpg"), or nil.
    static func extensionAfter(_ value: String, in recorded: String) -> String? {
        guard recorded.count > value.count, recorded.hasPrefix(value) else { return nil }
        let rest = recorded.dropFirst(value.count)
        guard rest.first == ".", rest.count >= 2, rest.count <= 6, rest.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return String(rest)
    }
}
