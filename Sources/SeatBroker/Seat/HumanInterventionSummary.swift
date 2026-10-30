//
//  HumanInterventionSummary.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation
import Engine
import Memory
import InteractionListener
import os

/// HumanInterventionSummary renders the net effects within 1,000 UTF-8 bytes: one line per fact type, then what
/// changed with no known cause and what could not be observed. Causes and intermediate states stay in details.
nonisolated enum HumanInterventionSummary {
    static let maximumBytes = 1000

    struct Digest: Sendable {
        let text: String
        let evidence: HumanInterventionEvidence
        let strings: HumanInterventionStrings
        /// Causes ranked with the episode's embeddings when they were available; details only.
        var attribution = HumanInterventionAttribution()
    }

    static func build(
        _ review: HumanInterventionConsumer.Intervention.Review,
        note: String? = nil,
        withholding: (String) -> String = { $0 }
    ) -> String {
        digest(review, note: note, withholding: withholding).text
    }

    static func digest(
        _ review: HumanInterventionConsumer.Intervention.Review,
        note: String? = nil,
        actionVectors: [[Float]] = [],
        effectVectors: [[Float]] = [],
        embeddingModel: String? = nil,
        withholding: (String) -> String = { $0 }
    ) -> Digest {
        let evidence = HumanInterventionEvidence(review)
        return digest(evidence, note: note, actionVectors: actionVectors, effectVectors: effectVectors,
                      embeddingModel: embeddingModel, withholding: withholding)
    }

    /// `embeddingModel` names the model the vectors come from ("id@revision"); causes are ranked only for the model
    /// the attribution floor was calibrated on.
    static func digest(
        _ evidence: HumanInterventionEvidence,
        note: String? = nil,
        actionVectors: [[Float]] = [],
        effectVectors: [[Float]] = [],
        embeddingModel: String? = nil,
        withholding: (String) -> String = { $0 }
    ) -> Digest {
        func safe(_ text: String) -> String {
            withholding(ValueMinimization().minimize(text: text).0)
                .components(separatedBy: .newlines).joined(separator: " ")
        }
        typealias Token = HumanInterventionStrings.Token
        // Vectors arrive as commands then effects, or split; either way they only rank causes for details.
        let commands = evidence.attribution.commandTexts.count
        let attribution = effectVectors.count == evidence.attribution.effectTexts.count && !effectVectors.isEmpty
            ? evidence.attribution.ranked(commands: actionVectors, effects: effectVectors, model: embeddingModel)
            : evidence.attribution.ranked(commands: Array(actionVectors.prefix(commands)),
                                          effects: Array(actionVectors.dropFirst(commands)), model: embeddingModel)
        if let skipped = attribution.skipped { log.notice("human digest attribution: causes unranked, \(skipped, privacy: .public)") }
        let uncertain = attribution.links.filter { $0.confidence == .uncertain }.count
        if uncertain > 0 { log.notice("human digest attribution: \(uncertain, privacy: .public) uncertain causes") }
        let body = evidence.ledger.effects
        let unobserved = unobservedEntries(evidence)
        let details = detailLine(evidence)
        let notes = (note.map { [safe($0)] } ?? []) + (details.map { [$0] } ?? [])
        guard !body.isEmpty || !unobserved.isEmpty else {
            let lines = ["No changes made."] + notes
            let bounded = lines.joined(separator: "\n").utf8.count <= maximumBytes
                ? lines : ["No changes made.", "Handoff note available in details."] + (details.map { [$0] } ?? [])
            return Digest(text: bounded.joined(separator: "\n"), evidence: evidence,
                strings: HumanInterventionStrings(tokens: []), attribution: attribution)
        }
        let title = safe(evidence.appName + " — " + evidence.documentTitle)
        let header = title.utf8.count <= 180 ? title : "Human intervention"
        // Only the exception is worth the worker's tokens: a missing final read leaves every effect unconfirmed.
        let footer = (evidence.hasFinalDocumentRead ? [] : ["Final state unread: verify before relying on it."]) + notes
        func sanitized(_ lines: [[Token]]) -> [[Token]] {
            lines.map { $0.map { token in
                switch token {
                case .literal(let text): return .literal(safe(text))
                case .operand(let text): return .operand(safe(text))
                }
            } }
        }
        func render(_ shown: [HumanInterventionEffects.Effect], level: Int, unknownLevel: Int? = nil,
                    more: Int) -> (String, HumanInterventionStrings) {
            let caused = shown.filter { !$0.causes.isEmpty }, unknown = shown.filter { $0.causes.isEmpty }
            var lines: [[Token]] = [[.literal(header)]]
            lines += entries(caused, evidence: evidence, level: level).map { $0.type + [.literal(": ")] + $0.items + [.literal(".")] }
            let other = entries(unknown, evidence: evidence, level: unknownLevel ?? level)
            if !other.isEmpty {
                var line: [Token] = [.literal("Also changed (cause unknown): ")]
                for (index, entry) in other.enumerated() {
                    line += (index > 0 ? [.literal("; ")] : []) + entry.type + [.literal(": ")] + entry.items
                }
                lines.append(line + [.literal(".")])
            }
            if more > 0 { lines.append([.literal("+\(more) more change\(more == 1 ? "" : "s") in details.")]) }
            if !unobserved.isEmpty {
                var line: [Token] = [.literal("Unobserved: ")]
                for (index, entry) in unobserved.enumerated() { line += (index > 0 ? [.literal("; ")] : []) + entry }
                lines.append(line + [.literal(".")])
            }
            let tokens = sanitized(lines + footer.map { [.literal($0)] })
            let strings = HumanInterventionStrings(tokens: tokens)
            return (strings.render(tokens), strings)
        }
        // Each level sheds less useful detail first; past the last, effects leave from the end, counted. Changes with
        // no known cause give up their names before the person's own changes give up a value.
        var shown = body
        var (text, strings) = render(shown, level: 0, more: 0)
        for level in 0...Compaction.namesInDetails where text.utf8.count > maximumBytes {
            (text, strings) = render(shown, level: level, unknownLevel: Compaction.namesInDetails, more: 0)
        }
        while text.utf8.count > maximumBytes, !shown.isEmpty {
            shown.removeLast()
            (text, strings) = render(shown, level: Compaction.namesInDetails, more: body.count - shown.count)
        }
        if text.utf8.count > maximumBytes {
            let lines = [header, "\(body.count) observed changes; \(unobserved.count) unobserved actions. Evidence in human_step."]
                + (details.map { [$0] } ?? [])
            strings = HumanInterventionStrings(tokens: lines.map { [.literal($0)] })
            text = strings.render(lines)
            shown = []
        }
        #if DEBUG
        let violations = evidence.ledger.stale() + evidence.ledger.malformed()
        if !violations.isEmpty { log.fault("report invariants violated: \(violations.count, privacy: .public)") }
        #endif
        return Digest(text: text, evidence: evidence, strings: strings, attribution: attribution)
    }

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")

    /// The pointer to details: every step, how many actions, and how many caused no observed change.
    private static func detailLine(_ evidence: HumanInterventionEvidence) -> String? {
        guard let span = detailReference(Array(1...max(1, evidence.steps.count))), !evidence.steps.isEmpty else { return nil }
        let causes = evidence.attribution.deterministicCauses
        let actions = evidence.threads.owners.count
        let idle = evidence.threads.owners.filter { !causes.contains($0) }.count
        return "Details: \(span) (\(actions) action\(actions == 1 ? "" : "s"), \(idle) without an observed change)."
    }

    /// One span over the steps: each line already names its fact, so the worker needs only where to page.
    private static func detailReference(_ indexes: [Int]) -> String? {
        guard let first = indexes.min(), let last = indexes.max() else { return nil }
        return first == last ? "human_step step \(first)" : "human_step steps \(first)-\(last)"
    }

    /// Rendering levels, tried in order until the digest fits.
    private enum Compaction {
        /// Values before a change are dropped.
        static let terse = 1
        /// Field excerpts and changed values are dropped; their controls stay named.
        static let unnamedValues = 2
        /// Created, deleted and renamed members are counted only; every name is still in the details.
        static let namesInDetails = 3
    }

    /// Body entries, one per fact type: the type from the effect's kind, refined only by a compatible meaning of
    /// its causes' captions, then its operands.
    private static func entries(_ effects: [HumanInterventionEffects.Effect], evidence: HumanInterventionEvidence,
                                level: Int) -> [(type: [HumanInterventionStrings.Token], items: [HumanInterventionStrings.Token])] {
        typealias Token = HumanInterventionStrings.Token
        typealias Effect = HumanInterventionEffects.Effect
        func means(_ meaning: HumanInterventionVocabulary.Meaning, _ effect: Effect) -> Bool {
            effect.causes.contains { evidence.threads.means($0, meaning) }
        }
        // A radio button turned on and its partners turned off are one choice.
        var effects = effects
        var choices: [(type: [Token], items: [Token])] = []
        for window in Set(effects.map(\.window)).sorted() {
            let radios = effects.indices.filter { effects[$0].window == window && effects[$0].kind == .state && effects[$0].role == "AXRadioButton" }
            let on = radios.filter { effects[$0].after == "on" }, off = radios.filter { effects[$0].after == "off" }
            guard on.count == 1, !off.isEmpty, let chosen = on.first else { continue }
            choices.append(([.literal("Selected")], [.operand(off.map { effects[$0].label }.joined(separator: ", ")),
                                                      .literal(" → "), .operand(effects[chosen].label)]))
            let used = Set(on + off)
            effects = effects.indices.filter { !used.contains($0) }.map { effects[$0] }
        }
        func type(_ effect: Effect) -> String {
            switch effect.kind {
            case .created: return means(.create, effect) ? "Create" : "Added"
            case .deleted: return means(.delete, effect) ? "Delete" : "Removed"
            case .renamed: return "Rename"
            case .moved: return "Move"
            case .resorted: return "Re-sorted"
            case .title: return "Window title"
            default: return effect.label
            }
        }
        // Values and states keep their observed order: both are a control's setting.
        let order: [[Effect.Kind]] = [[.created], [.deleted], [.renamed], [.moved], [.resorted], [.edited], [.value, .state], [.title]]
        var groups: [(type: String, effects: [Effect])] = []
        for kinds in order {
            for effect in effects where kinds.contains(effect.kind) {
                let name = type(effect)
                if let index = groups.firstIndex(where: { $0.type == name && $0.effects.first?.kind == effect.kind }) {
                    groups[index].effects.append(effect)
                } else { groups.append((name, [effect])) }
            }
        }
        var result: [(type: [Token], items: [Token])] = []
        for group in groups {
            let kind = group.effects[0].kind
            var items: [Token] = []
            let counted = level >= Compaction.namesInDetails && [.created, .deleted, .renamed].contains(kind)
            if counted {
                let count = group.effects.count
                items = [.literal((kind == .created ? "+ " : kind == .deleted ? "− " : "")
                    + "\(count) item\(count == 1 ? "" : "s") (names in details)")]
            } else {
                for (index, effect) in group.effects.enumerated() {
                    if index > 0 { items.append(.literal(", ")) }
                    switch kind {
                    case .created:
                        items += (index == 0 ? [.literal("+ ")] : []) + [.operand(effect.label)]
                            + (effect.recreated ? [.literal(" (re-created)")] : [])
                    case .deleted: items += (index == 0 ? [.literal("− ")] : []) + [.operand(effect.label)]
                    case .renamed: items += [.operand(effect.before ?? ""), .literal(" → "), .operand(effect.label)]
                    case .moved: items += [.operand(effect.label)] + (effect.after.map { [.literal(" after "), .operand($0)] } ?? [])
                    case .resorted: items.append(.operand(effect.label))
                    case .edited:
                        items.append(.operand(effect.member ?? "an item"))
                        if level < Compaction.unnamedValues { items += [.literal(" “"), .operand(excerpt(effect.after ?? "")), .literal("”")] }
                    default:
                        if level >= Compaction.unnamedValues { items.append(.literal("changed")); continue }
                        if level < Compaction.terse, let before = effect.before { items += shown(before) + [.literal(" → ")] }
                        items += shown(effect.after ?? "")
                    }
                }
            }
            if [.renamed, .edited, .value, .state, .title].contains(kind), group.effects.contains(where: \.overlapped) {
                items.append(.literal(" (input overlapped read)"))
            }
            result.append(([kind == .edited || kind == .value || kind == .state ? .operand(group.type) : .literal(group.type)], items))
        }
        return result + choices
    }

    /// Actions whose effect no read can show, each named once with how often it was given: a commit or choice
    /// that changed nothing observable, and the windows that could not be read at the end.
    private static func unobservedEntries(_ evidence: HumanInterventionEvidence) -> [[HumanInterventionStrings.Token]] {
        typealias Token = HumanInterventionStrings.Token
        let causes = evidence.attribution.deterministicCauses
        var groups: [(key: String, roots: [HumanInterventionThreads.Root])] = []
        for root in evidence.threads.roots where root.isOpaqueCommit && !causes.contains(root.id) {
            let targets = root.affected.isEmpty ? root.selectedObjects : root.affected
            let key = root.path.joined(separator: " ▸ ") + "|" + targets.joined(separator: ",") + "|" + root.operation.rawValue
            if let index = groups.firstIndex(where: { $0.key == key }) { groups[index].roots.append(root) }
            else { groups.append((key, [root])) }
        }
        let failed = Set(evidence.threads.roots.flatMap(\.unreadableSurfaces))
        var mentioned = Set<Int>()
        var entries: [[Token]] = groups.map { group in
            let root = group.roots[0]
            let named = root.path.filter { !$0.isEmpty }
            let path = named.joined(separator: " ▸ ")
            var labels: [String] = []
            for candidate in group.roots {
                if let label = candidate.terminal?.label, !label.isEmpty, !labels.contains(label) { labels.append(label) }
            }
            var entry: [Token] = []
            if root.operation == .choice, labels.isEmpty || path.isEmpty {
                // A choice whose opener was not read names no control: the item chosen is its value, never its subject.
                let choices = group.roots.count == 1 ? "a choice" : "\(group.roots.count) choices"
                entry = path.isEmpty ? [.literal(choices)] : [.operand(path), .literal(": " + choices)]
                for (index, label) in labels.enumerated() { entry += [.literal(index == 0 ? " → " : ", "), .operand(label)] }
            } else {
                if labels.count <= 1, group.roots.count > 1 { entry.append(.literal("\(group.roots.count)× ")) }
                if !path.isEmpty { entry.append(.operand(path)) }
                if !labels.isEmpty, labels != [named.last ?? ""] {
                    if !path.isEmpty { entry.append(.literal(" → ")) }
                    for (index, label) in labels.enumerated() {
                        if index > 0 { entry.append(.literal(", ")) }
                        entry.append(.operand(label))
                    }
                }
            }
            let targets = root.affected.isEmpty ? root.selectedObjects : root.affected
            if !targets.isEmpty {
                entry.append(.literal(" on "))
                for (index, target) in targets.enumerated() {
                    if index > 0 { entry.append(.literal(", ")) }
                    entry.append(.operand(target))
                }
            }
            let unread = Set(group.roots.flatMap(\.unreadableSurfaces))
            mentioned.formUnion(unread)
            return entry + (unread.isEmpty ? [] : [.literal(" (window unreadable at end)")])
        }
        // Counts that changed with no observed creation or removal in their window show a change no read saw.
        for window in Set(evidence.ledger.intermediate.filter(\.count).map(\.window)).sorted()
            where !evidence.ledger.effects.contains(where: { $0.window == window && [.created, .deleted].contains($0.kind) }) {
            let names = evidence.ledger.intermediate.filter { $0.count && $0.window == window }.map(\.label)
            entries.append([.literal("a change the counts of "), .operand(names.joined(separator: ", ")), .literal(" show")])
        }
        // Content another process hosts that did not answer: the region is named by its host.
        for region in evidence.ledger.unobservedRegions {
            entries.append([.literal("a pane hosted by "), .operand(region.host)])
        }
        // A window an action pointed or typed into that no read reached. A menu closes with its choice and a shortcut
        // acts on the focus, so neither names a window of its own.
        let pointed = evidence.ledger.unreadWindows.sorted().filter { window in
            evidence.threads.actions.contains { $0.windowNumber == window && !$0.isMenu && $0.kind != .shortcut }
        }
        let untitled = pointed.filter { evidence.windows[$0]?.isEmpty != false }.count
        for window in pointed { if let title = evidence.windows[window], !title.isEmpty { entries.append([.operand(title), .literal(" never read")]) } }
        if untitled > 0 { entries.append([.literal(untitled == 1 ? "a window never read" : "\(untitled) windows never read")]) }
        // A creation asked for more items than were observed: the rest could not be read.
        for root in evidence.threads.roots {
            guard let requested = root.requestedCount else { continue }
            let observed = evidence.ledger.effects.filter { $0.kind == .created && $0.causes.contains(root.id) }.count
            if observed > 0, requested > observed {
                entries.append([.literal("\(requested - observed) of \(requested) requested items")])
            }
        }
        for window in failed.subtracting(mentioned).sorted() {
            entries.append(evidence.windows[window].flatMap { $0.isEmpty ? nil : [.operand($0), .literal(" unreadable at end")] }
                ?? [.literal("a touched window unreadable at end")])
        }
        return entries
    }

    /// A value as shown, whitespace collapsed; an empty one says so.
    private static func shown(_ value: String) -> [HumanInterventionStrings.Token] {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return [text.isEmpty ? .literal("empty") : .operand(text)]
    }

    /// Field contents are shown briefly; protected values never reach a scene, and the caller withholds the rest.
    static func excerpt(_ value: String) -> String {
        let flat = value.components(separatedBy: .newlines).joined(separator: " ")
        return flat.count <= 32 ? flat : String(flat.prefix(31)) + "…"
    }

    /// Decodes and compares retained value snapshots on the concurrent executor, even for UI callers.
    @concurrent
    static func prepare(_ review: HumanInterventionConsumer.Intervention.Review) async -> HumanInterventionEvidence {
        assert(!Thread.isMainThread)
        return HumanInterventionEvidence(review)
    }

    /// Builds the bounded digest off the caller's actor. Withholding must capture only Sendable state.
    @concurrent
    static func render(
        _ evidence: HumanInterventionEvidence,
        note: String? = nil,
        actionVectors: [[Float]] = [],
        effectVectors: [[Float]] = [],
        embeddingModel: String? = nil,
        withholding: @Sendable (String) -> String = { $0 }
    ) async -> Digest {
        assert(!Thread.isMainThread)
        return digest(evidence, note: note, actionVectors: actionVectors, effectVectors: effectVectors,
                      embeddingModel: embeddingModel, withholding: withholding)
    }

    /// Describes metadata only, never typed characters or a protected field's title.
    static func action(_ payload: HumanRecordedInteraction) -> String {
        ValueMinimization().minimize(text: HumanInterventionEvidence.action(payload.summaryAction)).0
    }
}
