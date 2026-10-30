import Foundation
import PerceptionCore

/// HumanInterventionIdentity matches observations within one surface and collection lifetime, never by geometry. The
/// recognition kind is no identity; pixel text has none, so it is never matched, created, removed or renamed.
nonisolated enum HumanInterventionIdentity {
    enum Reason: String, Sendable {
        case scopedContent, stableControl, anchoredContainer, ambiguous, firstObservation, outsideCoverage
    }

    struct Key: Hashable, Sendable {
        let id: String
        let container: String?
        let role: String?

        init(_ element: PerceptionCore.SceneElement) {
            id = Self.identity(element.id)
            container = element.container
            role = element.role
        }

        /// An id without the recognition kind it starts with: "text|vol" and "control|vol" are one element.
        static func identity(_ id: String) -> String {
            guard let bar = id.firstIndex(of: "|"), id[..<bar].allSatisfy(\.isLetter) else { return id }
            return String(id[id.index(after: bar)...])
        }
    }

    struct Match: Sendable {
        let before: Int?
        let after: Int?
        let reason: Reason
    }

    static func match(_ old: [PerceptionCore.SceneElement], _ new: [PerceptionCore.SceneElement]) -> [Match] {
        // Only elements with an accessibility role carry identity.
        let oldIndices = old.indices.filter { old[$0].role != nil }
        let newIndices = new.indices.filter { new[$0].role != nil }
        let previous = Dictionary(grouping: oldIndices, by: { Key(old[$0]) })
        let current = Dictionary(grouping: newIndices, by: { Key(new[$0]) })
        var pairs: [Int: Int] = [:]
        var used = Set<Int>()
        for index in newIndices {
            let key = Key(new[index])
            let candidates = previous[key] ?? []
            if candidates.count == 1, current[key]?.count == 1, let candidate = candidates.first {
                let lhs = old[candidate]
                let rhs = new[index]
                let unchangedName = lhs.label == rhs.label
                let contentID = lhs.id.contains("|") && normalized(lhs.label) == normalized(rhs.label)
                if unchangedName || contentID {
                    pairs[index] = candidate
                    used.insert(candidate)
                }
            }
        }
        // A key repeated in a read pairs its elements by equal labels, in reading order.
        for (key, indexes) in current where indexes.count > 1 || (previous[key]?.count ?? 0) > 1 {
            var available = (previous[key] ?? []).filter { !used.contains($0) }
            for index in indexes where pairs[index] == nil {
                guard let position = available.firstIndex(where: { old[$0].label == new[index].label }) else { continue }
                pairs[index] = available.remove(at: position)
                used.insert(pairs[index] ?? 0)
            }
        }
        // What is left goes by its role, its name without a count, and its container without counts, in order.
        func fallback(_ element: PerceptionCore.SceneElement) -> String {
            let path = (element.container ?? "").components(separatedBy: " / ").map { normalized(countBase($0)) }
            return [element.role ?? "", normalized(countBase(element.label))].joined(separator: "|") + "|" + path.joined(separator: "/")
        }
        var remaining = Dictionary(grouping: oldIndices.filter { !used.contains($0) }, by: { fallback(old[$0]) })
        for index in newIndices where pairs[index] == nil {
            let key = fallback(new[index])
            guard !normalized(countBase(new[index].label)).isEmpty, var candidates = remaining[key], !candidates.isEmpty else { continue }
            pairs[index] = candidates.removeFirst()
            remaining[key] = candidates
            used.insert(pairs[index] ?? 0)
        }
        var result: [Match] = newIndices.map { index in
            if let before = pairs[index] { return Match(before: before, after: index, reason: .scopedContent) }
            return Match(before: nil, after: index, reason: previous[Key(new[index])] == nil ? .firstObservation : .ambiguous)
        }
        for index in oldIndices where !used.contains(index) {
            result.append(Match(before: index, after: nil, reason: .outsideCoverage))
        }
        return result
    }

    /// A label without the count a collection member shows beside its name: "All iCloud, 71 notes" is "All iCloud".
    static func countBase(_ label: String) -> String {
        guard label.contains(",") else { return label }
        return label.replacingOccurrences(of: #"(,\s*\d[\d.,]*(\s+\p{L}+)?)+$"#, with: "", options: .regularExpression)
    }

    /// A bare count, time or date is never a name: "6 notes", "15:18", "24/08/2026", "Yesterday at 14:04",
    /// "19 Oct 2026 at 14:28". A name holding a number ("Audio 13", "9 Setup guide.pdf") stays a name.
    static func isNameless(_ text: String) -> Bool {
        let flat = text.trimmingCharacters(in: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
        let time = #"\d{1,2}:\d{2}(:\d{2})?(\s?[AaPp]\.?[Mm]\.?)?"#
        let at = #"(,?\s+\p{L}{0,4}\s*"# + time + ")?"
        let shapes = [#"\d[\d.,]*(\s+\p{L}+)?"#, time, #"\d{1,4}[/.\-]\d{1,2}[/.\-]\d{1,4}"# + at,
                      #"(\p{L}+\.?,?\s+)?\d{1,2}(\s+\p{L}+\.?)?,?\s+\d{4}"# + at, #"\p{L}+,?\s+\p{L}{1,4}\s+"# + time]
        return flat.isEmpty || shapes.contains { flat.range(of: "^(" + $0 + ")$", options: .regularExpression) != nil }
    }

    /// The state markers a collection's members lead or end with ("Shown. Drums", "Audio 13. Selected"): a word
    /// and a full stop on more than half of the named members, never part of a name another read shows.
    /// Returns each name without them, with the marker kept as the member's state.
    static func strippingMarkers(_ names: [String], shownElsewhere: (String) -> Bool) -> [(name: String, state: String?)] {
        let lead = #"^\p{L}+\. (?=\S)"#, trail = #"(?<=\S)\. \p{L}+\.?$"#
        func marked(_ pattern: String) -> Bool {
            let hits = names.filter { $0.range(of: pattern, options: .regularExpression) != nil }
            return hits.count * 2 > names.count && !hits.contains(where: shownElsewhere)
        }
        let leading = marked(lead), trailing = marked(trail)
        return names.map { name in
            var rest = name
            var states: [String] = []
            for (pattern, on) in [(lead, leading), (trail, trailing)] where on {
                guard let range = rest.range(of: pattern, options: .regularExpression) else { continue }
                states.append(rest[range].trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
                rest.removeSubrange(range)
            }
            return (rest, states.isEmpty ? nil : states.joined(separator: ", "))
        }
    }

    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// A native name supplies the independent anchor for a decorated visual caption.
    static func decoratedBase(_ label: String, nativeNames: Set<String>) -> String? {
        // Strip only a punctuation prefix, then require the exact independently observed name.
        // Lookup is linear in the caption length rather than scanning every name in the scene.
        let suffix = String(label.drop(while: { !$0.isLetter && !$0.isNumber }))
        return suffix != label && nativeNames.contains(suffix) ? suffix : nil
    }
}
