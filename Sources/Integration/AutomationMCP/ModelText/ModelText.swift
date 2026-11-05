import Foundation
import Memory
import AutomationRuntime

/// ModelText owns the fixed, ordered language delivered to the model.
public nonisolated enum ModelText {
    public enum Delivery: Sendable, Hashable {
        case systemPrompt(order: Int)
        case mcpInstructions(AutomationTools.MCPInstructionsForm)
        case toolDescription(tool: String)
        case seatLine
        case toolAnswer(tool: String)
        case refusal(tool: String)
        case legend
        case summary
    }

    public struct Key: Hashable, Sendable, RawRepresentable {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public struct Entry: Sendable {
        public let key: Key
        public let owner: String
        public let delivery: Delivery
        public let budgetCharacters: Int
        public let text: String
        public let legacy: Bool

        public init(
            key: Key,
            owner: String,
            delivery: Delivery,
            budgetCharacters: Int,
            text: String,
            legacy: Bool
        ) {
            self.key = key
            self.owner = owner
            self.delivery = delivery
            self.budgetCharacters = budgetCharacters
            self.text = text
            self.legacy = legacy
        }
    }

    public static var catalogue: [Entry] {
        return allCatalogue.filter { entry in
            guard !entry.key.rawValue.contains("memory_task"), !entry.text.contains("memory_task") else { return false }
            switch entry.delivery {
            case .toolDescription(let tool), .toolAnswer(let tool), .refusal(let tool): return tool != "memory_task"
            default: return true
            }
        }
    }

    private static var allCatalogue: [Entry] {
        systemPromptTexts + toolDescriptionTexts + toolAnswerTexts + refusalTexts
            + mcpInstructionTexts + seatLineTexts + legendTexts + summaryTexts + outcomeTexts + capabilityTexts
            + serviceTexts + guideTexts + taskStateTexts + recallTexts + openingFailureTexts
    }

    private static let entries = Dictionary(uniqueKeysWithValues: allCatalogue.map { ($0.key, $0.text) })

    public static func text(_ key: Key) -> String {
        guard let text = entries[key] else { preconditionFailure("Unknown model text key: \(key.rawValue)") }
        return outcomeText(key, fallback: text)
    }

    /// Substitutes typed slots in one pass, so replacement text cannot introduce another slot.
    public static func render(_ key: Key, _ slots: [String: ModelTextSlot]) -> String {
        let source = text(key)
        let pattern = /\{([A-Za-z][A-Za-z0-9_]*)\}/
        var result = ""
        var cursor = source.startIndex
        for match in source.matches(of: pattern) {
            result += source[cursor..<match.range.lowerBound]
            guard let slot = slots[String(match.1)] else {
                preconditionFailure("Missing model text slot: \(match.1)")
            }
            switch slot {
            case .toolName(let name): result += name
            case .minimized(let text): result += text
            case .rowID(let row): result += row.rawValue
            case .rowVerdict(let verdict): result += verdict.rawValue
            case .count(let value), .revision(let value): result += String(value)
            }
            cursor = match.range.upperBound
        }
        result += source[cursor...]
        return result
    }
}

public nonisolated enum ModelTextSlot: Sendable {
    case toolName(String)
    /// Text admitted by the caller's minimization policy.
    case minimized(String)
    case count(Int)
    case revision(Int)
    case rowID(TodoRowID)
    case rowVerdict(TodoRevision.RowVerdict)
}
