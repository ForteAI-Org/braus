//
//  SceneRendering.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation

/// SceneTextCuts removes text that cannot name a target. Empty preserves the original rendering.
public struct SceneTextCuts: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Omits shared icon ids only when their group remains ambiguous after collapsing row facets.
    public static let sharedIconIDs = SceneTextCuts(rawValue: 1 << 0)
    /// Omits zero-length selections, which describe a caret rather than selected text.
    public static let emptySelections = SceneTextCuts(rawValue: 1 << 1)
    public static let safe: SceneTextCuts = [.sharedIconIDs, .emptySelections]
}

/// SceneRendering turns a scene into the text a language model reads: a compact map of named
/// panels with their notable elements, or the flat list when no structure was found.
extension SceneSnapshot {

    /// Renders the map tier: every section with its count and up to `notable` elements, stateful
    /// controls first because actionable state must never be hidden by summarization, then learned
    /// affordances, then labeled controls and icons. Roughly two thousand characters where the
    /// full scene is ninety thousand. An open menu shows up to sixty rows: its rows are the surface.
    public func mapText(notable: Int = 8) -> String {
        guard !sections.isEmpty else { return text() }
        var out = header() + knowledgeText()
        out += "map: \(elements.count) elements in \(sections.count) sections (describe_section(name) drills in)\n"
        for section in sections {
            let members = elements.filter { $0.section == section.name }
            out += sectionLine(section, count: members.count)
            let ranked = members.enumerated().sorted { a, b in
                let ra = Self.mapRank(a.element), rb = Self.mapRank(b.element)
                if ra != rb { return ra < rb }
                let xa = a.element.bounds.x, xb = b.element.bounds.x
                return xa != xb ? xa < xb : a.offset < b.offset
            }.map(\.element)
            // Nameless clutter is filtered before truncating, so the budget is spent on real rows.
            let showable = ranked.filter { !$0.isUnlabeled || $0.state != nil }
            let budget = showable.count <= 10 ? showable.count
                : (section.name == Self.openMenu ? min(60, showable.count) : notable)
            let shown = showable.prefix(budget)
            for element in shown {
                let state = element.state.map { " [\($0.rawValue)]" } ?? ""
                let details = Self.liveDetails(element)
                let does  = element.does.map { ": \(Self.inline($0))" } ?? ""
                let label = element.isUnlabeled ? "(unlabeled icon: target id '\(element.id)')" : Self.inline(element.label)
                let field = AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")
                let reference = field ? "[field] \(label) id:'\(element.id)'" : label
                out += "    \(reference)\(state)\(details)\(does)\n"
            }
            if showable.count > shown.count {
                out += "    … +\(showable.count - shown.count) more (describe_section)\n"
            }
        }
        let loose = elements.filter { $0.section == nil }.count
        if loose > 0 { out += "(+\(loose) unsectioned elements)\n" }
        if !commands.isEmpty { out += "commands: \(commands.count) menu paths known\n" }
        return out + outOfViewText()
    }

    /// Renders the full scene in the compact form the model reads: one header line, then one line
    /// per element under its `## section` line, with unlabeled plain icons gathered on one `icons:` line.
    ///
    /// Panels, and the elements inside each, come in reading order rather than in the order
    /// composition gathered them, so one screen renders one text. An open menu keeps its own order.
    /// The format is lossless for target resolution: every label, id, section and state it resolved
    /// by is still printed, and a `{container}` is printed where it changes within a section.
    public func text(cuts: SceneTextCuts = []) -> String {
        textLines(cuts: cuts).map(\.text).joined()
    }

    /// TextLine carries renderer provenance before an answer assigns UTF-8 spans.
    public struct TextLine: Sendable, Equatable {
        public enum Source: String, Sendable { case perception, memory, outOfView, braus }
        public enum Job: String, Sendable { case header, section, element, icons, commands, change, pointer, note }
        public let text: String
        public let source: Source
        public let job: Job
        public let section: String?

        package init(_ text: String, source: Source = .perception, job: Job, section: String? = nil) {
            self.text = text
            self.source = source
            self.job = job
            self.section = section
        }
    }

    /// Writes the whole scene with line roles; joining the lines preserves the original text bytes.
    public func textLines(cuts: SceneTextCuts = []) -> [TextLine] {
        var lines = [TextLine(compactHeader(counting: true), job: .header)]
        let knowledge = knowledgeText()
        if !knowledge.isEmpty { lines.append(TextLine(knowledge, source: .memory, job: .note)) }
        let shared = labelsSharedAcrossOwners
        func append(_ members: [SceneElement], section: String? = nil) {
            let text = compactLines(of: members, sharedLabels: shared,
                                    keepingOrder: section == Self.openMenu, cuts: cuts)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
                lines.append(TextLine(String(line) + "\n", job: line.hasPrefix("icons:") ? .icons : .element,
                                      section: section))
            }
        }
        if sections.isEmpty {
            append(elements)
        } else {
            for section in sectionsInReadingOrder {
                lines.append(TextLine(compactSectionLine(section), job: .section, section: section.name))
                append(elements.filter { $0.section == section.name }, section: section.name)
            }
            let loose = elements.filter { $0.section == nil }
            if !loose.isEmpty {
                lines.append(TextLine(Self.compactSectionLine(named: Self.unsectioned), job: .section))
                append(loose)
            }
        }
        if !commands.isEmpty { lines.append(TextLine(commandsLine(), job: .commands)) }
        if !outOfViewFields.isEmpty {
            lines.append(TextLine(Self.outOfViewHeading, source: .outOfView, job: .section,
                                  section: "past the window's edge"))
            lines += outOfViewFields.map {
                TextLine(Self.outOfViewLine($0) + "\n", source: .outOfView, job: .element,
                         section: "past the window's edge")
            }
        }
        return lines
    }

    static var outOfViewHeading: String {
        compactSectionLine(named: "past the window's edge (read only, not visible)")
    }

    private func outOfViewText() -> String {
        guard !outOfViewFields.isEmpty else { return "" }
        return Self.outOfViewHeading + outOfViewFields.map { Self.outOfViewLine($0) + "\n" }.joined()
    }

    static func outOfViewLine(_ field: OutOfViewField) -> String {
        let value = escapedValue(field.value.trimmingCharacters(in: .whitespacesAndNewlines))
        let availability = field.isEnabled == false ? " [disabled]" : ""
        let owner = field.container.map { " {\(inline($0))}" } ?? ""
        let details = field.role == "AXSecureTextField" ? " secret" : " = \(value)"
        return "[field] \(inline(field.label))\(details)\(availability)\(owner)"
    }

    /// The heading of the elements that belong to no section.
    static let unsectioned = "unsectioned"

    /// The section name of an open pop-up menu: its rows are its surface, kept in the menu's order.
    static let openMenu = "open menu"

    /// How far apart two vertical centers may be and still share a row: eight captured pixels, meant
    /// to keep a label on the row of the icon beside it and two lines of UI text on rows of their own.
    var rowTolerance: Double { 8 / Double(max(viewportPixelSize.height, 1)) }

    /// The sections in reading order, the same rule as elements.
    var sectionsInReadingOrder: [SceneSection] {
        Self.readingOrder(sections, rowTolerance: rowTolerance, bounds: \.bounds, tieBreak: \.name)
    }

    /// The labels, lowercased, that more than one container owns: a line copied alone must still name
    /// its container for `resolve` to tell them apart, so those lines print it even when it holds.
    var labelsSharedAcrossOwners: Set<String> {
        var owners: [String: Set<String?>] = [:]
        for element in elements { owners[element.label.lowercased(), default: []].insert(element.container) }
        return Set(owners.filter { $0.value.count > 1 }.keys)
    }

    /// The lines of `members` in the compact form: reading order unless `keepingOrder`, a container
    /// printed where it differs from the line before or where `sharedLabels` names the label, and the
    /// plain unlabeled icons on one last line.
    func compactLines(
        of members  : [SceneElement],
        sharedLabels: Set<String>,
        keepingOrder: Bool = false,
        cuts        : SceneTextCuts = []
    ) -> String {
        let ordered = keepingOrder ? members : Self.readingOrder(
            members.map { ($0, Self.elementLine($0)) },
            rowTolerance: rowTolerance,
            bounds      : \.0.bounds,
            tieBreak    : \.1
        ).map(\.0)
        var out = ""
        var icons: [SceneElement] = []
        var owner: String?
        for element in ordered {
            if Self.isPlainIcon(element) {
                icons.append(element)
                continue
            }
            // The owner holds until another one is printed; `{}` says the line has none.
            let repeated = element.container == owner
                && !(element.container != nil && sharedLabels.contains(element.label.lowercased()))
            let note = repeated ? "" : element.container.map { " {\(Self.inline($0))}" } ?? " {}"
            owner = element.container
            out += Self.elementLine(element, ownerNote: note, cuts: cuts)
        }
        if !icons.isEmpty { out += iconsLine(icons, original: members.filter(Self.isPlainIcon), cuts: cuts) }
        return out
    }

    /// `items` in reading order: rows top to bottom, then left to right within a row. A row holds
    /// every item whose vertical center lies within `rowTolerance` of its first item's. `tieBreak`
    /// orders items at one place, so equal sets of items come out equal whatever order they came in.
    static func readingOrder<Item>(
        _ items     : [Item],
        rowTolerance: Double,
        bounds      : (Item) -> NormalizedRect,
        tieBreak    : (Item) -> String
    ) -> [Item] {
        let byCenter = items.sorted {
            (bounds($0).midY, bounds($0).x, tieBreak($0)) < (bounds($1).midY, bounds($1).x, tieBreak($1))
        }
        var rows: [[Item]] = []
        var rowCenter = -Double.infinity
        for item in byCenter {
            if bounds(item).midY - rowCenter > rowTolerance {
                rows.append([item])
                rowCenter = bounds(item).midY
            } else {
                rows[rows.count - 1].append(item)
            }
        }
        return rows.flatMap { row in
            row.sorted {
                (bounds($0).x, bounds($0).midY, tieBreak($0)) < (bounds($1).x, bounds($1).midY, tieBreak($1))
            }
        }
    }

    private var inlineTitle: String {
        Self.inline(windowTitle).replacingOccurrences(of: "\"", with: "\\\"")
    }

    func header() -> String {
        "app: \(Self.inline(appName)) (\(Self.inline(bundleID)))\(windowTitle.isEmpty ? "" : ": \"\(inlineTitle)\"")\n"
    }

    /// `App (bundle) "title"`, then the viewport and the element count when `counting`.
    func compactHeader(counting: Bool) -> String {
        let title = windowTitle.isEmpty ? "" : " \"\(inlineTitle)\""
        guard counting else { return "\(Self.inline(appName)) (\(Self.inline(bundleID)))\(title)\n" }
        return "\(Self.inline(appName)) (\(Self.inline(bundleID)))\(title) \(viewportPixelSize.width)x\(viewportPixelSize.height), "
            + "\(elements.count) elements\n"
    }

    /// What the memory said about the scene, one line each, or nothing for a scene it did not read.
    func knowledgeText() -> String {
        knowledge.map { $0.lines.map { Self.inline($0) + "\n" }.joined() } ?? ""
    }

    func commandsLine() -> String {
        "commands (\(commands.count)): " + commands.prefix(40).map(Self.inline).joined(separator: " · ") + "\n"
    }

    func sectionLine(_ section: SceneSection, count: Int) -> String {
        let b = section.bounds
        let position = String(format: "%.2f,%.2f %.2f×%.2f", b.x, b.y, b.width, b.height)
        let vertical   = section.verticalScrollNote.map { " · \(Self.inline($0))" } ?? ""
        let horizontal = section.horizontalScrollNote.map { " · \(Self.inline($0))" } ?? ""
        return "Section: \(Self.inline(section.name)), position: \(position), \(count) elements\(vertical)\(horizontal)\n"
    }

    /// `## name @x,y wxh`, with the position and size in whole percent of the window.
    func compactSectionLine(_ section: SceneSection) -> String {
        let b = section.bounds
        let vertical   = section.verticalScrollNote.map { " · \(Self.inline($0))" } ?? ""
        let horizontal = section.horizontalScrollNote.map { " · \(Self.inline($0))" } ?? ""
        return Self.compactSectionLine(named: section.name,
            details: " @\(Self.percent(b.x)),\(Self.percent(b.y)) "
                + "\(Self.percent(b.width))x\(Self.percent(b.height))\(vertical)\(horizontal)")
    }

    /// The sole section heading syntax, including sections without geometry.
    static func compactSectionLine(named name: String, details: String = "") -> String {
        "## \(inline(name))\(inline(details))\n"
    }

    /// A value in 0...1 as the whole percent its two-decimal print used to show, so nothing rounds
    /// differently than before.
    static func percent(_ value: Double) -> Int {
        guard value.isFinite, let hundredths = Double(String(format: "%.2f", value)) else { return 0 }
        return Int((hundredths * 100).rounded())
    }

    /// `@x,y`: where an element is, in whole percent of the window.
    package static func place(_ bounds: NormalizedRect) -> String {
        "@\(percent(bounds.x)),\(percent(bounds.y))"
    }

    /// The one line of an element: its tag unless it is plain text, label, the id when a target needs
    /// it, state, live details, learned effect and place. `ownerNote` is the `{container}` text to
    /// print, or nil to print the element's own, which is what a line read on its own needs.
    static func elementLine(
        _ element: SceneElement,
        ownerNote: String? = nil,
        cuts: SceneTextCuts = []
    ) -> String {
        let field = AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")
        // A text line that could read as a tag or as another line keeps its tag.
        let plainText = element.kind == .text && !element.isUnlabeled && !field && !element.label.isEmpty
            && !readsAsStructure(element.label)
        let tag = plainText ? "" : field ? "[field]"
            : element.isUnlabeled ? "[\(element.kind.rawValue)?]" : "[\(element.kind.rawValue)]"
        let label = element.isUnlabeled && element.label == unlabeledLabel ? "" : Self.inline(element.label)
        let head = [tag, label].filter { !$0.isEmpty }.joined(separator: " ")
        let identity = element.isUnlabeled || field ? " id:'\(element.id)'" : ""
        let state    = element.state.map { " [\($0.rawValue)]" } ?? ""
        let owner    = ownerNote ?? element.container.map { " {\(Self.inline($0))}" } ?? ""
        let recalled = element.isRecalled ? " ~recalled" : ""
        let does     = element.does.map { ": \(Self.inline($0))" } ?? ""
        return "\(head)\(identity)\(state)\(compactDetails(element, cuts: cuts))\(owner)\(recalled)\(does) \(place(element.bounds))\n"
    }

    /// The label an element without a name carries; the line leaves it out, the `[icon?]` tag says it.
    static let unlabeledLabel = "(unlabeled)"

    /// True for an unlabeled icon that has nothing to print but its id and place, so it can share
    /// the `icons:` line. An id with a space could not be told apart there.
    private static func isPlainIcon(_ element: SceneElement) -> Bool {
        element.kind == .icon && element.isUnlabeled && element.label == unlabeledLabel
            && element.state == nil && element.value == nil && element.does == nil
            && element.isEnabled != false && element.container == nil && !element.isRecalled
            && !AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")
            && !element.id.isEmpty && !element.id.contains { $0.isWhitespace }
    }

    /// Groups plain icons by id. With shared-id cuts, only groups the resolver cannot reduce
    /// to one target disappear; reducible groups keep the original id and count.
    private func iconsLine(
        _ icons: [SceneElement],
        original: [SceneElement],
        cuts: SceneTextCuts
    ) -> String {
        // Collapse in the resolver's source order: overlap with the first facet is not transitive.
        let groups = Dictionary(grouping: original, by: \.id)
        var seen = Set<String>()
        var items: [String] = []
        for icon in icons where seen.insert(icon.id).inserted {
            let group = groups[icon.id] ?? []
            if cuts.contains(.sharedIconIDs), group.count > 1, Self.collapseSameRow(group).count > 1,
               case .ambiguous = resolve(target: icon.id) { continue }
            items.append(group.count == 1 ? icon.id + Self.place(icon.bounds) : "\(icon.id)×\(group.count)")
        }
        return items.isEmpty ? "" : "icons: " + items.joined(separator: " ") + "\n"
    }

    /// Value, selection and availability of an element, the compact way: `[sel a..b/n]`.
    private static func compactDetails(_ element: SceneElement, cuts: SceneTextCuts) -> String {
        if element.role == "AXSecureTextField" {
            return " secret" + (element.isEnabled == false ? " [disabled]" : "")
        }
        let value = element.value.flatMap { $0 == element.label ? nil : " = \(visibleValue($0))" } ?? ""
        let selection: String
        if let text = element.value, let range = SceneElement.validRange(element.selectedRange, value: text),
           !cuts.contains(.emptySelections) || range.length > 0 {
            selection = " [sel \(range.location)..\(range.location + range.length)/\(text.utf16.count)]"
        } else {
            selection = ""
        }
        return value + selection + (element.isEnabled == false ? " [disabled]" : "")
    }

    private static func liveDetails(_ element: SceneElement) -> String {
        if element.role == "AXSecureTextField" {
            return " secret" + (element.isEnabled == false ? " [disabled]" : "")
                + (element.container.map { " {\(Self.inline($0))}" } ?? "")
        }
        let value = element.value.flatMap { $0 == element.label ? nil : " = \(visibleValue($0))" } ?? ""
        let selection: String
        if let text = element.value, let range = SceneElement.validRange(element.selectedRange, value: text) {
            selection = " [selection UTF-16: \(range.location)..\(range.location + range.length) of \(text.utf16.count)]"
        } else {
            selection = ""
        }
        let availability = element.isEnabled == false ? " [disabled]" : ""
        let owner = element.container.map { " {\(Self.inline($0))}" } ?? ""
        return value + selection + availability + owner
    }

    /// Writes text read from an application on one scene line. Line and paragraph separators
    /// and control characters become spaces, so a fragment cannot start a line of its own.
    /// Values keep `visibleValue`.
    package static func inline(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { isInlineControl($0) ? " " : $0 }))
    }

    /// Whether a plain-text label could read as a structural line: such a label keeps its tag.
    /// This includes `[`, `#`, `+ `, `- `, `~ `, `icons:`, `commands` and `Unchanged since`.
    static func readsAsStructure(_ label: String) -> Bool {
        if label.unicodeScalars.contains(where: isInlineControl) { return true }
        let text = inline(label).trimmingCharacters(in: .whitespaces)
        return ["[", "#", "+ ", "- ", "~ ", "icons:", "commands", "Unchanged since"].contains {
            text.hasPrefix($0)
        }
    }

    private static func isInlineControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    /// Escapes whitespace without turning one native value into additional scene rows.
    private static func visibleValue(_ value: String) -> String {
        if value.isEmpty || value != value.trimmingCharacters(in: .whitespacesAndNewlines)
            || value.unicodeScalars.contains(where: isInlineControl) {
            return escapedValue(value)
        }
        return value
    }

    /// Keeps Swift's quoted value syntax, escaping separators it otherwise leaves literal.
    private static func escapedValue(_ value: String) -> String {
        String(reflecting: value).unicodeScalars.map { scalar in
            isInlineControl(scalar) ? "\\u{\(String(scalar.value, radix: 16))}" : String(scalar)
        }.joined()
    }

    /// Map order: stateful first, learned affordance second, any labeled control or icon third.
    private static func mapRank(_ element: SceneElement) -> Int {
        if element.state != nil { return 0 }
        if element.does != nil { return 1 }
        if (element.kind == .control || element.kind == .icon), !element.isUnlabeled { return 2 }
        return 3
    }
}

// Difference rows share the whole scene's syntax and protection at this rendering boundary.
extension SceneChanges {
    static func renderedChangeLines(
        from before: SceneSnapshot,
        to after: SceneSnapshot,
        cuts: SceneTextCuts
    ) -> [SceneSnapshot.TextLine] {
        typealias TextLine = SceneSnapshot.TextLine
        var header: [TextLine] = []
        if before.compactHeader(counting: false) != after.compactHeader(counting: false) {
            header.append(TextLine("window: " + after.compactHeader(counting: false), job: .header))
        }
        if before.viewportPixelSize != after.viewportPixelSize {
            header.append(TextLine("viewport: \(after.viewportPixelSize.width)x\(after.viewportPixelSize.height)\n", job: .header))
        }
        let knowledge = after.knowledgeText()
        if let status = after.knowledge?.status, status != .unavailable,
           knowledge != before.knowledgeText() {
            header.append(TextLine(knowledge.isEmpty ? "memory: no window operations in this state\n" : knowledge,
                                   source: .memory, job: .note))
        }
        let sectionsChanged = !sameLayout(before, after)
        let sectionNames = Set(after.sections.map(\.name))

        var reported: [Line] = []
        var matchedBefore = Set<Int>()
        var matchedAfter  = Set<Int>()
        for (old, new) in pairs(before.elements, after.elements) {
            matchedBefore.insert(old)
            matchedAfter.insert(new)
            let was = earlier(before.elements[old], after.elements[new], sections: sectionNames, cuts: cuts)
            guard !was.isEmpty else { continue }
            var shown = after.elements[new]
            shown.does = nil
            reported.append(Line(
                section: placed(after.elements[new].section, in: after),
                bounds : after.elements[new].bounds,
                text   : "~ " + line(shown, cuts: cuts) + "  (was " + was.joined(separator: ", ") + ")"
            ))
        }
        for (index, element) in after.elements.enumerated() where !matchedAfter.contains(index) {
            reported.append(Line(
                section: placed(element.section, in: after),
                bounds : element.bounds,
                text   : "+ " + line(element, cuts: cuts)
            ))
        }
        for (index, element) in before.elements.enumerated() where !matchedBefore.contains(index) {
            reported.append(Line(
                section: after.section(at: element.bounds.center)?.name,
                bounds : element.bounds,
                text   : "- " + short(element)
            ))
        }

        var body: [TextLine] = []
        let groups = Dictionary(grouping: reported, by: \.section)
        func append(_ lines: [Line]) {
            let ordered = SceneSnapshot.readingOrder(
                lines,
                rowTolerance: after.rowTolerance,
                bounds      : \.bounds,
                tieBreak    : \.text
            )
            body += ordered.map { TextLine($0.text + "\n", job: .change, section: $0.section) }
        }
        if after.sections.isEmpty {
            if sectionsChanged { body.append(TextLine(SceneSnapshot.compactSectionLine(named: SceneSnapshot.unsectioned), job: .section)) }
            append(groups[String?.none] ?? [])
        } else {
            for section in after.sectionsInReadingOrder {
                let lines = groups[section.name] ?? []
                guard sectionsChanged || !lines.isEmpty else { continue }
                body.append(TextLine(after.compactSectionLine(section), job: .section, section: section.name))
                append(lines)
            }
            if let loose = groups[String?.none], !loose.isEmpty {
                body.append(TextLine(SceneSnapshot.compactSectionLine(named: SceneSnapshot.unsectioned), job: .section))
                append(loose)
            }
        }
        if before.commands != after.commands {
            body.append(TextLine(after.commands.isEmpty ? "commands: none\n" : after.commandsLine(), job: .commands))
        }
        let fields = outOfViewChanges(from: before.outOfViewFields, to: after.outOfViewFields)
        if !fields.isEmpty {
            body.append(TextLine(SceneSnapshot.outOfViewHeading, source: .outOfView, job: .section,
                                 section: "past the window's edge"))
            body += fields.map { TextLine($0 + "\n", source: .outOfView, job: .change,
                                          section: "past the window's edge") }
        }
        return header + body
    }

    /// Read-only fields pair by their own label, role and container, with equal duplicates first.
    private static func outOfViewChanges(from before: [OutOfViewField], to after: [OutOfViewField]) -> [String] {
        var remaining = Set(after.indices)
        var unchanged = Set<Int>()
        for (index, old) in before.enumerated() {
            if let match = after.indices.first(where: { remaining.contains($0) && after[$0] == old }) {
                remaining.remove(match)
                unchanged.insert(index)
            }
        }
        var lines: [String] = []
        for (index, old) in before.enumerated() where !unchanged.contains(index) {
            let candidates = after.indices.filter {
                remaining.contains($0) && after[$0].role == old.role && after[$0].container == old.container
                    && LabelText.normalize(after[$0].label) == LabelText.normalize(old.label)
            }
            guard let index = candidates.first else {
                lines.append("- " + SceneSnapshot.outOfViewLine(old))
                continue
            }
            remaining.remove(index)
            let new = after[index]
            var was: [String] = []
            if old.value != new.value {
                was.append(String(reflecting: old.value.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if old.label != new.label { was.append("label " + String(reflecting: old.label)) }
            if (old.isEnabled == false) != (new.isEnabled == false) {
                was.append(old.isEnabled == false ? "[disabled]" : "enabled")
            }
            if !was.isEmpty {
                lines.append("~ " + SceneSnapshot.outOfViewLine(new) + "  (was " + was.joined(separator: ", ") + ")")
            }
        }
        for index in after.indices where remaining.contains(index) {
            lines.append("+ " + SceneSnapshot.outOfViewLine(after[index]))
        }
        return lines
    }

    /// One reported element: the section it is listed under, nil for none, and where it is.
    private struct Line {
        let section: String?
        let bounds: NormalizedRect
        let text: String
    }

    /// The earlier values of everything the reader sees or targets differently in `new`, in line
    /// order, then its section; empty when it is the same element in the same place. A group tag is
    /// left out, since no target names it, and so is a section no longer among `sections`: a renamed
    /// or redrawn panel is reported once, in its own line.
    static func earlier(
        _ old: SceneElement,
        _ new: SceneElement,
        sections: Set<String>,
        cuts: SceneTextCuts = []
    ) -> [String] {
        var was: [String] = []
        if tag(old) != tag(new) { was.append("[\(tag(old))]") }
        if old.label != new.label { was.append("label \(String(reflecting: old.label))") }
        if shownID(old) != shownID(new) { was.append(shownID(old).map { "id:'\($0)'" } ?? "no id") }
        if old.state != new.state { was.append(old.state.map { "[\($0.rawValue)]" } ?? "no state") }
        if shownValue(old) != shownValue(new) {
            was.append(shownValue(old).map { "= \(String(reflecting: $0))" } ?? "no value")
        }
        func selection(_ element: SceneElement) -> NSRange? {
            guard let range = SceneElement.validRange(element.selectedRange, value: element.value),
                  !cuts.contains(.emptySelections) || range.length > 0 else { return nil }
            return range
        }
        let oldRange = selection(old)
        if oldRange != selection(new) {
            was.append(oldRange.map { "selection \($0.location)..\($0.location + $0.length)" } ?? "no selection")
        }
        if (old.isEnabled == false) != (new.isEnabled == false) {
            was.append(old.isEnabled == false ? "[disabled]" : "enabled")
        }
        if old.container != new.container { was.append(old.container.map { "{\(SceneSnapshot.inline($0))}" } ?? "no container") }
        if abs(old.bounds.midX - new.bounds.midX) > nearby || abs(old.bounds.midY - new.bounds.midY) > nearby {
            was.append(SceneSnapshot.place(old.bounds))
        }
        if let section = old.section, section != new.section, sections.contains(section) {
            was.append("in \(SceneSnapshot.inline(section))")
        }
        return was
    }

    /// `text()`'s line for one element, without its indent and line break.
    private static func line(_ element: SceneElement, cuts: SceneTextCuts) -> String {
        String(SceneSnapshot.elementLine(element, cuts: cuts).dropLast())
    }

    /// A removed element as the reader can still tell it apart: its tag, label, shown id and place.
    private static func short(_ element: SceneElement) -> String {
        let identity = shownID(element).map { " id:'\($0)'" } ?? ""
        let label = element.isUnlabeled && element.label == SceneSnapshot.unlabeledLabel ? "" : " " + SceneSnapshot.inline(element.label)
        return "[\(tag(element))]\(label)\(identity) \(SceneSnapshot.place(element.bounds))"
    }

    /// The tag `text()` prints: `field` for text entry, a kind with `?` when unlabeled, else the kind.
    private static func tag(_ element: SceneElement) -> String {
        if AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "") { return "field" }
        return element.isUnlabeled ? "\(element.kind.rawValue)?" : element.kind.rawValue
    }

    /// The id `text()` prints, which a target can name: an unlabeled element's or a field's.
    private static func shownID(_ element: SceneElement) -> String? {
        element.isUnlabeled || tag(element) == "field" ? element.id : nil
    }

    /// The value `text()` prints: none when it repeats the label.
    private static func shownValue(_ element: SceneElement) -> String? {
        element.value == element.label ? nil : element.value
    }

}

extension SceneSnapshot {
    static func unchangedLine(since revision: Int) -> String {
        "Unchanged since revision \(revision)."
    }
}
