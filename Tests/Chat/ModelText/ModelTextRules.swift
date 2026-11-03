import AutomationRuntime
import Foundation
import LocalMCP
import Testing
@testable import AutomationMCP

struct RuleContext {
    var toolNames: Set<String> = ["observe", "open_session", "act", "status", "windows"]
    var visibleNames: Set<String> = ["expected_value", "set_toggle"]
    var channels: AutomationChannels = []
    var toolDefinitions: [JSONValue] = []
    var recovery = "observe"
    var hasAfterScene = false
    var requiresWindow = false
    var sentinels = ["fake-secret-value", "/tmp/private-document.txt", "person@example.invalid"]
}

struct Violation: Equatable {
    enum Code: String { case budget, name, value, contradiction, style }
    let key: ModelText.Key
    let code: Code
}

func validate(_ entries: [ModelText.Entry], context: RuleContext) -> [Violation] {
    var violations: [Violation] = []
    func matches(_ pattern: String, _ text: String) -> [String] {
        text.ranges(of: try! Regex(pattern)).map { String(text[$0]) }
    }
    func add(_ entry: ModelText.Entry, _ code: Violation.Code) {
        if !violations.contains(.init(key: entry.key, code: code)) {
            violations.append(.init(key: entry.key, code: code))
        }
    }
    let fresh = entries.filter { !$0.legacy }
    let fixed = fresh.filter {
        switch $0.delivery {
        case .systemPrompt, .mcpInstructions, .toolDescription: true
        default: false
        }
    }
    var fixedCharacters = 0
    var toolOrder: [String] = []
    var descriptions: [String: String] = [:]
    for entry in fixed {
        if case .toolDescription(let tool) = entry.delivery {
            if descriptions[tool] == nil { toolOrder.append(tool) }
            descriptions[tool, default: ""] += entry.text
        } else {
            fixedCharacters += entry.text.count
        }
    }
    if !toolOrder.isEmpty {
        let definitions: [JSONValue] = toolOrder.map { tool in
            var definition = context.toolDefinitions.first { $0["name"].string == tool }?.object ?? [
                "name": .string(tool),
                "inputSchema": .object(["type": .string("object"), "properties": .object([:])])
            ]
            definition["description"] = .string(descriptions[tool, default: ""])
            return .object(definition)
        }
        do {
            let encoded = try JSONValue.canonicalEncoder().encode(JSONValue.array(definitions))
            fixedCharacters += String(decoding: encoded, as: UTF8.self).count
        } catch {
            Issue.record(error)
            if let first = fixed.first { add(first, .budget) }
        }
    }
    if fixedCharacters > 15_000, let first = fixed.first { add(first, .budget) }
    var responseDirectives = 0
    var enumerations: Set<String> = []
    for entry in entries {
        if entry.text.count > entry.budgetCharacters { add(entry, .budget) }
        guard !entry.legacy else { continue }
        let text = entry.text
        let lower = text.lowercased()
        let tokens = Set(matches("[A-Za-z][A-Za-z0-9_]*", text))
        let lowerTokens = Set(tokens.map { $0.lowercased() })
        switch entry.delivery {
        case .toolAnswer, .refusal:
            if text.count > 160 { add(entry, .budget) }
        default: break
        }
        for token in tokens where token.contains("_") {
            if !context.toolNames.contains(token), !context.visibleNames.contains(token) { add(entry, .name) }
        }
        for phrase in matches("(?i)\\b(?:the )?(?:call|use) [a-z][a-z_0-9]*", text)
            where !phrase.lowercased().hasPrefix("the ") {
            let name = String(phrase.split(separator: " ").last!)
            if !context.toolNames.contains(name) { add(entry, .name); add(entry, .contradiction) }
        }
        for phrase in matches("\\b[a-z][a-z_0-9]* then [a-z][a-z_0-9]*\\b", text) {
            let names = phrase.components(separatedBy: " then ")
            if names.contains(where: { !context.toolNames.contains($0) }) { add(entry, .contradiction) }
        }
        if context.sentinels.contains(where: text.contains) { add(entry, .value) }
        if lower.contains("observe") || lower.contains("perceive") || lower.contains("re-read") || lower.contains("look again") {
            switch entry.delivery {
            case .toolAnswer, .refusal:
                if context.recovery != "observe" || context.hasAfterScene { add(entry, .contradiction) }
            default: break
            }
        }
        if (lower.contains("stays on the background seat") || lower.contains("stay on the background seat")
            || lower.range(of: "all actions.*seat", options: .regularExpression) != nil),
           !context.channels.isDisjoint(with: [.native, .web]) { add(entry, .contradiction) }
        if lower.range(of: "discover.*windows?.*then open_session", options: .regularExpression) != nil,
           !context.requiresWindow { add(entry, .contradiction) }
        if lower.contains("before you answer") || lower.contains("in your next call") {
            responseDirectives += 1
            if responseDirectives > 1 { add(entry, .contradiction) }
        }
        for field in matches("[a-z][a-z_0-9]* is one of", text) {
            if !enumerations.insert(field).inserted { add(entry, .contradiction) }
        }
        let jargon: Set<String> = ["qualified", "handback", "readback", "oracle", "producer", "candidate", "tract", "macdriver"]
        let apps: Set<String> = ["chrome", "finder", "textedit", "preview", "safari", "firefox", "reddit", "slack", "photoshop"]
        if !lowerTokens.isDisjoint(with: jargon.union(apps)) || tokens.contains("IMPORTANT")
            || !matches("\\b[A-Z]{2,}\\b", text).isEmpty
            || lower.range(of: "\\bp2-[0-9]+\\b|\\br-[a-z]-[0-9]+\\b", options: .regularExpression) != nil {
            add(entry, .style)
        }
        if lowerTokens.contains("seat"), entry.delivery != .seatLine { add(entry, .style) }
        let allowed = Set("·⇒…⟦⟧".unicodeScalars)
        if text.unicodeScalars.contains(where: { !$0.isASCII && !allowed.contains($0) }) { add(entry, .style) }
    }
    return violations
}

func specimen(_ text: String, delivery: ModelText.Delivery = .systemPrompt(order: 0), budget: Int = 1000,
              key: String = "test") -> ModelText.Entry {
    .init(key: .init(rawValue: key), owner: "AutomationMCP", delivery: delivery,
          budgetCharacters: budget, text: text, legacy: false)
}

let modelTextRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
