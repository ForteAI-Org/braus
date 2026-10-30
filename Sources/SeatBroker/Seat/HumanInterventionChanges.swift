//
//  HumanInterventionChanges.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation
import PerceptionCore

/// HumanInterventionChanges pairs semantic facts in linear time, without reporting geometry changes.
/// Scoped content and independent child anchors constrain correspondence; ambiguous pairs stay unresolved.
nonisolated enum HumanInterventionChanges {
    struct Pair {
        let before: PerceptionCore.SceneElement?
        let after: PerceptionCore.SceneElement?
        var reason: HumanInterventionIdentity.Reason = .scopedContent
    }

    static func pairs(
        _ before: SceneSnapshot,
        _ after: SceneSnapshot,
        allowsLocationMatching: Bool = true
    ) -> [Pair] {
        let old = before.elements.filter { isRelevant($0) }
        let new = after.elements.filter { isRelevant($0) }
        return HumanInterventionIdentity.match(old, new).map {
            Pair(before: $0.before.map { old[$0] }, after: $0.after.map { new[$0] }, reason: $0.reason)
        }
    }

    /// Named containers can change their content-derived identity while their native children stay fixed.
    /// Two independent stable children and a unique name-bearing control attest the correspondence.
    static func renamedContainers(_ before: SceneSnapshot, _ after: SceneSnapshot) -> [Pair] {
        let old = Dictionary(grouping: before.elements.filter { $0.container != nil && $0.role != nil }) {
            $0.container ?? ""
        }
        let new = Dictionary(grouping: after.elements.filter { $0.container != nil && $0.role != nil }) {
            $0.container ?? ""
        }
        func signature(_ element: PerceptionCore.SceneElement) -> String {
            element.id + ":" + (element.role ?? "")
        }
        let oldCountsBySignature = Dictionary(grouping: before.elements, by: signature).mapValues(\.count)
        let newCountsBySignature = Dictionary(grouping: after.elements, by: signature).mapValues(\.count)
        var anchors: [String: Set<String>] = [:]
        var movingAnchors: [String: Set<String>] = [:]
        for (container, elements) in old where new[container] == nil {
            for element in elements {
                let key = element.id + ":" + (element.role ?? "") + ":\(element.bounds)"
                anchors[key, default: []].insert(container)
                let independent = signature(element)
                if oldCountsBySignature[independent] == 1 && newCountsBySignature[independent] == 1 {
                    movingAnchors[independent, default: []].insert(container)
                }
            }
        }
        var candidates: [(old: String, new: String)] = []
        for (container, elements) in new where old[container] == nil {
            var votes: [String: Set<String>] = [:]
            for element in elements {
                let key = element.id + ":" + (element.role ?? "") + ":\(element.bounds)"
                let independent = signature(element)
                let candidates = (anchors[key] ?? []).union(movingAnchors[independent] ?? [])
                for previous in candidates { votes[previous, default: []].insert(independent) }
            }
            let matches = votes.keys.filter { (votes[$0]?.count ?? 0) >= 2 }
            if matches.count == 1, let previous = matches.first {
                candidates.append((previous, container))
            }
        }
        let oldCounts = Dictionary(grouping: candidates, by: \.old)
        return candidates.compactMap { candidate in
            guard oldCounts[candidate.old]?.count == 1 else { return nil }
            let oldNames = (old[candidate.old] ?? []).filter { $0.value == candidate.old }
            let newNames = (new[candidate.new] ?? []).filter { $0.value == candidate.new }
            guard oldNames.count == 1, newNames.count == 1,
                  let previous = oldNames.first, let current = newNames.first,
                  previous.role == current.role else { return nil }
            return Pair(before: previous, after: current, reason: .anchoredContainer)
        }
    }

    /// Display roles and numeric formatting identify readouts without interpreting their captions.
    static func isRelevant(_ element: PerceptionCore.SceneElement) -> Bool {
        guard !element.isUnlabeled else { return false }
        let label = element.label.lowercased()
        let numericValue = isNumeric(element.value ?? element.label)
        let editable = editableRoles.contains(element.role ?? "")
        let display = element.kind == .text || displayRoles.contains(element.role ?? "")
        if numericValue && !editable && display { return false }
        if isNumeric(element.label) { return false }
        if element.kind == .text && element.role == nil {
            let words = label.split { !$0.isLetter }
            // OCR has no language attestation; reject fragments and unseparated all-capital noise.
            guard words.contains(where: { word in
                word.count >= 3 && word.contains(where: { "aeiouàèéìòùäöü".contains($0) })
            }) else { return false }
            if element.label.count > 6, !element.label.contains(" "),
               element.label == element.label.uppercased() { return false }
        }
        return true
    }

    /// Numeric readouts do not erase structural facts such as a new row or a changed control label.
    static func hasRelevantValue(_ element: PerceptionCore.SceneElement) -> Bool {
        !displayRoles.contains(element.role ?? "")
            && (!isNumeric(element.value ?? "") || editableRoles.contains(element.role ?? ""))
    }

    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider", "AXStepper",
        "AXCheckBox", "AXRadioButton", "AXSwitch"
    ]

    private static let displayRoles: Set<String> = [
        "AXStaticText", "AXValueIndicator", "AXProgressIndicator", "AXLevelIndicator", "AXMeter"
    ]

    private static let numericCharacters = CharacterSet(charactersIn: "0123456789+-−.,:;| /%°'\"\t\n")

    static func isNumeric(_ text: String) -> Bool {
        var value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["inf", "-inf", "+inf", "−inf"].contains(value) { return true }
        // A suffix is a unit-shaped token, not a domain vocabulary or a translated caption.
        if let unit = value.firstIndex(where: { $0.isLetter }) {
            let suffix = value[unit...]
            guard suffix.allSatisfy({ $0.isLetter || $0.isNumber || "/%°^·−-".contains($0) }) else { return false }
            value = String(value[..<unit]).trimmingCharacters(in: .whitespaces)
        }
        return value.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
            && value.unicodeScalars.allSatisfy(numericCharacters.contains)
    }
}
