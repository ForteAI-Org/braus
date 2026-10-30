//
//  HumanInterventionEffects.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore

/// HumanInterventionEffects is the ledger of what the reads show changed: each read against the previous read of its
/// window (steps) and each window's first read against its last (net). Its net effects are the report's only facts.
nonisolated struct HumanInterventionEffects: Sendable {
    enum Kind: String, Sendable {
        case appeared, disappeared, renamed, value, state, enabled, moved, resorted, title
    }

    /// One read: -1 is the initial read, then one per finding by its position, then the final read.
    struct Read: Sendable {
        let index: Int
        let sequence: UInt64
        let actions: [Int]
        let overlapped: Bool
    }

    struct Change: Sendable {
        let window: Int
        let kind: Kind
        let subject: String
        let role: String?
        let container: String?
        /// The collection member the element belongs to; nil outside any collection.
        let member: String?
        let before: String?
        let after: String?
        let from: Int
        let to: Int
        /// The name a person sees: an identifier label goes by the first line the element shows.
        var name: String = ""
        var fromOrdinal: Int? = nil
        var toOrdinal: Int? = nil
        /// For an order: whether the collection is a list (native rows), not a layout group.
        var list = false
        /// A name that changed only in the count beside it: the member's count, a value, not a rename.
        var count = false
        /// The name came from the collection member that shows the element, not from the element itself.
        var owned = false
    }

    /// A net effect as the report states it: what changed, never which action did it.
    struct Effect: Sendable {
        enum Kind: String, Sendable { case created, deleted, renamed, moved, resorted, edited, value, state, title }
        let window: Int
        let kind: Kind
        /// The member created, deleted or moved, the new name, the control, the collection or "Window title".
        var label: String
        var before: String?
        /// The new value or name; for a move, the member it now follows.
        var after: String?
        /// The member owning an edited field.
        var member: String?
        var collection: String?
        var role: String?
        /// The commands (thread roots) attribution keeps as possible causes; empty means cause unknown.
        var causes: Set<Int> = []
        /// The actions the reads where this effect was observed cover: the time gate of attribution.
        var actions: Set<Int> = []
        var overlapped = false
        /// A created member whose name a member removed earlier in the episode had.
        var recreated = false
        /// The count beside a member's name, which follows other effects: details only.
        var count = false
        /// The change concerns a collection as a whole (its sections), which no member names.
        var whole = false
    }

    /// What became of one net change: stated by an effect, intermediate, or interface noise counted in details.
    enum Disposition: Sendable, Equatable {
        case effect(Int)
        case intermediate
        case noise(String)
    }

    private(set) var reads: [Read] = []
    private(set) var stepChanges: [Change] = []
    private(set) var netChanges: [Change] = []
    /// Net effects for the body, in ledger order: interpreted first, then those no interpretation explained.
    private(set) var effects: [Effect] = []
    /// Effects that did not survive to the end, for details only.
    private(set) var intermediate: [Effect] = []
    private(set) var dispositions: [Disposition] = []
    /// What each read's steps observed, by read sequence, for details.
    private(set) var observed: [UInt64: [String]] = [:]
    /// Normalized texts each window shows in its first and last read: names, values, container parts, title.
    private var shown: [Int: (first: Set<String>, last: Set<String>)] = [:]
    /// Each window's last read: displayed names to their values and states.
    private var finalValues: [Int: [String: Set<String>]] = [:]
    /// Each window's last read: the names its elements show, without counts.
    private var finalNames: [Int: Set<String>] = [:]
    /// Every text each window showed in any read, pixel text included: wording evidence, never identity.
    private var everShown: [Int: Set<String>] = [:]
    private var transient = Set<Int>()
    /// Structural reads (archive version 3) by read index and window.
    private var structures: [Int: [Int: InteractionStructuralRead.Window]] = [:]
    /// Content another process hosts that did not answer, by window and host: unobserved regions.
    private(set) var unobservedRegions: [(window: Int, host: String)] = []
    /// Windows a structural read had in scope but never reached.
    private(set) var unreadWindows = Set<Int>()
    /// Windows the person typed into and did not cancel: in-place editors when they hold one field.
    private var editors = Set<Int>()

    init() {}

    /// `scenes` holds every read in time order, its windows already named as the engine names them; `actions` are
    /// the recorded actions the reads' indexes point at, for telling a live readout from a value a person set.
    init(structures: [Int: [Int: InteractionStructuralRead.Window]] = [:], unread: Set<Int> = [], editors: Set<Int> = [],
         actions: [HumanRecordedInteraction.SummaryAction] = [], reads: [(read: Read, scenes: [Int: SceneSnapshot])]) {
        self.reads = reads.map(\.read)
        self.structures = structures
        self.editors = editors
        unreadWindows = unread.subtracting(structures.values.flatMap(\.keys))
        var previous: [Int: (index: Int, scene: SceneSnapshot)] = [:]
        var first: [Int: (index: Int, scene: SceneSnapshot)] = [:]
        // A window read before its title was drawn goes by the first title it showed.
        var firstTitle: [Int: String] = [:]
        for (read, scenes) in reads {
            for window in scenes.keys.sorted() {
                guard let scene = scenes[window] else { continue }
                if HumanInterventionScene.isTransient(scene) { transient.insert(window) }
                if firstTitle[window] == nil, !scene.windowTitle.isEmpty, !HumanInterventionScene.isTransient(scene) {
                    firstTitle[window] = scene.windowTitle
                }
                everShown[window, default: []].formUnion(Self.names(scene))
                if let earlier = previous[window] {
                    let changes = Self.changes(earlier.scene, scene, window: window, from: earlier.index, to: read.index)
                    classifyValues(changes, in: scene, read: read, actions: actions)
                    stepChanges += changes
                } else { first[window] = (read.index, scene) }
                previous[window] = (read.index, scene)
            }
        }
        for window in first.keys.sorted() {
            guard let start = first[window], let end = previous[window] else { continue }
            shown[window] = (Self.texts(start.scene), Self.texts(end.scene))
            finalValues[window] = Dictionary(end.scene.elements.map {
                (Self.key(HumanInterventionScene.name($0)), Set([$0.value, $0.state?.rawValue].compactMap { $0 }.map(Self.key)))
            }, uniquingKeysWith: { $0.union($1) })
            finalNames[window] = Set(end.scene.elements.filter { $0.role != nil }.map { Self.key(HumanInterventionIdentity.countBase($0.label)) })
            guard start.index != end.index else { continue }
            var changes = Self.changes(start.scene, end.scene, window: window, from: start.index, to: end.index)
            if start.scene.windowTitle.isEmpty, let title = firstTitle[window], title != end.scene.windowTitle {
                changes.removeAll { $0.kind == .title }
                changes.append(Change(window: window, kind: .title, subject: "Window title", role: nil, container: nil,
                                      member: nil, before: title, after: end.scene.windowTitle, from: start.index,
                                      to: end.index, name: "Window title"))
            }
            netChanges += changes
        }
    }


    /// Values that moved while no input of their read could move them, by "window|label", and values a person set
    /// directly; a readout is the first and never the second.
    private var autonomous = Set<String>()
    private var edited = Set<String>()
    /// The value a person left in a field they typed into, by "window|label": what they set, though the application
    /// may show something else later (an address bar's page address after its search).
    private var editedValue: [String: String] = [:]
    /// Whether each value's latest change came in a read with no input but scrolling: an application's own update.
    private var settledAlone: [String: Bool] = [:]

    /// Live readouts, decided by evidence. A value is set by the person when its read had input that could set it (a
    /// key, or a press on a named control: not the window, a scroll bar or the menu bar), the element is not a display
    /// role showing a number, and, for a number, the person was not typing into another field the read shows. Any other
    /// value change, or one in a read with no input but scrolling, is a readout; an action on the element itself (its
    /// label and role, by typing, dragging, clicking or a key in it) makes it a value the person set.
    private mutating func classifyValues(_ changes: [Change], in scene: SceneSnapshot, read: Read,
                                         actions: [HumanRecordedInteraction.SummaryAction]) {
        let inputs = read.actions.filter(actions.indices.contains).map { actions[$0] }
        let moved = inputs.contains { ![.scroll, .hover, .focus, .gap].contains($0.kind) }
        let covering = inputs.contains { input in
            switch input.kind {
            case .typing, .shortcut: return true
            case .click, .drag:
                return input.label != nil && input.role != nil
                    && !["AXWindow", "AXScrollArea", "AXScrollBar", "AXMenuBar"].contains(input.role ?? "")
            default: return false
            }
        }
        let fields = Set(inputs.filter(\.isField).compactMap(\.label))
        let addressed = scene.elements.contains { fields.contains($0.label) }
        for change in changes where [.value, .appeared].contains(change.kind) {
            let key = "\(change.window)|\(change.subject)"
            let element = scene.elements.first { $0.label == change.subject && $0.role == change.role }
            let direct = inputs.contains { action in
                action.label == change.subject && action.role == change.role
                    && (action.kind == .typing || action.kind == .drag || action.kind == .click
                        || (action.isField && action.kind == .shortcut))
            }
            if direct {
                edited.insert(key)
                if let value = change.kind == .value ? change.after : element?.value, !value.isEmpty { editedValue[key] = value }
                continue
            }
            guard change.kind == .value, let after = change.after, change.before != nil else { continue }
            settledAlone[key] = !moved && !read.overlapped
            // Otherwise a readout shows a number, or a control the person cannot set.
            let numeric = HumanInterventionChanges.isNumeric(after)
            guard numeric || element?.isEnabled == false else { continue }
            let relevant = covering && !addressed
                && element.map { HumanInterventionChanges.isRelevant($0) && HumanInterventionChanges.hasRelevantValue($0) } == true
            if !relevant || element?.isEnabled == false || !moved && !read.overlapped { autonomous.insert(key) }
        }
    }

    /// Every element change between two reads of one window, its title, and the order of each collection.
    static func changes(_ old: SceneSnapshot, _ new: SceneSnapshot, window: Int, from: Int, to: Int) -> [Change] {
        let rows = Set((old.elements + new.elements).filter { $0.role == "AXRow" }.map(\.label))
        // Row texts name identifier-labelled controls; most reads have none, so they are read only when needed.
        var rowTexts: [[String: [String: Set<String>]]]?
        func texts() -> [[String: [String: Set<String>]]] {
            if let rowTexts { return rowTexts }
            let value = [HumanInterventionScene.rowTexts(old), HumanInterventionScene.rowTexts(new)]
            rowTexts = value
            return value
        }
        var result: [Change] = []
        func add(_ kind: Kind, _ element: PerceptionCore.SceneElement, _ before: String?, _ after: String?,
                 _ fromOrdinal: Int?, _ toOrdinal: Int?) {
            let owner = HumanInterventionScene.isIdentifier(element.label) ? owner(of: element, texts: texts()) : nil
            result.append(Change(window: window, kind: kind, subject: element.label, role: element.role,
                                 container: element.container, member: member(element, rows: rows),
                                 before: before, after: after, from: from, to: to,
                                 name: owner ?? HumanInterventionScene.name(element),
                                 fromOrdinal: fromOrdinal, toOrdinal: toOrdinal, owned: owner != nil))
        }
        for match in HumanInterventionIdentity.match(old.elements, new.elements) {
            switch (match.before, match.after) {
            case (nil, let index?): add(.appeared, new.elements[index], nil, nil, nil, index)
            case (let index?, nil): add(.disappeared, old.elements[index], nil, nil, index, nil)
            case (let i?, let j?):
                let a = old.elements[i], b = new.elements[j]
                if a.label != b.label {
                    add(.renamed, b, a.label, b.label, i, j)
                    if HumanInterventionIdentity.countBase(a.label) == HumanInterventionIdentity.countBase(b.label) {
                        result[result.count - 1].count = true
                        result[result.count - 1].name = HumanInterventionIdentity.countBase(b.label)
                    }
                }
                if a.value != b.value { add(.value, b, a.value, b.value, i, j) }
                if a.state != b.state { add(.state, b, a.state?.rawValue, b.state?.rawValue, i, j) }
                if a.isEnabled != b.isEnabled { add(.enabled, b, a.isEnabled.map(String.init), b.isEnabled.map(String.init), i, j) }
            default: break
            }
        }
        if old.windowTitle != new.windowTitle {
            result.append(Change(window: window, kind: .title, subject: "Window title", role: nil, container: nil,
                                 member: nil, before: old.windowTitle, after: new.windowTitle, from: from, to: to,
                                 name: "Window title"))
        }
        let before = HumanInterventionScene.members(old), after = HumanInterventionScene.members(new)
        let lists = Set((old.elements + new.elements).filter { $0.role == "AXRow" }.compactMap(\.container))
        for collection in before.keys.sorted() {
            guard let current = after[collection] else { continue }
            let moved = HumanInterventionScene.reordered(old: before[collection] ?? [], new: current)
            // Three or more members out of order at once is the collection re-sorted: one change.
            if moved.count >= 3 {
                result.append(Change(window: window, kind: .resorted, subject: "\(moved.count) members", role: nil,
                                     container: collection, member: nil, before: nil, after: nil, from: from, to: to,
                                     name: collection, list: lists.contains(collection)))
                continue
            }
            for name in moved {
                let position = current.firstIndex(of: name) ?? 0
                result.append(Change(window: window, kind: .moved, subject: name, role: nil, container: collection,
                                     member: name, before: nil, after: position > 0 ? current[position - 1] : nil,
                                     from: from, to: to, name: name, list: lists.contains(collection)))
            }
        }
        return result
    }

    /// A control labelled only by an identifier goes by the collection member that shows its first line, as a note's
    /// text goes by its row; several members that show it leave it unnamed, unless one is named by that line.
    static func owner(of element: PerceptionCore.SceneElement, texts: [[String: [String: Set<String>]]]) -> String? {
        guard HumanInterventionScene.isIdentifier(element.label),
              let line = element.value?.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !line.isEmpty else { return nil }
        let names = Set(texts.flatMap { $0.values.flatMap { $0.filter { $0.value.contains(line) }.map(\.key) } })
        // Two members may show the same line (two notes with one title); the one named by it is the name.
        return names.count == 1 ? names.first : names.contains(line) ? line : nil
    }

    /// The member an element belongs to: a row is its own member; inside a collection, the row its path starts
    /// with, else the last part of its path.
    static func member(_ element: PerceptionCore.SceneElement, rows: Set<String>) -> String? {
        if element.role == "AXRow" { return element.label }
        guard let container = element.container else { return nil }
        if let head = container.components(separatedBy: " / ").first, rows.contains(head) { return head }
        return container.range(of: " / ", options: .backwards).map { String(container[$0.upperBound...]) }
    }

    private static func key(_ text: String) -> String { HumanInterventionIdentity.normalized(text) }

    /// The count a label shows beside its name: "71 notes" of "All iCloud, 71 notes".
    private static func countOf(_ label: String) -> String {
        let base = HumanInterventionIdentity.countBase(label)
        return String(label.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
    }

    /// The names a read shows: labels and container parts, without values.
    private static func names(_ scene: SceneSnapshot) -> Set<String> {
        var result = Set<String>()
        var containers = Set<String>()
        for element in scene.elements {
            result.insert(key(element.label))
            if let container = element.container { containers.insert(container) }
        }
        for container in containers { for part in container.components(separatedBy: " / ") { result.insert(key(part)) } }
        return result
    }

    private static func texts(_ scene: SceneSnapshot) -> Set<String> {
        var result = Set([key(scene.windowTitle)])
        for element in scene.elements {
            result.insert(key(element.label))
            for line in (element.value ?? "").split(whereSeparator: \.isNewline) { result.insert(key(String(line))) }
            for part in (element.container ?? "").components(separatedBy: " / ") { result.insert(key(part)) }
        }
        result.remove("")
        return result
    }

    // MARK: - Net effects

    /// Turns the ledger into net effects: every net change of a persisting element that is not interface noise is an
    /// effect; what structural reads certify (members in and out, renames, orders, groups, levels) joins them.
    /// `dialogs` are windows whose default or cancel button was used.
    mutating func resolve(dialogs: Set<Int>) {
        let transient = transient.union(dialogs)
        let sequence = Dictionary(uniqueKeysWithValues: reads.map { ($0.index, $0.sequence) })
        // Effects keep the order the changes were first seen in: the person's order, not the scene's.
        let firstSeen = Dictionary(stepChanges.map { ("\($0.window)|\($0.subject)", $0.to) }, uniquingKeysWith: min)
        netChanges = netChanges.enumerated().sorted { lhs, rhs in
            let a = firstSeen["\(lhs.element.window)|\(lhs.element.subject)"] ?? Int.max
            let b = firstSeen["\(rhs.element.window)|\(rhs.element.subject)"] ?? Int.max
            return (a, lhs.offset) < (b, rhs.offset)
        }.map(\.element)
        for change in netChanges {
            let key = "\(change.window)|\(change.subject)"
            // A field the person typed into that appeared during the session holds what they wrote: empty before it.
            if change.kind == .appeared, let value = editedValue[key] {
                dispositions.append(.effect(effects.count))
                effects.append(Effect(window: change.window, kind: .value, label: change.name, before: "", after: value,
                                      collection: change.container, role: change.role))
                continue
            }
            if let reason = noise(change, transient: transient, readout: isReadout(change)) {
                dispositions.append(.noise(reason))
                continue
            }
            var effect = Self.effect(change)
            // What the person left in a field they typed into, though the application shows something else later.
            if change.kind == .value, let value = editedValue[key], value != effect.after {
                if value == effect.before { dispositions.append(.intermediate); intermediate.append(effect); continue }
                effect.after = value
            }
            if effect.kind == .resorted,
               let same = effects.firstIndex(where: { $0.kind == .resorted && $0.window == effect.window && $0.label == effect.label }) {
                dispositions.append(.effect(same))
                continue
            }
            // A count beside a member's name follows other effects: details only.
            if change.count {
                effect = Effect(window: change.window, kind: .value, label: change.name,
                                before: change.before.map(Self.countOf), after: change.after.map(Self.countOf),
                                collection: change.container, role: change.role)
                effect.count = true
                dispositions.append(.intermediate)
                intermediate.append(effect)
                continue
            }
            // Net means net: a value the window's last read shows back in its earlier state is intermediate.
            if isStale(effect) {
                dispositions.append(.intermediate)
                intermediate.append(effect)
                continue
            }
            dispositions.append(.effect(effects.count))
            effects.append(effect)
        }

        // The time gate: the actions covered by the reads where each effect's subject was seen changing.
        let covered = Dictionary(uniqueKeysWithValues: reads.map { ($0.index, $0.actions) })
        let overlapping = Set(reads.filter(\.overlapped).map(\.index))
        func steps(_ effect: Effect) -> [Change] {
            let names = Set([effect.label, effect.before, effect.after].compactMap { $0 }.map(Self.key))
            return stepChanges.filter { change in
                guard change.window == effect.window else { return false }
                switch effect.kind {
                case .title: return change.kind == .title
                case .resorted: return [.moved, .resorted].contains(change.kind) && change.container == effect.label
                default: return [change.name, change.subject, change.member ?? ""].contains { names.contains(Self.key($0)) }
                }
            }
        }
        func actions(_ effect: Effect) -> Set<Int> {
            // A title changes when its page or document has loaded, often after the read that covered the command.
            let lag = effect.kind == .title ? stepChanges.filter { $0.window == effect.window && $0.kind == .title }
                .flatMap { covered[$0.from] ?? [] } : []
            return Set(lag).union(steps(effect).flatMap { covered[$0.to] ?? [] })
        }
        // Input arrived while a read showing the change ran: it may follow later input than it seems. A title follows a
        // load, never the input of its read.
        func overlapped(_ effect: Effect) -> Bool {
            effect.kind != .title && steps(effect).contains { overlapping.contains($0.to) }
        }
        for index in effects.indices {
            effects[index].actions = actions(effects[index])
            effects[index].overlapped = overlapped(effects[index])
        }
        for index in intermediate.indices { intermediate[index].actions = actions(intermediate[index]) }
        resolveStructure(covered: covered)

        // What each read observed, for details: interface noise left out, intermediate states marked.
        for change in stepChanges {
            guard ![.appeared, .disappeared].contains(change.kind),
                  noise(change, transient: transient, readout: isReadout(change)) == nil,
                  let read = sequence[change.to] else { continue }
            let kept = effects.contains { $0.window == change.window && $0.label == change.name && $0.after == change.after }
            observed[read, default: []].append(Self.describe(Self.effect(change)) + (kept ? "" : " (not in the final state)"))
        }
    }

    private func isReadout(_ change: Change) -> Bool {
        let key = "\(change.window)|\(change.subject)"
        return (autonomous.contains(key) || settledAlone[key] == true) && !edited.contains(key)
    }

    /// What structural reads certify inside the part of a collection both reads cover: members in, out, renamed (same
    /// identifier or document), reordered, or grouped into other sections. A viewport certifies nothing; each effect is
    /// timed by the first step that reached its final state, over every read since the step's earlier structural read,
    /// that read included.
    private mutating func resolveStructure(covered: [Int: [Int]]) {
        typealias Window = InteractionStructuralRead.Window
        let order = reads.map(\.index)
        let windows = Set(structures.values.flatMap(\.keys))
        for window in windows.sorted() {
            let sequence = order.compactMap { index in structures[index]?[window].map { (index: index, read: $0) } }
            if let last = sequence.last?.read {
                for region in last.hosted where !region.read && !unobservedRegions.contains(where: { $0.window == window && $0.host == (region.host ?? "") }) {
                    unobservedRegions.append((window, region.host ?? "another process"))
                }
            }
            guard let first = sequence.first, let last = sequence.last, first.index != last.index else { continue }
            let shown = everShown[window] ?? []
            // A step is found by the state it reached, else by its subject (a move's neighbour may differ in between).
            func steps(_ effect: Effect) -> [String] {
                ["\(effect.kind)|\(effect.label)|\(effect.after ?? "")", "\(effect.kind)|\(effect.label)"]
            }
            // A read whose structural read failed leaves its actions to the next structural read of the window. An
            // application often draws a change after the read that followed its command (Finder regroups after its menu
            // closes; Pro Tools removes a track after its Delete), so that read's actions stay candidates too.
            var since: [String: [Int]] = [:]
            for (a, b) in zip(sequence, sequence.dropFirst()) {
                for change in Self.membership(a.read, b.read, shown: shown) {
                    let reads = order.filter { $0 >= a.index && $0 <= b.index }
                    for key in steps(change) where since[key] == nil { since[key] = reads }
                }
            }
            for var effect in Self.membership(first.read, last.read, shown: shown) {
                let known = (effects + intermediate).contains { $0.window == window && $0.kind == effect.kind && Self.key($0.label) == Self.key(effect.label) }
                guard !known else { continue }
                let reached = steps(effect).lazy.compactMap { since[$0] }.first
                    ?? Self.span(of: effect, in: sequence, order: order, shown: shown)
                let whole = effect.whole
                effect = Effect(window: window, kind: effect.kind, label: effect.label, before: effect.before, after: effect.after,
                                collection: effect.collection)
                effect.whole = whole
                effect.actions = Set(reached.flatMap { covered[$0] ?? [] })
                effects.append(effect)
            }
            // A control a person sets, the only one of its role, name and container in each read: its first value
            // against its last, timed by the step that reached the last. Levels and choices a scene never shows (a
            // slider whose only value is where its thumb sits, the output of a track off screen) are found here.
            let readings = sequence.map { (index: $0.index, levels: Self.settings($0.read)) }
            for key in Set(readings.flatMap(\.levels.keys)).sorted() {
                let seen = readings.compactMap { reading in reading.levels[key].map { (index: reading.index, level: $0) } }
                guard let earliest = seen.first, let latest = seen.last, earliest.level.value != latest.level.value,
                      !(effects + intermediate).contains(where: {
                          $0.window == window && $0.kind == .value && Self.key($0.label) == Self.key(latest.level.name)
                      }) else { continue }
                var effect = Effect(window: window, kind: .value, label: latest.level.name, before: earliest.level.value,
                                    after: latest.level.value, role: key.components(separatedBy: "|").first)
                let step = Array(zip(seen, seen.dropFirst())).last { $0.level.value != $1.level.value }
                let reads = step.map { step in order.filter { $0 > step.0.index && $0 <= step.1.index } } ?? []
                effect.actions = Set(reads.flatMap { covered[$0] ?? [] })
                effects.append(effect)
            }
        }
        // An in-place editor (a window holding one field and nothing else) the person typed into and that then
        // closed renames what it opened on: its first value to its last.
        for window in editors.sorted() {
            let seen = order.compactMap { index in structures[index]?[window].map { (index: index, read: $0) } }
            guard let first = seen.first, let last = seen.last,
                  seen.allSatisfy({ $0.read.fields.count == 1 && $0.read.collections.isEmpty }),
                  let before = first.read.fields[0].value, let after = last.read.fields[0].value, before != after,
                  order.contains(where: { $0 > last.index && structures[$0] != nil && structures[$0]?[window] == nil }),
                  !(effects + intermediate).contains(where: { $0.kind == .renamed && Self.key($0.label) == Self.key(after) })
            else { continue }
            var effect = Effect(window: window, kind: .renamed, label: after, before: before, after: after)
            let changed = zip(seen, seen.dropFirst()).filter { $0.read.fields[0].value != $1.read.fields[0].value }.map(\.1.index)
            effect.actions = Set(changed.flatMap { covered[$0] ?? [] })
            effects.append(effect)
        }
    }

    /// A collection member as identity sees it: keyed by its name without markers or counts, a duplicate name told
    /// apart by its rank among its namesakes; a member with no name (or only a count, time or date) by its position.
    private struct Keyed {
        let key: String
        let name: String?
        let state: String?
        let member: InteractionStructuralRead.Member
    }

    private static func keyed(_ members: [InteractionStructuralRead.Member], shown: Set<String>) -> [Keyed] {
        let names = members.map { member in
            (member.name ?? member.document).map(HumanInterventionIdentity.countBase).flatMap { HumanInterventionIdentity.isNameless($0) ? nil : $0 }
        }
        let present = names.compactMap { $0 }
        let cleaned = HumanInterventionIdentity.strippingMarkers(present) { shown.contains(key($0)) }
        var next = cleaned.makeIterator()
        var ranks: [String: Int] = [:]
        return zip(members, names).map { member, name in
            guard name != nil, let clean = next.next(), !key(clean.name).isEmpty else {
                return Keyed(key: "@\(member.index)", name: nil, state: nil, member: member)
            }
            let rank = ranks[key(clean.name), default: 0]
            ranks[key(clean.name)] = rank + 1
            return Keyed(key: key(clean.name) + (rank > 0 ? "#\(rank)" : ""), name: clean.name, state: clean.state, member: member)
        }
    }

    /// The controls of `read` a person sets, by role, name, identifier and container, each the only one of its key:
    /// a level (slider, stepper) and a pop-up's choice. A control whose name carries its value on a second line
    /// ("Audio Output Path selector" over "Output (Stereo)") goes by its first line. A pop-up is compared only within
    /// its container: one of a name per track or row, and archives without containers could pair two tracks' ones.
    static func settings(_ read: InteractionStructuralRead.Window) -> [String: (name: String, value: String)] {
        var result: [String: (name: String, value: String)] = [:]
        var seen: [String: Int] = [:], named: [String: Int] = [:]
        var found: [(key: String, base: String, container: String, value: String?, named: String)] = []
        for field in read.fields {
            let level = InteractionSemanticSnapshot.levelRoles.contains(field.role)
            guard level || field.role == "AXPopUpButton" else { continue }
            let lines = (field.name ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let base = lines.first, !base.isEmpty else { continue }
            let container = field.container ?? ""
            guard level || !container.isEmpty else { continue }
            let key = "\(field.role)|\(base)|\(field.identifier ?? "")|\(container)"
            seen[key, default: 0] += 1
            named["\(field.role)|\(base)", default: 0] += 1
            let value = field.value ?? (lines.count > 1 ? lines.dropFirst().joined(separator: " ") : nil)
            found.append((key, base, container, value, "\(field.role)|\(base)"))
        }
        // The container names a control only when its name alone does not tell it apart.
        for entry in found where seen[entry.key] == 1 {
            guard let value = entry.value else { continue }
            let name = named[entry.named] == 1 || entry.container.isEmpty ? entry.base : entry.base + " on " + entry.container
            result[entry.key] = (name, value)
        }
        return result
    }

    /// The reads a member's arrival or departure falls between when no single step certifies it (a list read in part in
    /// between): from the last read that showed it (or, for an arrival, did not) to the first complete read that
    /// shows the change, both included. Empty for other effects.
    private static func span(of effect: Effect, in sequence: [(index: Int, read: InteractionStructuralRead.Window)],
                             order: [Int], shown: Set<String>) -> [Int] {
        guard [.created, .deleted].contains(effect.kind), let collection = effect.collection else { return [] }
        func state(_ read: InteractionStructuralRead.Window) -> (present: Bool, complete: Bool)? {
            guard let list = read.collections.first(where: { ($0.name ?? $0.identifier ?? $0.role) == collection }) else { return nil }
            let present = keyed(list.members, shown: shown).contains { $0.name.map(key) == key(effect.label) }
            return (present, list.coverage == .complete)
        }
        let before = effect.kind == .deleted
        guard let end = sequence.firstIndex(where: { step in
                  state(step.read).map { $0.complete && $0.present != before } == true
              }),
              let start = sequence[..<end].lastIndex(where: { step in state(step.read).map { $0.present == before } == true })
        else { return [] }
        return order.filter { $0 >= sequence[start].index && $0 <= sequence[end].index }
    }

    /// Roles of a collection, which also mark a member that is a section of its collection.
    private static let collectionRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid", "AXBrowser"]

    /// The names of the sections `collection` holds, joined; nil when it holds none, or when `window`'s read does
    /// not hold every section as a collection of its own: a reader that never opened the sections named an unnamed
    /// one after its first item ("Drafts, 2 items"), which is no group.
    private static func sections(_ collection: InteractionStructuralRead.Collection,
                                 in window: InteractionStructuralRead.Window) -> String? {
        let parts = collection.members.filter { collectionRoles.contains($0.role ?? "") }
        guard !parts.isEmpty, parts.allSatisfy({ part in
            window.collections.contains { $0.role == part.role && $0.name == part.name }
        }) else { return nil }
        let names = parts.compactMap(\.name)
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    /// Each collection of a later read with the one of an earlier read it continues. A named collection, the only
    /// one of its role, name and identifier in both reads, continues that one. Otherwise (a web page's unnamed
    /// lists) a collection continues the earlier one it shares the most members with, and none when it shares
    /// none: lists that only look alike are never compared, so they claim nothing.
    private static func paired(_ old: [InteractionStructuralRead.Collection], _ new: [InteractionStructuralRead.Collection])
        -> [(InteractionStructuralRead.Collection, InteractionStructuralRead.Collection)] {
        func signature(_ collection: InteractionStructuralRead.Collection) -> String {
            "\(collection.role)|\(collection.name ?? "")|\(collection.identifier ?? "")"
        }
        func names(_ collection: InteractionStructuralRead.Collection) -> Set<String> {
            Set(collection.members.compactMap { ($0.name ?? $0.document).map(key) }.filter { !$0.isEmpty })
        }
        var used = Set<Int>()
        var result: [(InteractionStructuralRead.Collection, InteractionStructuralRead.Collection)] = []
        for collection in new {
            let candidates = old.indices.filter { !used.contains($0) && signature(old[$0]) == signature(collection) }
            let named = collection.name != nil || collection.identifier != nil
            let unique = candidates.count == 1 && new.filter { signature($0) == signature(collection) }.count == 1
            let members = names(collection)
            let overlaps = candidates.map { (index: $0, shared: names(old[$0]).intersection(members).count) }
            guard let match = named && unique ? candidates.first
                    : overlaps.filter({ $0.shared > 0 }).max(by: { $0.shared < $1.shared })?.index else { continue }
            used.insert(match)
            result.append((old[match], collection))
        }
        return result
    }

    /// Certified membership effects between two structural reads of one window, window number unset. Members are
    /// matched by name; a name that changed is a rename only with evidence (the same stable identifier, or the same
    /// document), else a removal and an addition. A member read without a name may be any of them: nothing is
    /// claimed across it. `shown` holds the names any read of the window shows, for telling markers from names.
    private static func membership(_ old: InteractionStructuralRead.Window, _ new: InteractionStructuralRead.Window,
                                   shown: Set<String> = []) -> [Effect] {
        var result: [Effect] = []
        for (previous, collection) in paired(old.collections, new.collections) {
            // The sections a collection is grouped into are its setting; "none" when no section has a name of its own.
            if previous.coverage == .complete, collection.coverage == .complete,
               let earlier = sections(previous, in: old), let later = sections(collection, in: new), earlier != later {
                let label = collection.name ?? collection.identifier ?? collection.role
                var effect = Effect(window: 0, kind: .value, label: label + " groups", before: earlier, after: later,
                                    collection: label)
                effect.whole = true
                result.append(effect)
            }
            // The part both reads cover, counted from the first member; a viewport covers nothing.
            func covered(_ coverage: InteractionStructuralRead.Coverage) -> Int? {
                switch coverage {
                case .complete: Int.max
                case .range(0, let last): last
                default: nil
                }
            }
            guard let a = covered(previous.coverage), let b = covered(collection.coverage) else { continue }
            let reach = min(a, b)
            let label = collection.name ?? collection.identifier ?? collection.role
            let before = keyed(previous.members.filter { $0.index <= reach }, shown: shown)
            let after = keyed(collection.members.filter { $0.index <= reach }, shown: shown)
            let oldKeys = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let newKeys = Dictionary(after.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            // An identifier is evidence only when every member kept by name kept it too: a row index is no identity.
            let kept = after.filter { $0.name != nil && oldKeys[$0.key] != nil }
            let stable = kept.contains { $0.member.identifier != nil }
                && kept.allSatisfy { $0.member.identifier == oldKeys[$0.key]?.member.identifier }
            var gone = before.filter { $0.name != nil && newKeys[$0.key] == nil }
            var added = after.filter { $0.name != nil && oldKeys[$0.key] == nil }
            for member in added {
                guard let index = gone.firstIndex(where: { earlier in
                    stable && earlier.member.identifier != nil && earlier.member.identifier == member.member.identifier
                        || earlier.member.document != nil && earlier.member.document == member.member.document
                }) else { continue }
                result.append(Effect(window: 0, kind: .renamed, label: member.name ?? "", before: gone[index].name,
                                     after: member.name, collection: label))
                gone.remove(at: index)
                added.removeAll { $0.key == member.key }
            }
            if !after.contains(where: { $0.name == nil }) {
                result += gone.map { Effect(window: 0, kind: .deleted, label: $0.name ?? "", collection: label) }
            }
            if !before.contains(where: { $0.name == nil }) {
                result += added.map { Effect(window: 0, kind: .created, label: $0.name ?? "", collection: label) }
            }
            // The same member spelled otherwise ("A B" → "A_B") keeps its key: a rename.
            for member in kept where member.name != oldKeys[member.key]?.name {
                result.append(Effect(window: 0, kind: .renamed, label: member.name ?? "", before: oldKeys[member.key]?.name,
                                     after: member.name, collection: label))
            }
            // A marker that changed while the member's selection did not is its state (shown, hidden).
            for member in kept where member.state != oldKeys[member.key]?.state && member.member.selected == oldKeys[member.key]?.member.selected {
                guard let earlier = oldKeys[member.key]?.state, let state = member.state else { continue }
                result.append(Effect(window: 0, kind: .state, label: member.name ?? "", before: earlier, after: state, collection: label))
            }
            guard previous.coverage == .complete, collection.coverage == .complete else { continue }
            let common = Set(kept.map(\.key))
            let names = { (members: [Keyed]) in members.map(\.key).filter(common.contains) }
            let moved = HumanInterventionScene.reordered(old: names(before), new: names(after))
            if moved.count >= 3 {
                result.append(Effect(window: 0, kind: .resorted, label: label, collection: label))
            } else {
                let current = names(after)
                for key in moved {
                    let position = current.firstIndex(of: key) ?? 0
                    let follows = position > 0 ? newKeys[current[position - 1]]?.name : nil
                    result.append(Effect(window: 0, kind: .moved, label: newKeys[key]?.name ?? key, after: follows, collection: label))
                }
            }
        }
        return result
    }

    /// Interface noise, decided by evidence: dialogs and menus, pixel text, members entering or leaving a viewport,
    /// controls shown or hidden, availability, the same name read again, readouts and display-only values.
    private func noise(_ change: Change, transient: Set<Int>, readout: Bool) -> String? {
        if transient.contains(change.window) { return "dialog or menu" }
        if change.role == nil, ![.title, .moved, .resorted].contains(change.kind) { return "pixel text" }
        let settable = HumanInterventionScene.settableRoles.contains(change.role ?? "")
        switch change.kind {
        case .appeared, .disappeared: return change.member == nil ? "control shown or hidden" : "list member entering or leaving view"
        case .enabled: return "availability"
        case .renamed:
            return Self.key(change.before ?? "") == Self.key(change.after ?? "") ? "same name read again" : nil
        case .value:
            // A value read on one side only was unread there: its change is unknown.
            if change.before == nil || change.after == nil { return "value unread on one side" }
            return readout || !settable ? "readout" : nil
        // A state read as unknown on one side was not read there: its change is unknown.
        case .state where [change.before, change.after].contains { $0 == nil || $0 == "unknown" }: return "state unread on one side"
        case .state: return settable ? nil : "interface state"
        case .moved, .resorted: return change.list ? nil : "layout order"
        case .title: return nil
        }
    }


    private static func effect(_ change: Change) -> Effect {
        let kind: Effect.Kind = switch change.kind {
        case .moved: .moved
        case .resorted: .resorted
        case .title: .title
        case .renamed: .renamed
        case .state: .state
        default: .value
        }
        return Effect(window: change.window, kind: kind, label: change.kind == .renamed ? change.after ?? change.name : change.name,
                      before: change.before, after: change.after, collection: change.container, role: change.role)
    }


    /// One effect in neutral words, as details state it.
    static func describe(_ effect: Effect) -> String {
        func value(_ text: String?) -> String {
            let flat = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return flat.isEmpty ? "empty" : HumanInterventionSummary.excerpt(flat)
        }
        switch effect.kind {
        case .created: return "+ " + effect.label
        case .deleted: return "− " + effect.label
        case .renamed: return "\(effect.before ?? "") → \(effect.label)"
        case .moved: return effect.label + " moved" + (effect.after.map { " after " + $0 } ?? "")
        case .resorted: return effect.label + " re-sorted"
        case .edited: return "\(effect.label) of \(effect.member ?? "an item"): \(value(effect.after))"
        default: return "\(effect.label): \(value(effect.before)) → \(value(effect.after))"
        }
    }

    /// Sets each effect's possible causes, body effects first, then intermediate ones.
    mutating func attribute(_ causes: [Set<Int>]) {
        for index in effects.indices where causes.indices.contains(index) { effects[index].causes = causes[index] }
        for index in intermediate.indices where causes.indices.contains(effects.count + index) {
            intermediate[index].causes = causes[effects.count + index]
        }
    }

    func withholding(_ transform: (String) -> String) -> Self {
        var result = self
        func change(_ value: Change) -> Change {
            var copy = Change(window: value.window, kind: value.kind, subject: transform(value.subject), role: value.role,
                              container: value.container.map(transform), member: value.member.map(transform),
                              before: value.before.map(transform), after: value.after.map(transform),
                              from: value.from, to: value.to)
            copy.name = transform(value.name)
            copy.fromOrdinal = value.fromOrdinal
            copy.toOrdinal = value.toOrdinal
            copy.list = value.list
            copy.count = value.count
            copy.owned = value.owned
            return copy
        }
        func effect(_ value: Effect) -> Effect {
            var copy = value
            copy.label = transform(value.label)
            copy.before = value.before.map(transform)
            copy.after = value.after.map(transform)
            copy.member = value.member.map(transform)
            copy.collection = value.collection.map(transform)
            return copy
        }
        result.stepChanges = stepChanges.map(change)
        result.netChanges = netChanges.map(change)
        result.effects = effects.map(effect)
        result.intermediate = intermediate.map(effect)
        result.observed = observed.mapValues { $0.map(transform) }
        return result
    }

    // MARK: - Invariants


    /// Invariants 7 and 8: no body subject is a bare count, time, date or state marker ("6 notes", "15:18",
    /// "Shown."), and no name is renamed onward (A → B with B → C in one window), which only shifted rows produce.
    func malformed() -> [String] {
        func bare(_ text: String?) -> Bool {
            guard let text else { return false }
            return HumanInterventionIdentity.isNameless(text) || text.range(of: #"^\p{L}+\.$"#, options: .regularExpression) != nil
        }
        let subjects = effects.filter { bare($0.label) || $0.kind == .renamed && bare($0.before) || $0.kind == .moved && bare($0.after) }
        let renames = effects.filter { $0.kind == .renamed }
        let chains = renames.filter { rename in
            renames.contains { $0.window == rename.window && $0.before.map(Self.key) == Self.key(rename.label) && Self.key($0.label) != Self.key(rename.label) }
        }
        return (subjects + chains).map(Self.describe)
    }

    /// Invariant 5, net means net: body effects whose control the last read shows still holding its earlier value.
    func stale() -> [String] {
        effects.filter(isStale).map(Self.describe)
    }

    private func isStale(_ effect: Effect) -> Bool {
        guard [.value, .state].contains(effect.kind), let before = effect.before,
              Self.key(before) != Self.key(effect.after ?? ""),
              let values = finalValues[effect.window]?[Self.key(effect.label)] else { return false }
        return values.contains(Self.key(before)) && !values.contains(Self.key(effect.after ?? ""))
    }
}
