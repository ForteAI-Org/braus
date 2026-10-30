//
//  InteractionStructuralReader.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation

/// InteractionStructuralReader reads collections whole (rows, or children of any role) in batches up to 2,000 members
/// in one 150 ms time box, through the semantic probe's reader; nodes another process owns are read when they answer.
/// A collection's members that are collections themselves (sections) are read as collections of their own.
/// The box is spent in priority order: collections as they are found, each with at most half of what the walk has
/// left; field values last, the focused field and its neighbours first; what the box left unread is counted.
enum InteractionStructuralReader {
    static let memberCap = 2_000
    static let batch = 200
    static let elementBudget = 4_000
    static let depthLimit = 40
    static let fieldCap = 512
    /// The share of the box the walk may use; field values get the rest.
    static let walkShare = 0.85
    static let lists: [String: (members: String, visible: String)] = [
        "AXTable": ("AXRows", "AXVisibleRows"), "AXOutline": ("AXRows", "AXVisibleRows"),
        "AXList": ("AXChildren", "AXVisibleChildren"), "AXGrid": ("AXChildren", "AXVisibleChildren"),
        "AXBrowser": ("AXChildren", "AXVisibleChildren")
    ]
    /// Controls whose value a person sets: text, a pop-up's choice, a level (read as a number).
    static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXPopUpButton",
                                          "AXSlider", "AXIncrementor"]

    static func capture<R: InteractionSemanticReading>(
        reader: R, application: R.Node, processID: Int32, windows scope: Set<Int>, seconds: Double = 0.15,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        hostName: (Int32) -> String? = { _ in nil }, isReserved: (String) -> Bool = { _ in false }
    ) -> InteractionStructuralRead {
        let start = now()
        let deadline = start + seconds
        let walkDeadline = start + seconds * walkShare
        // A long read (when control passes, at hand-back) reads a heavy window whole: its budgets grow with its box.
        let long = seconds > 0.5
        let elements = long ? elementBudget * 5 : elementBudget
        let fields = long ? fieldCap * 8 : fieldCap
        func string(_ value: InteractionSemanticProbe.Value<R.Node>) -> String? {
            guard case .string(let text) = value, !text.isEmpty else { return nil }
            return text
        }
        func guarded(_ text: String?) -> String? { text.flatMap { isReserved($0) ? nil : $0 } }
        var result = InteractionStructuralRead(processID: processID, interval: .init(start: start, end: start))
        guard case .nodes(let windows, _) = reader.read(application, "AXWindows", limit: 64) else {
            result.unread = scope.sorted()
            result.interval = .init(start: start, end: now())
            return result
        }
        // The focused element and its parent put the fields beside it first.
        var focus: R.Node?
        var focusParent: R.Node?
        if case .node(let node) = reader.read(application, "AXFocusedUIElement", limit: 1) {
            focus = node
            if case .node(let parent) = reader.read(node, "AXParent", limit: 1) { focusParent = parent }
        }
        // The focus itself first, then a field inside it, then one beside it under the same parent, then the rest.
        func rank(_ node: R.Node, _ parent: R.Node?) -> Int {
            guard let focus else { return 3 }
            if reader.same(focus, node) { return 0 }
            guard let parent else { return 3 }
            return reader.same(parent, focus) ? 1 : focusParent.map { reader.same($0, parent) } == true ? 2 : 3
        }
        var reached = Set<Int>()
        for node in windows {
            guard now() < deadline else { break }
            guard case .integer(let number) = reader.read(node, "windowNumber", limit: 1) else { continue }
            guard scope.isEmpty || scope.contains(number) else { continue }
            reached.insert(number)
            var window = InteractionStructuralRead.Window(number: number, title: guarded(string(reader.read(node, "AXTitle", limit: 1))))
            var found: [(node: R.Node, parent: R.Node?, role: String, name: String?, identifier: String?, path: [String])] = []
            // Each element carries the names of its named ancestors below the window: a field's container.
            var queue: [(node: R.Node, depth: Int, parent: R.Node?, path: [String])] = [(node, 0, nil, [])]
            var position = 0
            // Collections their share cut short, by index in the window's collections, for the time the walk leaves.
            var cut: [(index: Int, node: R.Node, role: String, list: (members: String, visible: String))] = []
            while position < queue.count {
                // A cancelled read (input arrived during a pause's read) stops at once and leaves the app to the next one.
                guard now() < walkDeadline, !Task.isCancelled else { window.quality.deadline = true; break }
                guard window.elements < elements else { window.quality.elementBudget = true; break }
                let (current, depth, parent, path) = queue[position]
                position += 1
                window.elements += 1
                let answers = reader.values(current, ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXIdentifier"])
                let role = string(answers[0])
                // Content another process hosts: read with the window when it answers, else an unobserved region.
                if let owner = reader.owner(current), owner != processID {
                    let named = guarded(string(answers[2]) ?? string(answers[3]))
                    if !window.hosted.contains(where: { $0.processID == owner }) {
                        window.hosted.append(.init(processID: owner, host: hostName(owner), role: role, name: named, read: role != nil))
                    }
                    if role == nil { continue }
                }
                if let role, let list = lists[role] {
                    // One collection never takes more than half of what the walk has left, so the rest of the window is read.
                    let share = min(walkDeadline, now() + (walkDeadline - now()) / 2)
                    let (read, sections) = collection(reader, current, role: role, list: list,
                                                      name: guarded(string(answers[2]) ?? string(answers[3])),
                                                      identifier: string(answers[4]), deadline: share, now: now,
                                                      quality: &window.quality, guarded: guarded)
                    window.collections.append(read)
                    if case .range = read.coverage { cut.append((window.collections.count - 1, current, role, list)) }
                    // Members that are collections themselves (an icon view grouped into sections) are read next.
                    queue.insert(contentsOf: sections.map { ($0, depth + 1, current, path) }, at: position)
                    continue
                }
                let name = guarded(string(answers[2]) ?? string(answers[3]))
                if let role, fieldRoles.contains(role), string(answers[1]) != "AXSecureTextField", found.count < fields {
                    found.append((current, parent, role, name, string(answers[4]), path))
                }
                guard depth < depthLimit else { window.quality.depth = true; continue }
                if case .nodes(let children, _) = reader.read(current, "AXChildren", limit: 256) {
                    let inner = depth > 0 ? path + [name].compactMap { $0 } : path
                    queue += children.map { ($0, depth + 1, current, inner) }
                }
            }
            // The time the walk did not need goes back to the collections their share cut short, in the order found
            // (a note list: a fourth of its rows read, and half the box left unused).
            for item in cut where now() < walkDeadline {
                var collection = window.collections[item.index]
                let (more, _) = Self.collection(reader, item.node, role: item.role, list: item.list, name: collection.name,
                                                identifier: collection.identifier, deadline: walkDeadline, now: now,
                                                quality: &window.quality, guarded: guarded, from: collection.members.count)
                collection.members += more.members
                collection.coverage = more.coverage
                window.collections[item.index] = collection
            }
            // Field values last, the focused field and its neighbours first, each kept in reading order.
            let ranks = found.map { rank($0.node, $0.parent) }
            let ordered = found.indices.sorted { (ranks[$0], $0) < (ranks[$1], $1) }
            for index in ordered {
                guard now() < deadline else { break }
                let field = found[index]
                let level = InteractionSemanticSnapshot.levelRoles.contains(field.role)
                var value = string(reader.read(field.node, level ? "AXLevel" : "AXValue", limit: 1))
                if level, value == nil { value = thumbLevel(reader, field.node) }
                window.fields.append(.init(role: field.role, name: field.name, identifier: field.identifier,
                                           value: guarded(value),
                                           container: field.path.isEmpty ? nil : field.path.suffix(2).joined(separator: " / ")))
            }
            if window.fields.count < found.count { window.quality.skippedFields = found.count - window.fields.count }
            result.windows.append(window)
        }
        result.unread = scope.subtracting(reached).sorted()
        result.interval = .init(start: start, end: now())
        return result
    }

    /// One collection: its count, then members in batches until the count, the cap or the deadline; with the members
    /// that are collections themselves (sections), for the walk to read in turn. `start` resumes a collection a
    /// deadline cut short: only members from that index are returned, the coverage counts the earlier ones.
    private static func collection<R: InteractionSemanticReading>(
        _ reader: R, _ node: R.Node, role: String, list: (members: String, visible: String), name: String?,
        identifier: String?, deadline: Double, now: () -> Double, quality: inout InteractionStructuralRead.Quality,
        guarded: (String?) -> String?, from start: Int = 0
    ) -> (InteractionStructuralRead.Collection, sections: [R.Node]) {
        func string(_ value: InteractionSemanticProbe.Value<R.Node>) -> String? {
            guard case .string(let text) = value, !text.isEmpty else { return nil }
            return text
        }
        let count = reader.count(node, list.members)
        var nodes: [R.Node] = []
        var members: [InteractionStructuralRead.Member] = []
        // An application that exposes no count is read by what it shows: its viewport.
        let total = min(count ?? 0, memberCap)
        while nodes.count < total, now() < deadline {
            guard case .nodes(let batch, _) = reader.read(node, list.members, from: nodes.count, limit: min(batch, total - nodes.count)),
                  !batch.isEmpty else { quality.unanswered += 1; break }
            nodes += batch
        }
        var visible: [R.Node] = []
        if case .nodes(let shown, _) = reader.read(node, list.visible, limit: 512) { visible = shown }
        let viewport = count == nil
        if viewport { nodes = visible }
        var misses = 0, hits = 0
        var sections: [R.Node] = []
        for (index, member) in nodes.enumerated() where index >= start {
            guard now() < deadline else { quality.deadline = true; break }
            let answers = reader.values(member, ["AXRole", "AXTitle", "AXDescription", "AXIdentifier", "AXFilename", "AXURL", "AXSelected"])
            var name = string(answers[1]) ?? string(answers[2])
            let document = string(answers[4]) ?? string(answers[5])
            // A section is named only by itself: its first child is one of its members, not its name.
            let section = lists[string(answers[0]) ?? ""] != nil
            if section { sections.append(member) }
            // A row names itself in its first cell: that cell's text, or the text its children show first in reading
            // order, a level deeper when a child is a view holding the texts. Members that never name themselves so
            // are read without names, to spare the box.
            if name == nil, document == nil, !section, misses < 5 || hits > 0,
               case .nodes(let cells, _) = reader.read(member, "AXChildren", limit: 1), let cell = cells.first {
                name = reader.values(cell, ["AXValue", "AXTitle", "AXDescription"]).lazy.compactMap(string).first
                    ?? firstText(reader, under: cell, depth: 1, string: string)
                if name == nil { misses += 1 } else { hits += 1 }
            }
            var selected: Bool?
            if case .bool(let flag) = answers[6] { selected = flag }
            members.append(.init(index: index, name: guarded(name), identifier: string(answers[3]),
                                 document: guarded(document), role: string(answers[0]), selected: selected))
        }
        let read = start + members.count
        let coverage: InteractionStructuralRead.Coverage = viewport ? .viewport
            : read == count ? .complete
            : read == 0 ? .viewport : .range(first: 0, last: read - 1)
        let shown = visible.compactMap { item in nodes.firstIndex { reader.same($0, item) } }
        return (.init(role: role, name: name, identifier: identifier, count: count, members: members,
                      coverage: coverage, visible: shown), sections)
    }

    /// The level of a slider that exposes no value, from where its thumb (`AXValueIndicator`) sits along its track: 0
    /// at the start (left, or bottom when vertical), 1 at the end, to two decimals; nil without a thumb or a frame.
    /// System Settings' brightness answers "no value" for AXValue, AXMinValue and AXMaxValue, and shows only its thumb.
    private static func thumbLevel<R: InteractionSemanticReading>(_ reader: R, _ node: R.Node) -> String? {
        let frame = ["AXPositionX", "AXPositionY", "AXSizeWidth", "AXSizeHeight"]
        func numbers(_ values: [InteractionSemanticProbe.Value<R.Node>]) -> [Double]? {
            let found = values.compactMap { value -> Double? in
                if case .integer(let number) = value { return Double(number) }
                return nil
            }
            return found.count == values.count ? found : nil
        }
        let answers = reader.values(node, frame + ["AXOrientation"])
        guard let track = numbers(Array(answers.prefix(4))),
              case .nodes(let children, _) = reader.read(node, "AXChildren", limit: 8) else { return nil }
        let vertical: Bool
        if case .string("AXVerticalOrientation") = answers[4] { vertical = true } else { vertical = false }
        for child in children {
            let parts = reader.values(child, ["AXRole"] + frame)
            guard case .string("AXValueIndicator") = parts[0], let thumb = numbers(Array(parts.dropFirst())) else { continue }
            let span = vertical ? track[3] - thumb[3] : track[2] - thumb[2]
            guard span > 0 else { return nil }
            let offset = vertical ? track[1] + track[3] - thumb[1] - thumb[3] : thumb[0] - track[0]
            let level = (min(1, max(0, offset / span)) * 100).rounded() / 100
            return level == level.rounded() ? String(Int(level)) : String(level)
        }
        return nil
    }

    /// The text `node`'s children show first in reading order, top then left, `depth` levels deeper where a child
    /// shows none (a cell view holding a title, a time and a preview). The tree's order is not the reading order: a
    /// note's row lists its preview and time before the title drawn above them (Notes). A text with a letter wins, so
    /// a time or a count never names the row; texts without a position follow, in the tree's order.
    private static func firstText<R: InteractionSemanticReading>(
        _ reader: R, under node: R.Node, depth: Int, string: (InteractionSemanticProbe.Value<R.Node>) -> String?
    ) -> String? {
        var texts: [(text: String, y: Int, x: Int)] = []
        func collect(_ node: R.Node, depth: Int) {
            guard case .nodes(let children, _) = reader.read(node, "AXChildren", limit: 8) else { return }
            for child in children {
                // Eager on purpose: a lazy compactMap runs its transform twice, and a live accessibility value can
                // vanish between the two reads, which traps on the second.
                let answers = reader.values(child, ["AXValue", "AXTitle", "AXPositionY", "AXPositionX"])
                guard let text = answers.prefix(2).compactMap(string).first else {
                    if depth > 0 { collect(child, depth: depth - 1) }
                    continue
                }
                func point(_ value: InteractionSemanticProbe.Value<R.Node>) -> Int {
                    if case .integer(let number) = value { return number }
                    return .max
                }
                texts.append((text, point(answers[2]), point(answers[3])))
            }
        }
        collect(node, depth: depth)
        let lettered = texts.filter { $0.text.contains(where: \.isLetter) }
        // The tree's order breaks ties: texts at one position, or without one.
        let ordered = (lettered.isEmpty ? texts : lettered).enumerated()
            .min { ($0.element.y, $0.element.x, $0.offset) < ($1.element.y, $1.element.x, $1.offset) }
        return ordered?.element.text
    }
}
