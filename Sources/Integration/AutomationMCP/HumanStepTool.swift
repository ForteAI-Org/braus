//
//  HumanStepTool.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import Foundation
import LocalMCP

/// HumanStepTool exposes bounded episode reads without adding them to the action archive.
enum HumanStepTool {
    static let name = "human_step"

    static var definition: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(ModelText.text(.init(rawValue: "tool.human_step.v1.description"))
                + ModelText.text(.init(rawValue: "human_step_tool.definition.v1"))),
            "inputSchema": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "steps": .object([
                        "type": .string("string"),
                        "pattern": .string("^[1-9][0-9]*(-[1-9][0-9]*)?$"),
                        "description": .string(ModelText.text(.init(rawValue: "human_step_tool.definition.v1.2")))
                    ]),
                    "diff": .object([
                        "oneOf": .array([
                            .object(["type": .string("string"), "pattern": .string("^§?[1-9][0-9]*$")]),
                            .object(["type": .string("integer"), "minimum": .number(1)])
                        ]),
                        "description": .string(ModelText.text(.init(rawValue: "human_step_tool.definition.v1.3")))
                    ]),
                    "picture": .object(["type": .string("integer"), "minimum": .number(1)])
                ]),
                "oneOf": .array(["steps", "diff", "picture"].map {
                    .object(["required": .array([.string($0)])])
                })
            ]),
            "annotations": .object(["readOnlyHint": .bool(true)])
        ])
    }

    static func request(_ arguments: JSONValue) throws -> HumanStepRequest {
        guard let fields = arguments.object, fields.count == 1 else { throw invalid }
        if let value = fields["steps"]?.string {
            let bounds = value.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let first = positiveInteger(String(bounds[0])),
                  let last = positiveInteger(String(bounds[bounds.count - 1])),
                  first <= last, last - first < 20 else { throw invalid }
            return .steps(first...last)
        }
        if let value = fields["diff"] {
            if let text = value.string {
                let number = text.hasPrefix("§") ? String(text.dropFirst()) : text
                guard positiveInteger(number) != nil else { throw invalid }
                return .diff(text)
            }
            guard let number = positiveInteger(value) else { throw invalid }
            return .diff(String(number))
        }
        if let value = fields["picture"], let number = positiveInteger(value) {
            return .picture(number)
        }
        throw invalid
    }

    static func result(
        _ result: HumanStepResult,
        withholding: (String) -> String
    ) -> JSONValue {
        let hasPicture = result.picture != nil && !result.isError
        let description = hasPicture ? result.text + ModelText.text(.init(rawValue: "human_step_tool.description.v1")) : result.text
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(withholding(description))])]
        if let picture = result.picture, !result.isError {
            content.append(.object([
                "type": .string("image"),
                "data": .string(picture.base64EncodedString()),
                "mimeType": .string("image/heic")
            ]))
        }
        return .object(["content": .array(content), "isError": .bool(result.isError)])
    }

    private static var invalid: AutomationFailure {
        AutomationFailure(ModelText.text(.init(rawValue: "tool.human_step.v1.refusal")))
    }

    private static func positiveInteger(_ text: String) -> Int? {
        guard text.first != "0", !text.isEmpty,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), number > 0 else { return nil }
        return number
    }

    private static func positiveInteger(_ value: JSONValue) -> Int? {
        guard case .number(let number) = value, let integer = Int(exactly: number), integer > 0 else { return nil }
        return integer
    }
}
