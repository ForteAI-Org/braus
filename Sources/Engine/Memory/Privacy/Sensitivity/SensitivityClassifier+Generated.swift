import Foundation

extension SensitivityClassifier {
    /// Whether a word reads as a generated key. An absolute path (`/…` or `~/…`) is judged by its
    /// components, since its slashes join names that are each short and would otherwise add up to a
    /// key's length (live run R01, LV02): it has a key's shape when one component does, whole or as a
    /// shorter random run (`readsRandom`). Any other word, a key with slashes in its alphabet among them,
    /// is judged whole.
    static func looksGenerated(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:()[]{}<>"))
        guard trimmed != "[withheld]" else { return false }
        if let components = pathComponents(trimmed) {
            return components.contains { isGeneratedWord($0) || readsRandom($0) }
        }
        return isGeneratedWord(trimmed)
    }

    /// The characters a generated key is drawn from: letters, digits and the separators of base64.
    private static let keyAlphabet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))

    /// A word of 32 or more characters drawn from a key's alphabet, with upper case, lower case and
    /// digits all present: how generated keys look, and how file names and hashes do not.
    static func isGeneratedWord(_ word: String) -> Bool {
        guard word.count >= 32 else { return false }
        guard word.unicodeScalars.allSatisfy({ keyAlphabet.contains($0) && $0.isASCII }) else { return false }
        let upper = word.contains { $0.isUppercase }, lower = word.contains { $0.isLowercase }
        let digit = word.contains { $0.isNumber }
        return upper && lower && digit
    }

    /// The components of an absolute path, from the root or the home folder, without the empty one a
    /// final slash leaves; nil for any other word, and for one with an empty component inside, which
    /// no path has and a key with slashes may.
    static func pathComponents(_ word: String) -> [String]? {
        let rest: Substring
        if word.hasPrefix("~/") { rest = word.dropFirst(2) } else if word.hasPrefix("/") { rest = word.dropFirst() } else { return nil }
        var components = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty, !components.contains("") else { return nil }
        return components
    }

    /// Whether a path component reads as random though shorter than a key: twelve letters and digits or
    /// more, drawn from a key's alphabet, upper case, lower case and digits all present, and the kind of
    /// character changing between at least half of the adjacent letters and digits, as it does in a
    /// generated string (`aB3dE5fG7hI9jK1l`) and not in a name (`Reports2026`, `BrausAppSupport`).
    static func readsRandom(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        guard scalars.allSatisfy({ keyAlphabet.contains($0) && $0.isASCII }) else { return false }
        func kind(_ scalar: Unicode.Scalar) -> Int? {
            switch scalar.value {
                case 0x41...0x5A: 0
                case 0x61...0x7A: 1
                case 0x30...0x39: 2
                default         : nil
            }
        }
        let kinds = scalars.map(kind)
        let present = Set(kinds.compactMap { $0 })
        guard kinds.compactMap({ $0 }).count >= 12, present.count == 3 else { return false }
        var pairs = 0, changes = 0
        for (left, right) in zip(kinds, kinds.dropFirst()) {
            guard let left, let right else { continue }
            pairs += 1
            if left != right { changes += 1 }
        }
        return changes * 2 >= pairs
    }

}
