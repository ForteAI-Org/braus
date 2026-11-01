import Foundation
import LocalMCP
import PerceptionCore

enum MessageContract {
    static func mentionsObserve(_ text: String) -> Bool {
        text.range(of: #"\b(observe|perceive|re-read|look again|describe_scene)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func unknownToolNames(in text: String, known: Set<String>) -> Set<String> {
        let expression = /\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/
        return Set(text.matches(of: expression).map { String($0.output) }).subtracting(known)
    }

    static func overBudget(_ text: String, limit: Int = 160) -> Bool { text.count > limit }

    static func leakedValues(in text: String, scenes: [SceneSnapshot]) -> Set<String> {
        var found: Set<String> = []
        for value in scenes.flatMap({ $0.elements.compactMap(\.value) }) where value.count >= 8 {
            let characters = Array(value)
            for start in 0...(characters.count - 8) {
                let portion = String(characters[start..<(start + 8)])
                if text.contains(portion) { found.insert(portion) }
            }
        }
        return found
    }

    static func messages(in answer: JSONValue) -> [String] {
        switch answer {
        case .object(let fields):
            return fields.flatMap { key, value in
                key == "message" ? value.string.map { [$0] } ?? []
                    : (value.object != nil || value.array != nil ? messages(in: value) : [])
            }
        case .array(let values):
            return values.flatMap { value in
                value.object != nil || value.array != nil ? messages(in: value) : []
            }
        case .string(let text): return [text]
        default: return []
        }
    }

    static func violations(in messages: [String], scenes: [SceneSnapshot], known: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for message in messages {
            if mentionsObserve(message) { result.insert("observe") }
            if overBudget(message) { result.insert("messageBudget") }
            for name in unknownToolNames(in: message, known: known) { result.insert("unknownTool:\(name)") }
            if !leakedValues(in: message, scenes: scenes).isEmpty { result.insert("leakedValue") }
        }
        return result
    }
}
