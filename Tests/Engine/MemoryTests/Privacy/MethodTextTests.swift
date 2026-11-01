import Foundation
@testable import Memory
import Testing

@Suite("Method text admission and Recall compatibility")
struct MethodTextTests {

    private struct Value: Decodable {
        let name: String
        let text: String?
        let kind: String
        let state: String?

        func taskValue() throws -> TaskValue {
            let kind = try #require(TaskValueKind(rawValue: kind))
            let content: TaskValue.Content
            switch state {
                case "withheld": content = .withheld
                case "missing": content = .missing
                default: content = .text(try #require(text))
            }
            return try TaskValue(name: name, kind: kind, content: content, source: .request)
        }
    }

    private struct Case: Decodable {
        struct Context: Decodable {
            let values: [Value]
            let isUnderCollection: Bool
            let role: String?
        }
        struct Expected: Decodable {
            let method: String?
            let reason: String?
            let placeholder: String?
        }
        let id: String
        let text: String
        let context: Context
        let expected: Expected
    }

    private static var memoryTests: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func cases() throws -> [Case] {
        let url = Self.memoryTests.appendingPathComponent("Fixtures/MethodTextCases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    private func check(_ row: Case) throws {
        let context = MethodText.Context(
            values: try row.context.values.map { try $0.taskValue() },
            isUnderCollection: row.context.isUnderCollection,
            role: row.context.role
        )
        let expected: MethodText.Admission
        if let method = row.expected.method {
            expected = .method(method)
        } else {
            let reasonName = try #require(row.expected.reason)
            let reason = try #require(MethodText.InstanceReason(rawValue: reasonName))
            expected = .instance(placeholder: try #require(row.expected.placeholder), reason)
        }
        #expect(MethodText.admit(row.text, in: context) == expected, "\(row.id): \(row.text)")
    }

    @Test func casesTable() throws {
        let rows = try cases()
        #expect(rows.count >= 40)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for row in rows { try check(row) }
    }

    @Test func refusesSyntheticInstances() throws {
        let rows = try cases().filter { $0.id.hasPrefix("synthetic-") }
        #expect(Set(rows.map(\.id)) == Set((1...16).map { String(format: "synthetic-%02d", $0) }))
        for row in rows {
            #expect(row.expected.method == nil)
            try check(row)
        }
    }

    @Test func admitsMethodLabels() throws {
        for row in try cases() where row.expected.method != nil { try check(row) }
    }

    @Test func refusesTaskValues() throws {
        for row in try cases() where row.expected.reason == "taskValue" { try check(row) }
    }

    @Test func refusesFileShapes() throws {
        for row in try cases() where row.expected.reason == "fileName" { try check(row) }
    }

    @Test func refusesCollectionMembers() throws {
        for row in try cases() where row.expected.reason == "collectionMember" { try check(row) }
    }

    @Test func refusesDatesNumbersOrdinals() throws {
        for row in try cases() where row.expected.reason == "dateOrNumber" || row.expected.reason == "ordinal" {
            try check(row)
        }
    }

    private struct Corpus: Decodable {
        struct Query: Decodable {
            struct Input: Decodable {
                let name: String
                let value: String
                let kind: String?
            }
            let remaining: String
            let inputs: [Input]?
        }
        let queries: [Query]
    }

    private func assertCompatibility(_ text: String, values: [TaskValue]) {
        let expected = Self.legacyMasked(text, values: values)
        #expect(MethodText.masked(text, values: values).utf8.elementsEqual(expected.utf8))
        #expect(RecallText.masked(text, values: values).utf8.elementsEqual(expected.utf8))
        let mentions = Self.legacyMentions(text, values: values)
        #expect(MethodText.mentions(text, values: values) == mentions)
        #expect(RecallText.mentions(text, values: values) == mentions)
    }

    @Test func maskedIsByteIdenticalToToday() throws {
        let root = Self.memoryTests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Tests/Integration/AutomationRuntimeTests/Fixtures/recall-corpus-v4.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(!corpus.queries.isEmpty)
        for query in corpus.queries {
            let values = try (query.inputs ?? []).map { input in
                let kind = try #require(TaskValueKind(rawValue: input.kind ?? "text"))
                return try TaskValue(name: input.name, kind: kind, content: .text(input.value), source: .request)
            }
            assertCompatibility(query.remaining, values: values)
        }
    }

    @Test func recallCandidateBoundariesRemainIdentical() throws {
        let values = try [
            TaskValue(name: "file_name", kind: .file, content: .text("/docs/report_q3.pdf"), source: .request),
            TaskValue(name: "other_file", kind: .file, content: .text("/docs/report_q3.txt"), source: .request),
            TaskValue(name: "format", kind: .text, content: .text("pdf"), source: .request),
            TaskValue(name: "a", kind: .text, content: .text("Roma"), source: .request),
            TaskValue(name: "b", kind: .text, content: .text("Roma"), source: .request),
            TaskValue(name: "short", kind: .text, content: .text("ab"), source: .request),
            TaskValue(name: "slide", kind: .number, content: .text("2"), source: .request),
            TaskValue(name: "bad-name", kind: .text, content: .text("Delta"), source: .request),
            TaskValue(name: "missing", kind: .missing, content: .missing, source: .request),
            TaskValue(name: "hidden", kind: .file, content: .withheld, source: .request),
            TaskValue(name: "padded", kind: .text, content: .text(" Beta "), source: .request),
        ]
        let texts = [
            "Open /docs/report_q3.pdf and report_q3.pdf, report_q3, /docs, pdf",
            "ROMA Roma ab abc 2 12 222 Delta Beta", "report_q3extra xRoma Roma2", "", "Café Cafe\u{301}",
        ]
        for order in [values, Array(values.reversed())] {
            for text in texts { assertCompatibility(text, values: order) }
        }
        #expect(MethodText.masked("Roma", values: values) == "<a>")
        #expect(MethodText.masked("Roma", values: Array(values.reversed())) == "<b>")
        #expect(MethodText.masked("2 ab /docs", values: values) == "2 ab /docs")
        #expect(MethodText.mentions("Roma report_q3 2", values: values) == ["slide"])
        #expect(MethodText.masked("Delta", values: values) == "<bad-name>")
    }

    private static func legacyMasked(_ text: String, values: [TaskValue]) -> String {
        var replacements: [(text: String, name: String)] = []
        for candidate in RecallBinding.candidates(values) where !candidate.isDerived || candidate.name.hasSuffix(".name") {
            guard let value = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 3 else { continue }
            let name = candidate.isDerived ? String(candidate.name.dropLast(".name".count)) : candidate.name
            replacements.append((value, name))
        }
        var masked = text
        for replacement in replacements.sorted(by: { $0.text.count > $1.text.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: replacement.text) + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(masked.startIndex..., in: masked)
            masked = expression.stringByReplacingMatches(in: masked, range: range,
                                                         withTemplate: NSRegularExpression.escapedTemplate(for: "<\(replacement.name)>"))
        }
        return masked
    }

    private static func legacyMentions(_ text: String, values: [TaskValue]) -> Set<String> {
        var owners: [String: Set<String>] = [:]
        for candidate in RecallBinding.candidates(values) where !candidate.isDerived || candidate.name.hasSuffix(".name") {
            guard let value = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.count >= 3 || (!value.isEmpty && value.allSatisfy(\.isNumber)) else { continue }
            let name = candidate.isDerived ? String(candidate.name.dropLast(".name".count)) : candidate.name
            owners[value.lowercased(), default: []].insert(name)
        }
        var mentioned: Set<String> = []
        for (value, names) in owners where names.count == 1 {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: value) + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            mentioned.formUnion(names)
        }
        return mentioned
    }
}
