import Foundation

/// DataBlock encloses data in a trusted tag, neutralizing embedded closing tags.
public nonisolated enum DataBlock {
    /// Wraps content without changing it except for occurrences of the closing tag. The tag name must be trusted.
    public static func wrap(_ content: String, tag: String) -> String {
        let pattern = "<(?=/" + NSRegularExpression.escapedPattern(for: tag) + "\\s*>)"
        let content = content.replacingOccurrences(
            of: pattern, with: "&lt;", options: [.regularExpression, .caseInsensitive]
        )
        return "<\(tag)>\n\(content)\n</\(tag)>"
    }
}
