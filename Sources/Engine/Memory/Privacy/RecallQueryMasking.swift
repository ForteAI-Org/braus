/// RecallQueryMasking replaces literal task values with their names before credential scrubbing.
/// Matches use the longest text first and then the smallest name; inserted placeholders are never scanned.
public enum RecallQueryMasking {
    /// Returns text safe to retain, ignoring absent, withheld and empty values.
    public static func masked(_ text: String, values: [TaskValue]) -> String {
        let candidates = values.compactMap { value -> (text: String, name: String)? in
            guard case .text(let content) = value.content, !content.isEmpty else { return nil }
            return (content, value.name)
        }.sorted {
            if $0.text.utf8.count != $1.text.utf8.count { return $0.text.utf8.count > $1.text.utf8.count }
            return $0.name < $1.name
        }
        let original = Array(text.utf8)
        let matches = candidates.map { (bytes: Array($0.text.utf8), name: $0.name) }
        var kept = [UInt8]()
        var offset = 0
        while offset < original.count {
            if let match = matches.first(where: { original[offset...].starts(with: $0.bytes) }) {
                kept.append(contentsOf: "{\(match.name)}".utf8)
                offset += match.bytes.count
            } else {
                kept.append(original[offset])
                offset += 1
            }
        }
        return ValueMinimization().minimize(text: String(decoding: kept, as: UTF8.self)).0
    }
}
