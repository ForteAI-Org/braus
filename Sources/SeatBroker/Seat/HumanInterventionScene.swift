//
//  HumanInterventionScene.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import PerceptionCore

/// HumanInterventionScene holds what the effects ledger reads off a scene: an element's name, whether a window is a
/// dialog, the members of each collection in order, the texts each member shows, and which members moved.
nonisolated enum HumanInterventionScene {
    /// Roles whose value or state a person sets directly.
    static let settableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider",
        "AXStepper", "AXIncrementor", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXPopUpButton"]

    /// The name a person sees: a member whose value names it, else its label, else (an internal identifier) the
    /// first line the control shows, else its role.
    static func name(_ element: PerceptionCore.SceneElement) -> String {
        if element.role != nil, let value = element.value, !value.isEmpty, element.container == value,
           element.label.contains(value) { return value }
        guard isIdentifier(element.label) else { return element.label }
        let line = (element.value ?? "").split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !line.isEmpty { return line.count <= 32 ? line : String(line.prefix(31)) + "…" }
        return element.role == "AXTextArea" ? "text area" : element.role == "AXTextField" ? "text field" : "control"
    }

    /// Whether a label carries an internal identifier, a UUID or a long hexadecimal token, rather than a name.
    static func isIdentifier(_ label: String) -> Bool {
        label.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                    options: .regularExpression) != nil
            || label.range(of: "\\b[0-9A-Fa-f]{16,}\\b", options: .regularExpression) != nil
    }

    /// A dialog by its role, or, as a hint, by buttons whose captions read as cancel and as a commit.
    static func isTransient(_ scene: SceneSnapshot) -> Bool {
        let buttons = Set(scene.elements.filter { $0.role == "AXButton" }.compactMap { HumanInterventionVocabulary.meaning(of: $0.label) })
        return buttons.contains(.cancel) && !buttons.isDisjoint(with: [.create, .commit, .apply, .delete])
            || scene.elements.contains { ["AXDialog", "AXSheet"].contains($0.role ?? "") }
    }

    /// Members are the named child subtrees `collection / member`; a collection without them uses
    /// its AXRow labels. Order is vertical, then horizontal, by the member's first element.
    static func members(_ scene: SceneSnapshot) -> [String: [String]] {
        typealias Position = (y: Double, x: Double)
        var subtrees: [String: [String: Position]] = [:]
        var rows: [String: [String: Position]] = [:]
        func place(_ table: inout [String: [String: Position]], _ collection: String, _ member: String,
                   _ element: PerceptionCore.SceneElement) {
            let position = (element.bounds.y, element.bounds.x)
            if let old = table[collection]?[member], old <= position { return }
            table[collection, default: [:]][member] = position
        }
        for element in scene.elements {
            guard let container = element.container, !container.isEmpty else { continue }
            if let split = container.range(of: " / ", options: .backwards) {
                let member = String(container[split.upperBound...])
                if !member.isEmpty { place(&subtrees, String(container[..<split.lowerBound]), member, element) }
            } else if element.role == "AXRow", !element.label.isEmpty {
                place(&rows, container, element.label, element)
            }
        }
        // ponytail: one position per name, so two members with the same name merge; split by
        // geometry if duplicate names in one collection matter.
        var result: [String: [String]] = [:]
        for collection in Set(subtrees.keys).union(rows.keys) {
            let table = subtrees[collection] ?? rows[collection] ?? [:]
            result[collection] = table.keys.sorted { lhs, rhs in
                let a = table[lhs]!, b = table[rhs]!
                return a != b ? a < b : lhs < rhs
            }
        }
        return result
    }

    /// A row goes by the one untitled editable field it holds, the cell an in-place rename edits, else by its first
    /// text, never by another column's text (a date, a size) a reader named it after.
    static func namingRows(_ scene: SceneSnapshot, byFirstText: Bool = true) -> SceneSnapshot {
        var fields: [String: [String]] = [:]
        for element in scene.elements where element.role == "AXTextField" {
            guard let container = element.container, container.contains(" / "),
                  let value = element.value, !value.isEmpty, element.label == value else { continue }
            fields[container, default: []].append(value)
        }
        let containers = Set(scene.elements.compactMap(\.container))
        var renamed: [String: String] = [:]
        var aliases: [String: String] = [:]
        for (container, values) in fields where values.count == 1 {
            guard let split = container.range(of: " / ", options: .backwards) else { continue }
            let member = String(container[split.upperBound...])
            let target = String(container[..<split.lowerBound]) + " / " + values[0]
            guard member != values[0], !containers.contains(target) else { continue }
            renamed[container] = target
            aliases[member] = values[0]
        }
        // A native row a reader named by its longest text (a date, a preview, a status) goes by its first text in
        // reading order, as a first column or a title shows it; the row's own label counts when it sits above them.
        var relabeled = Set<String>()
        let cells = byFirstText ? Dictionary(grouping: scene.elements.filter {
            ["AXStaticText", nil].contains($0.role) && !$0.label.isEmpty && $0.container != nil
        }, by: { $0.container ?? "" }) : [:]
        for row in scene.elements where byFirstText && row.role == "AXRow" && !row.label.isEmpty {
            guard let collection = row.container else { continue }
            let container = collection + " / " + row.label
            guard renamed[container] == nil else { continue }
            let cell = cells[container] ?? []
            guard cell.count >= 2, let first = cell.min(by: { ($0.bounds.y, $0.bounds.x) < ($1.bounds.y, $1.bounds.x) }) else { continue }
            let name = first.value?.isEmpty == false ? first.value ?? first.label : first.label
            guard row.bounds.y + 0.001 >= first.bounds.y, name != row.label, !HumanInterventionChanges.isNumeric(name),
                  !containers.contains(collection + " / " + name), !aliases.values.contains(name) else { continue }
            renamed[container] = collection + " / " + name
            aliases[row.label] = name
            relabeled.insert(container)
        }
        guard !renamed.isEmpty else { return scene }
        var result = scene
        for index in result.elements.indices {
            // The row itself takes the name its cell gave it.
            if result.elements[index].role == "AXRow", let collection = result.elements[index].container,
               relabeled.contains(collection + " / " + result.elements[index].label),
               let target = renamed[collection + " / " + result.elements[index].label],
               let split = target.range(of: " / ", options: .backwards) {
                result.elements[index].label = String(target[split.upperBound...])
            }
            guard let container = result.elements[index].container else { continue }
            if let target = renamed[container] {
                result.elements[index].container = target
            } else if let owner = renamed.keys.first(where: { container.hasPrefix($0 + " / ") }),
                      let target = renamed[owner] {
                result.elements[index].container = target + container.dropFirst(owner.count)
            }
        }
        return result
    }

    /// What each member's row shows, by collection: its subtree's labels and values, and its row's label.
    static func rowTexts(_ scene: SceneSnapshot) -> [String: [String: Set<String>]] {
        var result: [String: [String: Set<String>]] = [:]
        for element in scene.elements {
            guard let container = element.container, !container.isEmpty else { continue }
            if let split = container.range(of: " / ", options: .backwards) {
                let member = String(container[split.upperBound...])
                guard !member.isEmpty else { continue }
                let texts = [element.label, element.value ?? ""].filter { !$0.isEmpty }
                result[String(container[..<split.lowerBound]), default: [:]][member, default: []].formUnion(texts)
            } else if element.role == "AXRow", !element.label.isEmpty {
                result[container, default: [:]][element.label, default: []].insert(element.label)
            }
        }
        return result
    }

    /// The shared members whose removal restores the shared order: fewest not named in `movers`, then fewest named.
    /// At least three must be shared; a scroll or crop never reorders survivors.
    static func reordered(old: [String], new: [String], movers: Set<String> = []) -> [String] {
        let position = Dictionary(new.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let shared = old.filter { position[$0] != nil }
        let ranks = shared.compactMap { position[$0] }
        guard shared.count >= 3, ranks != ranks.sorted() else { return [] }
        // Keeping a named mover is worth one; keeping any other member outweighs every mover together.
        let weight = shared.map { movers.contains($0) ? 1 : shared.count + 1 }
        // ponytail: quadratic heaviest increasing run; collections hold tens of members, not thousands.
        var best = weight
        for i in ranks.indices.reversed() {
            for j in (i + 1)..<ranks.count where ranks[j] > ranks[i] { best[i] = max(best[i], weight[i] + best[j]) }
        }
        // ponytail: with no evidence between equal readings (A B → B A), the member earlier in `new` is kept,
        // so the one that ends later is named as moved; a selection or drag source is the only upgrade.
        var kept = Set<Int>()
        var need = best.max() ?? 0, last = -1, from = 0
        while need > 0, let next = (from..<ranks.count).filter({ best[$0] == need && ranks[$0] > last })
            .min(by: { ranks[$0] < ranks[$1] }) {
            kept.insert(next)
            (last, from, need) = (ranks[next], next + 1, need - weight[next])
        }
        return shared.indices.filter { !kept.contains($0) }.map { shared[$0] }
    }
}
