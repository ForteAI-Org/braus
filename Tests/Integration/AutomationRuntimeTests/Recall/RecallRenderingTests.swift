import AutomationMCP
@testable import AutomationRuntime
import Memory
import Foundation
import Testing

@Suite("RecallRendering")
struct RecallRenderingTests {
    func part(_ key: String, label: String = "Export {name}") -> RecallRendering.OfferedPart {
        .init(key: key, label: label, app: "Notes", parameters: ["name"], produces: ["file"],
              reliability: .init(verifiedRuns: 2, resultChecked: true), bundleID: "com.apple.Notes", partID: key)
    }

    func delivery(_ rows: [RecallRendering.RowParts] = [], head: String? = nil, guide: [String] = [],
                  chosen: [RecallRendering.ChosenPart] = [], notices: [String] = []) -> RecallRendering.Delivery {
        .init(memory: rows, guideHead: head, guide: guide, chosen: chosen, notices: notices,
              texts: ModelText.recallRenderingTexts)
    }

    @Test func summariesCarryIdAndText() {
        let rows = [RecallRendering.RowParts(row: .init(rawValue: "r1"), parts: [part("s1")])]
        let summaries = RecallRendering.summaries(rows, texts: ModelText.recallRenderingTexts)
        let answer = RecallRendering.render(delivery(rows), budget: 4000)
        #expect(summaries.count == 1)
        #expect(summaries.first?.bundleID == "com.apple.Notes")
        #expect(summaries.first?.partID == "s1")
        #expect(answer.text.contains(summaries.first?.text ?? "missing"))
        #expect(summaries.first?.text.contains("{name}") == true)
        #expect(summaries.first?.text.contains("private-file-name") == false)
    }

    @Test func compactRendering() {
        let rows = [RecallRendering.RowParts(row: .init(rawValue: "r1"), parts: [part("s1"), part("s2")])]
        let answer = RecallRendering.render(delivery(rows), budget: 4000)
        let guide = ModelText.text(.init(rawValue: RecallRendering.choiceGuide))
        #expect(answer.text.components(separatedBy: guide).count == 2)
        #expect(RecallRendering.summaries(rows, texts: ModelText.recallRenderingTexts).allSatisfy { $0.text.count <= 320 })
        #expect(!RecallRendering.render(delivery(), budget: 4000).text.contains(guide))
    }

    @Test func roundOrderKeepsBestForEachRow() {
        let rows = (1...3).map { number in
            RecallRendering.RowParts(row: .init(rawValue: "r\(number)"),
                parts: [part("s\(number)"), part("s\(number + 3)")])
        }
        let best = rows.map { RecallRendering.RowParts(row: $0.row, parts: Array($0.parts.prefix(1))) }
        let cost = RecallRendering.render(delivery(best), budget: 4000).text.count
        let answer = RecallRendering.render(delivery(rows), budget: cost)
        for number in 1...3 { #expect(answer.text.contains("s\(number) «")) }
        for number in 4...6 { #expect(!answer.text.contains("s\(number) «")) }
        #expect(answer.leftOut?.parts == 3)
        #expect(answer.text.count <= cost)
    }

    @Test func oneBudgetMemoryFirst() {
        let rows = [RecallRendering.RowParts(row: .init(rawValue: "r1"), parts: [part("s1")])]
        let cost = RecallRendering.render(delivery(rows, head: "Always present"), budget: 4000).text.count
        let answer = RecallRendering.render(delivery(rows, head: "Always present", guide: ["Extra section"]), budget: cost)
        #expect(answer.text.contains("Always present"))
        #expect(answer.text.contains("s1 «"))
        #expect(!answer.text.contains("Extra section"))
        #expect(answer.leftOut?.guideSections == 1)
        #expect(answer.events.contains { if case .planDeliveryTrimmed = $0 { true } else { false } })
    }

    @Test func chosenStepsInsideBudget() {
        let steps = String(repeating: "complete step\n", count: 50)
        let chosen = (1...3).map { RecallRendering.ChosenPart(row: .init(rawValue: "r\($0)"), key: "s\($0)", steps: steps) }
        let answer = RecallRendering.render(delivery(chosen: chosen, notices: ["Keep this notice"]), budget: 950)
        #expect(answer.text.count <= 950)
        #expect(answer.text.contains("Keep this notice"))
        #expect(answer.text.contains(steps))
        #expect(answer.leftOut?.chosenParts == ["s2", "s3"])
        #expect(answer.text.contains("choose it again alone"))
        let alone = RecallRendering.render(delivery(chosen: [chosen[0]]), budget: 50)
        #expect(alone.text.contains(steps))
        #expect(alone.leftOut == nil)
    }

    @Test func longLabelsStayCompact() {
        let rows = [RecallRendering.RowParts(row: .init(rawValue: "r1"), parts: [part("s1", label: String(repeating: "word ", count: 300))])]
        #expect(RecallRendering.summaries(rows, texts: ModelText.recallRenderingTexts).allSatisfy { $0.text.count <= 320 })
    }
}

extension RecallRenderingTests {
    @Test func budgetCountsUTF8Bytes() {
        let rows = [RecallRendering.RowParts(row: .init(rawValue: "r1"), parts: [part("s1", label: "保存文書")])]
        let full = RecallRendering.render(delivery(rows), budget: 4000)
        let answer = RecallRendering.render(delivery(rows), budget: full.text.utf8.count - 1, measure: { $0.utf8.count })
        #expect(!answer.text.contains("s1 «"))
        #expect(answer.leftOut?.parts == 1)
    }
}
