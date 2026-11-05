//
//  SceneAnswerBudget.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import Foundation
import PerceptionCore

/// SceneAnswerBudget fits the scene text a tool answer carries into what the model can receive,
/// without a silent cut: an answer over the budget keeps the header, outlines every section, and
/// carries whole sections until the budget, naming the ones left out and how to read them.
///
/// It shapes only the text sent to the model. The scene itself, its baseline for later changes
/// and the element resolution of every action keep the whole scene. Sizes are in characters.
nonisolated enum SceneAnswerBudget {

    /// The most characters of scene text one answer carries.
    ///
    /// The Claude command line moves an MCP result over `MAX_MCP_OUTPUT_TOKENS` (25,000 tokens by
    /// default) to a file the model cannot read. A dense window measured at 1,117 to 1,136 elements
    /// wrote 61,000 to 65,000 characters and never reached the model; 47,000 characters of 868
    /// elements did. 36,000 keeps clear of that limit with the rest of the answer around it.
    static let characters = 36_000

    /// The scene text for an answer: `layout.text` unchanged when it fits `budget`, else the budgeted
    /// form. `aimed` is the title of the section an action targeted, kept before the others.
    ///
    /// Sections are kept whole in this order, each one that still fits: dialogs, sheets, popovers,
    /// alerts and an open menu (the scene marks no focus, and these hold it); the aimed section;
    /// the top and bottom bars, toolbar and window controls; then the rest, smallest first so the
    /// most sections fit. They are written in the scene's own order. The header, the outline and
    /// the commands line are always kept; an outline of hundreds of sections would itself not fit.
    static func text(
        of layout: SceneTextLayout,
        aimed    : String? = nil,
        budget   : Int = characters
    ) -> String {
        let whole = layout.text
        guard whole.count > budget else { return whole }
        let parts = layout.parts
        let sizes = parts.map(\.text.count)
        let pageCounts = parts.map { pages(of: $0, budget: budget).count }
        // Reserve the outline and the note as if every part were left out: the answer never grows past it.
        let reserved = layout.head.count + layout.commands.count
            + intro(parts.count, shown: parts.count, budget: budget).count
            + outline(parts, shown: [], pageCounts: pageCounts).count
            + leftOutNote(parts.map(\.title)).count
        var room = budget - reserved
        var shown = Set<Int>()
        for index in priorityOrder(parts, sizes: sizes, aimed: aimed) where sizes[index] <= room {
            shown.insert(index)
            room -= sizes[index]
        }
        let left = parts.indices.filter { !shown.contains($0) }.map { parts[$0].title }
        return layout.head
            + intro(parts.count, shown: shown.count, budget: budget)
            + outline(parts, shown: shown, pageCounts: pageCounts)
            + parts.indices.filter(shown.contains).map { parts[$0].text }.joined()
            + layout.commands
            + leftOutNote(left)
    }

    /// One page of the part titled `title`, matched as `section` matches a section in `act`, or by
    /// a part's own title such as `unsectioned`. A part over `budget` is cut into pages of whole lines.
    ///
    /// Throws when no part has that title or the page does not exist, saying what does.
    static func section(
        _ title : String,
        page    : Int,
        of scene: SceneSnapshot,
        layout  : SceneTextLayout,
        budget  : Int = characters
    ) throws -> (title: String, text: String, pages: Int) {
        let resolved = scene.resolveSection(named: title)?.name ?? title
        guard let part = layout.parts.first(where: { $0.title.caseInsensitiveCompare(resolved) == .orderedSame })
        else {
            let titles = layout.parts.map { "\"\($0.title)\"" }.joined(separator: ", ")
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_answer_budget.titles.v1")) + title
                + ModelText.text(.init(rawValue: "scene_answer_budget.titles.v1.2")) + titles
                + ModelText.text(.init(rawValue: "scene_answer_budget.titles.v1.3")))
        }
        let pages = self.pages(of: part, budget: budget)
        guard pages.indices.contains(page - 1) else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_answer_budget.pages.v1")) + part.title
                + ModelText.render(.init(rawValue: "scene_answer_budget.pages.v1.2"), ["count": .count(pages.count)]))
        }
        let heading = part.heading.isEmpty ? "## \(part.title)\n" : part.heading
        let more = page < pages.count ? ModelText.render(.init(rawValue: "scene_answer_budget.page.v1"), [
            "page": .count(page), "pages": .count(pages.count), "next": .count(page + 1)
        ]) : ""
        return (part.title, heading + pages[page - 1] + more, pages.count)
    }

    /// The title of the section an action aimed at in `scene`: its `section` argument as resolution
    /// reads it (a section, or a container whose section it gives), else the section of its target.
    static func aimedTitle(in scene: SceneSnapshot, section: String?, target: String?) -> String? {
        if let section, !section.isEmpty {
            if let named = scene.resolveSection(named: section) { return named.name }
            let owned = scene.elements.first { $0.container?.caseInsensitiveCompare(section) == .orderedSame }
            if let owned { return owned.section }
        }
        return target.flatMap { scene.candidates(target: $0).first?.section }
    }

    /// Fits T2 safe lines while retaining each shown line's provenance and section identity.
    static func lines(_ whole: [SceneSnapshot.TextLine], of scene: SceneSnapshot,
                      aimed: String? = nil, budget: Int = characters) -> [SceneSnapshot.TextLine] {
        guard whole.reduce(0, { $0 + $1.text.count }) > budget else { return whole }
        let layout = scene.textLayout()
        let parts = layout.parts
        let grouped = parts.map { part in partLines(part, in: whole) }
        let sizes = grouped.map { $0.reduce(0, { $0 + $1.text.count }) }
        let pageCounts = zip(parts, grouped).map { part, lines in
            pages(body: lines.filter { $0.job != .section }.map(\.text).joined(),
                  heading: part.heading, budget: budget).count
        }
        let head = whole.filter { $0.job == .header || ($0.job == .note && $0.source != .outOfView) }
        let commands = whole.filter { $0.job == .commands }
        let reserved = (head + commands).reduce(0, { $0 + $1.text.count })
            + intro(parts.count, shown: parts.count, budget: budget).count
            + outline(parts, shown: [], pageCounts: pageCounts).count
            + leftOutNote(parts.map(\.title)).count
        var room = budget - reserved
        var shown = Set<Int>()
        for index in priorityOrder(parts, sizes: sizes, aimed: aimed) where sizes[index] <= room {
            shown.insert(index)
            room -= sizes[index]
        }
        var result = head
        result.append(.init(intro(parts.count, shown: shown.count, budget: budget)
            + outline(parts, shown: shown, pageCounts: pageCounts), source: .braus, job: .note))
        for index in parts.indices where shown.contains(index) { result += grouped[index] }
        result += commands
        let left = parts.indices.filter { !shown.contains($0) }.map { parts[$0].title }
        if !left.isEmpty { result.append(.init(leftOutNote(left), source: .braus, job: .note)) }
        return result
    }

    /// A paged section uses the same safe cuts as the scene rather than restoring omitted table text.
    static func safeSection(_ title: String, page: Int, of scene: SceneSnapshot,
                            lines whole: [SceneSnapshot.TextLine], budget: Int = characters) throws -> (title: String, text: String, pages: Int) {
        let layout = scene.textLayout()
        let resolved = scene.resolveSection(named: title)?.name ?? title
        guard let part = layout.parts.first(where: { $0.title.caseInsensitiveCompare(resolved) == .orderedSame }) else {
            return try section(title, page: page, of: scene, layout: layout, budget: budget)
        }
        let lines = partLines(part, in: whole)
        let pages = pages(body: lines.filter { $0.job != .section }.map(\.text).joined(),
                          heading: part.heading, budget: budget)
        guard pages.indices.contains(page - 1) else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_answer_budget.pages.v1")) + part.title
                + ModelText.render(.init(rawValue: "scene_answer_budget.pages.v1.2"), ["count": .count(pages.count)]))
        }
        let heading = part.heading.isEmpty ? "## \(part.title)\n" : part.heading
        let more = page < pages.count ? ModelText.render(.init(rawValue: "scene_answer_budget.page.v1"), [
            "page": .count(page), "pages": .count(pages.count), "next": .count(page + 1)
        ]) : ""
        return (part.title, heading + pages[page - 1] + more, pages.count)
    }

    private static func partLines(_ part: PerceptionCore.SceneTextPart,
                                  in lines: [SceneSnapshot.TextLine]) -> [SceneSnapshot.TextLine] {
        lines.filter { line in
            guard [.section, .element, .icons].contains(line.job) else { return false }
            if line.source == .outOfView { return part.title.hasPrefix("past the window's edge") }
            return line.section.map { $0 == part.title } ?? (part.title == "unsectioned")
        }
    }

    // MARK: Parts

    /// The body of `part` in pages of whole lines, each with room for the heading and the page note.
    /// A single line longer than a page, such as a long value, is split across pages. Never empty.
    static func pages(of part: PerceptionCore.SceneTextPart, budget: Int) -> [String] {
        pages(body: part.body, heading: part.heading, budget: budget)
    }

    private static func pages(body: String, heading: String, budget: Int) -> [String] {
        let capacity = max(budget - heading.count - pageNoteRoom, 1)
        var lines = body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var pages: [String] = []
        var page = ""
        var used = 0
        for line in lines {
            var rest = Substring(line + "\n")
            var size = rest.count
            while size > 0 {
                if used + size <= capacity {
                    page += rest
                    used += size
                    size = 0
                } else if used == 0 {
                    page = String(rest.prefix(capacity))
                    rest = rest.dropFirst(capacity)
                    size -= capacity
                    pages.append(page)
                    page = ""
                } else {
                    pages.append(page)
                    page = ""
                    used = 0
                }
            }
        }
        return pages.isEmpty || used > 0 ? pages + [page] : pages
    }

    /// Room on a page for "Page n of m: page n+1 continues it."
    private static let pageNoteRoom = 80

    /// Dialogs and their kin first, the aimed section, the bars, then the rest smallest first.
    private static func priorityOrder(_ parts: [PerceptionCore.SceneTextPart], sizes: [Int], aimed: String?) -> [Int] {
        func rank(_ part: PerceptionCore.SceneTextPart) -> Int {
            let lower = part.title.lowercased()
            let words = Set(lower.split { !$0.isLetter }.map(String.init))
            if lower == "open menu" || !words.isDisjoint(with: ["dialog", "sheet", "popover", "alert"]) { return 0 }
            if let aimed, part.title.caseInsensitiveCompare(aimed) == .orderedSame { return 1 }
            let bars = ["top bar", "bottom bar", "toolbar", "window controls"]
            if bars.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) { return 2 }
            return 3
        }
        let ranks = parts.map(rank)
        return parts.indices.sorted { (ranks[$0], sizes[$0], $0) < (ranks[$1], sizes[$1], $1) }
    }

    // MARK: Text

    private static func intro(_ count: Int, shown: Int, budget: Int) -> String {
        ModelText.render(.init(rawValue: "scene_answer_budget.intro.v1"), [
            "budget": .count(budget), "shown": .count(shown), "count": .count(count)
        ])
    }

    /// One line per part: its title and frame as the heading prints them, its count, and whether
    /// it is shown; a left-out part over the budget says how many pages it reads in.
    private static func outline(_ parts: [PerceptionCore.SceneTextPart], shown: Set<Int>, pageCounts: [Int]) -> String {
        parts.indices.map { index in
            let part = parts[index]
            let frame = part.heading.isEmpty ? part.title : String(part.heading.dropFirst(3).dropLast())
            let state = shown.contains(index) ? ModelText.text(.init(rawValue: "scene_answer_budget.shown.v1"))
                : pageCounts[index] > 1
                    ? ModelText.render(.init(rawValue: "scene_answer_budget.leftOutPages.v1"), ["count": .count(pageCounts[index])])
                    : ModelText.text(.init(rawValue: "scene_answer_budget.leftOut.v1"))
            return "- " + frame + ": "
                + ModelText.render(.init(rawValue: "scene_answer_budget.outline.v1"), ["count": .count(part.elementCount)])
                + state + "\n"
        }.joined()
    }

    private static func leftOutNote(_ titles: [String]) -> String {
        guard !titles.isEmpty else { return "" }
        return ModelText.text(.init(rawValue: "scene_answer_budget.leftOutNote.v1"))
            + titles.map { "\"\($0)\"" }.joined(separator: ", ")
            + ModelText.text(.init(rawValue: "scene_answer_budget.leftOutNote.v1.2"))
    }
}
