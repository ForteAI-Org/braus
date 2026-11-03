import Foundation
import CoreFoundation

/// AppGuide is a validated skill-shaped guide supplied by the composition.
public nonisolated struct AppGuide: Sendable, Hashable {
    public struct Header: Sendable, Hashable, Codable {
        public let app: String
        public let appVersions: GuideVersionRange?
        public let locale: String
        public let revision: Int
        public let name: String
        public let description: String
    }

    public struct Section: Sendable, Hashable {
        public let title: String
        public let body: String
        public var text: String { title + "\n" + body }
    }

    public enum ParseError: Error, Sendable, Equatable {
        case invalidUTF8, missingHeader, invalidHeader, unknownKey(String), missingKey(String)
        case invalidVersion, invalidRange, invalidLocale, invalidRevision, invalidHead
        case duplicateSection(String), emptySection(String)
    }

    public let header: Header
    public let head: String
    public let sections: [Section]

    /// Parses strict JSON metadata and complete Markdown sections, normalizing line endings.
    public static func parse(_ markdown: String) throws -> AppGuide {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            throw ParseError.missingHeader
        }
        let data = Data(lines[1..<end].joined(separator: "\n").utf8)
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ParseError.invalidHeader
            }
            object = decoded
        } catch { throw ParseError.invalidHeader }
        let required: Set<String> = ["app", "locale", "revision", "name", "description"]
        try validateKeys(object, allowed: required.union(["appVersions"]), required: required)
        if let range = object["appVersions"], !(range is NSNull) {
            guard let range = range as? [String: Any] else { throw ParseError.invalidRange }
            try validateKeys(range, allowed: ["minimum", "maximum"], required: ["minimum", "maximum"])
        }
        guard let locale = object["locale"] as? String, validLocale(locale) else { throw ParseError.invalidLocale }
        guard let revision = object["revision"] as? NSNumber,
              CFGetTypeID(revision) != CFBooleanGetTypeID(),
              let numericRevision = Int(exactly: revision.doubleValue), numericRevision > 0 else { throw ParseError.invalidRevision }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch let error as ParseError { throw error }
        catch { throw ParseError.invalidHeader }
        guard [header.app, header.name, header.description].allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ParseError.invalidHeader
        }
        var head: [String] = []
        var sections: [Section] = []
        var title: String?
        var body: [String] = []
        var titles: Set<String> = []
        func finish() throws {
            guard let title else { return }
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !text.isEmpty else { throw ParseError.emptySection(title) }
            sections.append(Section(title: title, body: text))
        }
        for line in lines.dropFirst(end + 1) {
            if line.hasPrefix("## ") {
                try finish()
                let next = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                guard titles.insert(next).inserted else { throw ParseError.duplicateSection(next) }
                title = next
                body = []
            } else if title == nil {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { head.append(line) }
            } else { body.append(line) }
        }
        try finish()
        guard (2...3).contains(head.count) else { throw ParseError.invalidHead }
        return AppGuide(header: Header(app: header.app, appVersions: header.appVersions,
            locale: normalizedLocale(locale), revision: header.revision,
            name: header.name, description: header.description), head: head.joined(separator: "\n"), sections: sections)
    }

    private static func validateKeys(_ object: [String: Any], allowed: Set<String>, required: Set<String>) throws {
        if let key = Set(object.keys).subtracting(allowed).sorted().first { throw ParseError.unknownKey(key) }
        if let key = required.subtracting(object.keys).sorted().first { throw ParseError.missingKey(key) }
    }

    private static func normalizedLocale(_ text: String) -> String {
        var extensionStarted = false
        return text.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            .enumerated().map { index, part in
                if part.count == 1 { extensionStarted = true }
                guard index > 0, !extensionStarted else { return String(part) }
                if part.count == 2 { return part.uppercased() }
                if part.count == 4, part.utf8.allSatisfy({ (97...122).contains($0) }) {
                    return part.prefix(1).uppercased() + part.dropFirst()
                }
                return String(part)
            }.joined(separator: "-")
    }

    private static func validLocale(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "_", with: "-").lowercased()
        let grandfathered: Set<String> = [
            "en-gb-oed", "i-ami", "i-bnn", "i-default", "i-enochian", "i-hak", "i-klingon", "i-lux",
            "i-mingo", "i-navajo", "i-pwn", "i-tao", "i-tay", "i-tsu", "sgn-be-fr", "sgn-be-nl",
            "sgn-ch-de", "art-lojban", "cel-gaulish", "no-bok", "no-nyn", "zh-guoyu", "zh-hakka",
            "zh-min", "zh-min-nan", "zh-xiang"
        ]
        if grandfathered.contains(normalized) { return true }
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        func letters(_ value: Substring) -> Bool { value.utf8.allSatisfy { (97...122).contains($0) } }
        func digits(_ value: Substring) -> Bool { value.utf8.allSatisfy { (48...57).contains($0) } }
        guard parts.allSatisfy({ part in
            (1...8).contains(part.count) && part.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0)
            }
        }), let language = parts.first else { return false }
        if language == "x" { return parts.count > 1 }
        guard (2...8).contains(language.count), letters(language) else { return false }
        var cursor = 1
        func current() -> Substring { cursor < parts.count ? parts[cursor] : "" }
        if language.count <= 3 {
            for _ in 0..<3 {
                guard current().count == 3, letters(current()) else { break }
                cursor += 1
            }
        }
        if current().count == 4, letters(current()) { cursor += 1 }
        if (current().count == 2 && letters(current())) || (current().count == 3 && digits(current())) {
            cursor += 1
        }
        var variants: Set<Substring> = []
        while (5...8).contains(current().count)
            || (current().count == 4 && current().first?.isNumber == true) {
            guard variants.insert(current()).inserted else { return false }
            cursor += 1
        }
        var extensions: Set<Substring> = []
        while current().count == 1, current() != "x" {
            guard extensions.insert(current()).inserted else { return false }
            cursor += 1
            let start = cursor
            while (2...8).contains(current().count) { cursor += 1 }
            guard cursor > start else { return false }
        }
        if current() == "x" { return cursor + 1 < parts.count }
        return cursor == parts.count
    }

}

/// GuideVersion compares one to four numeric components with insignificant trailing zeros.
public nonisolated struct GuideVersion: Sendable, Hashable, Codable, Comparable {
    public let components: [UInt]

    public init(components: [UInt]) throws {
        guard (1...4).contains(components.count) else { throw AppGuide.ParseError.invalidVersion }
        var normalized = components
        while normalized.count > 1 && normalized.last == 0 { normalized.removeLast() }
        self.components = normalized
    }

    public static func parse(_ text: String) throws -> Self {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { throw AppGuide.ParseError.invalidVersion }
        let values = try parts.map { part -> UInt in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt(part) else {
                throw AppGuide.ParseError.invalidVersion
            }
            return value
        }
        return try Self(components: values)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text: String
        do { text = try container.decode(String.self) }
        catch { throw AppGuide.ParseError.invalidVersion }
        self = try Self.parse(text)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(components.map(String.init).joined(separator: "."))
    }
}

/// GuideVersionRange includes both numeric bounds.
public nonisolated struct GuideVersionRange: Sendable, Hashable, Codable {
    public let minimum: GuideVersion
    public let maximum: GuideVersion

    public init(minimum: GuideVersion, maximum: GuideVersion) throws {
        guard minimum <= maximum else { throw AppGuide.ParseError.invalidRange }
        self.minimum = minimum
        self.maximum = maximum
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(minimum: values.decode(GuideVersion.self, forKey: .minimum),
                      maximum: values.decode(GuideVersion.self, forKey: .maximum))
    }
}

/// OpenedApp carries resolved version and the person's preferred locale, without platform handles.
public nonisolated struct OpenedApp: Sendable {
    public let bundleID: String
    public let version: GuideVersion?
    public let locale: String

    public init(bundleID: String, version: GuideVersion?, locale: String) {
        self.bundleID = bundleID
        self.version = version
        self.locale = locale
    }
}

/// GuideHead is ready-to-render content selected before formatting.
public nonisolated struct GuideHead: Sendable {
    public let header: AppGuide.Header
    public let text: String

    public init(header: AppGuide.Header, text: String) {
        self.header = header
        self.text = text
    }
}

/// GuideIndex is a selected guide's ordered section titles.
public nonisolated struct GuideIndex: Sendable {
    public let header: AppGuide.Header
    public let titles: [String]

    public init(header: AppGuide.Header, titles: [String]) {
        self.header = header
        self.titles = titles
    }
}
