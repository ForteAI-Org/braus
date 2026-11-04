import Foundation
import Memory

/// RecallRendering composes complete memory parts and guide sections under one character budget.
/// Fixed language is supplied by ModelText at the boundary, keeping this value transformation independent of MCP.
public nonisolated enum RecallRendering {
    public typealias TrustLabel = RecallTrust
    public static let choiceGuide = "recall.choice"
    public static let answerBudget = 4_000

    public struct Reliability: Sendable, Equatable {
        public let verifiedRuns: Int
        public let resultChecked: Bool
        public init(verifiedRuns: Int, resultChecked: Bool) {
            self.verifiedRuns = verifiedRuns
            self.resultChecked = resultChecked
        }
    }

    public struct OfferedPart: Sendable, Equatable {
        public let key: String
        public let label: String
        public let app: String
        public let startsFrom: String?
        public let parameters: [String]
        public let produces: [String]
        public let effect: String?
        public let shortSteps: [String]?
        public let reliability: Reliability
        public let trust: TrustLabel?
        public let bundleID: String
        public let partID: String

        public init(key: String, label: String, app: String, startsFrom: String? = nil,
                    parameters: [String] = [], produces: [String] = [], effect: String? = nil,
                    shortSteps: [String]? = nil, reliability: Reliability, trust: TrustLabel? = nil,
                    bundleID: String, partID: String) {
            self.key = key
            self.label = label
            self.app = app
            self.startsFrom = startsFrom
            self.parameters = parameters
            self.produces = produces
            self.effect = effect
            self.shortSteps = shortSteps
            self.reliability = reliability
            self.trust = trust
            self.bundleID = bundleID
            self.partID = partID
        }
    }

    public struct RowParts: Sendable, Equatable {
        public struct UnknownApp: Sendable, Equatable {
            public let named: String
            public let candidates: [String]
            public init(named: String, candidates: [String]) {
                self.named = named
                self.candidates = Array(candidates.prefix(3))
            }
        }
        public let row: TodoRowID
        public let parts: [OfferedPart]
        public let unknownApp: UnknownApp?
        public init(row: TodoRowID, parts: [OfferedPart], unknownApp: UnknownApp? = nil) {
            self.row = row
            self.parts = unknownApp == nil ? Array(parts.prefix(3)) : []
            self.unknownApp = unknownApp
        }
    }

    public struct ChosenPart: Sendable, Equatable {
        public let row: TodoRowID
        public let key: String
        public let steps: String
        public init(row: TodoRowID, key: String, steps: String) {
            self.row = row
            self.key = key
            self.steps = steps
        }
    }

    public struct LeftOut: Sendable, Equatable {
        public let parts: Int
        public let guideSections: Int
        public let chosenParts: [String]
        public init(parts: Int, guideSections: Int, chosenParts: [String]) {
            self.parts = parts
            self.guideSections = guideSections
            self.chosenParts = chosenParts
        }
    }

    public enum DeliveryEvent: Sendable, Equatable {
        case planDeliveryTrimmed(LeftOut)
        case guideSectionCovered(bundleID: String, partID: String)
    }

    /// Texts contains catalogue entries; there is no language fallback outside the catalogue.
    public struct Texts: Sendable {
        public let entries: [String: String]
        public init(entries: [String: String]) { self.entries = entries }
        public subscript(_ key: String) -> String {
            guard let value = entries["recall." + key] else { preconditionFailure("Missing Recall text: \(key)") }
            return value
        }
    }

    public struct Delivery: Sendable {
        public let memory: [RowParts]
        public let guideHead: String?
        public let guide: [String]
        public let chosen: [ChosenPart]
        public let notices: [String]
        public var leftOut: LeftOut?
        public let texts: Texts
        public init(memory: [RowParts], guideHead: String? = nil, guide: [String] = [],
                    chosen: [ChosenPart] = [], notices: [String] = [], leftOut: LeftOut? = nil, texts: Texts) {
            self.memory = memory
            self.guideHead = guideHead
            self.guide = guide
            self.chosen = chosen
            self.notices = notices
            self.leftOut = leftOut
            self.texts = texts
        }
    }

    /// Returns exactly the one-line descriptions delivered to the model, with stable archive identities.
    public static func summaries(_ rows: [RowParts], texts: Texts) -> [MemoryPartSummary] {
        rows.flatMap { row in row.parts.map { part in
            MemoryPartSummary(bundleID: part.bundleID, partID: part.partID, label: part.label,
                              text: line(part, texts: texts))
        } }
    }

    /// Returns the prefix of the same round order used by render, without inferring receipts from rendered text.
    public static func deliveredMemory(_ rows: [RowParts], omittingFromEnd omitted: Int) -> [RowParts] {
        let ordered = orderedParts(rows)
        var keys: [TodoRowID: Set<String>] = [:]
        for (row, part) in ordered.prefix(max(0, ordered.count - max(0, omitted))) {
            keys[row, default: []].insert(part.key)
        }
        return rows.map { row in
            RowParts(row: row.row, parts: row.parts.filter { keys[row.row]?.contains($0.key) == true },
                     unknownApp: row.unknownApp)
        }
    }

    private static func orderedParts(_ rows: [RowParts]) -> [(TodoRowID, OfferedPart)] {
        (0..<3).flatMap { rank in rows.compactMap { row in
            row.parts.indices.contains(rank) ? (row.row, row.parts[rank]) : nil
        } }
    }

    public static func render(_ delivery: Delivery, budget: Int, measure: (String) -> Int = { $0.count }) -> (text: String, leftOut: LeftOut?, events: [DeliveryEvent]) {
        let texts = delivery.texts
        var blocks = [delivery.guideHead].compactMap { $0 }.filter { !$0.isEmpty } + delivery.notices
        for row in delivery.memory {
            if let unknown = row.unknownApp {
                blocks.append(row.row.rawValue + ": " + texts["unknownApp"] + " " + unknown.named
                    + (unknown.candidates.isEmpty ? "" : " · " + texts["candidates"] + " " + unknown.candidates.joined(separator: ", ")))
            }
        }
        func joined(_ values: [String]) -> String { values.filter { !$0.isEmpty }.joined(separator: "\n") }
        func missing(_ part: ChosenPart) -> String {
            part.row.rawValue + ": " + texts["stepsOf"] + " " + part.key + " " + texts["overBudget"]
        }
        var chosen = delivery.chosen.map(missing)
        var chosenCount = 0
        for (index, part) in delivery.chosen.enumerated() {
            let complete = part.row.rawValue + " " + part.key + "\n" + part.steps
            var candidate = chosen
            candidate[index] = complete
            let alone = delivery.chosen.count == 1 && joined(blocks + candidate).utf8.count <= RecallContract.channelLimitBytes
            guard alone || measure(joined(blocks + candidate)) <= max(0, budget) else { break }
            chosen = candidate
            chosenCount += 1
        }
        blocks += chosen
        var kept = 0
        let rounds = orderedParts(delivery.memory).map { row, part in
            row.rawValue + ": " + line(part, texts: texts)
        }
        for line in rounds {
            let additions = (kept == 0 ? [texts["choice"]] : []) + [line]
            guard measure(joined(blocks + additions)) <= max(0, budget) else { break }
            blocks += additions
            kept += 1
        }
        var sections = 0
        for section in delivery.guide {
            guard measure(joined(blocks + [section])) <= max(0, budget) else { break }
            blocks.append(section)
            sections += 1
        }
        let omitted = Array(delivery.chosen.dropFirst(chosenCount).map(\.key))
        let previous = delivery.leftOut
        let left = LeftOut(parts: rounds.count - kept + (previous?.parts ?? 0),
            guideSections: delivery.guide.count - sections + (previous?.guideSections ?? 0),
            chosenParts: omitted + (previous?.chosenParts ?? []))
        let trimmed = left.parts > 0 || left.guideSections > 0 || !left.chosenParts.isEmpty
        return (joined(blocks), trimmed ? left : nil, trimmed ? [.planDeliveryTrimmed(left)] : [])
    }

    private static func line(_ part: OfferedPart, texts: Texts) -> String {
        var fields = [part.key + " «" + String(part.label.prefix(100)) + "»", String(part.app.prefix(40))]
        if let start = part.startsFrom { fields.append(texts["from"] + " " + String(start.prefix(40))) }
        if !part.parameters.isEmpty { fields.append(texts["needs"] + " " + part.parameters.map { "{\($0)}" }.joined(separator: ", ")) }
        if !part.produces.isEmpty { fields.append(texts["makes"] + " " + part.produces.map { "{\($0)}" }.joined(separator: ", ")) }
        if let effect = part.effect { fields.append(effect) }
        if let steps = part.shortSteps, steps.count <= 3 { fields.append(steps.joined(separator: "; ")) }
        var suffix = [texts["verified"] + " \(part.reliability.verifiedRuns)×"]
        if part.reliability.resultChecked { suffix.append(texts["resultChecked"]) }
        if let trust = part.trust { suffix.append(texts[trust.rawValue]) }
        let ending = suffix.joined(separator: " · ")
        let body = fields.joined(separator: " · ")
        let room = max(0, 320 - ending.count - 3)
        return String(body.prefix(room)) + " · " + ending
    }
}

/// TokenEstimate estimates tokens as the character count divided by four, rounded up: (n + 3) / 4.
public nonisolated enum TokenEstimate {
    public static func tokens(in text: String) -> Int { tokens(characterCount: text.count) }
    public static func tokens(characterCount: Int) -> Int { (max(0, characterCount) + 3) / 4 }
}
