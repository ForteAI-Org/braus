import EngineCore
import Foundation
import LocalMCP

/// AdapterText writes an adapter's answer as the model reads it: lines of text in place of JSON, the same for every
/// adapter. The JSON (`AdapterOutcome.json`) stays the form of the call's record and of its transcript line.
///
/// An outcome's first line is its word (`word(_:)`) and its message; a top-level text the message already says whole
/// (`says(_:_:)`) is not repeated. Each field is then a `key: value` line: a number or a boolean bare, an ISO 8601
/// instant as `MM-DD HH:mm` in the Mac's time zone (`YYYY-MM-DD HH:mm` outside the current year), a nested object's
/// fields as `key.field`, a list of texts joined by commas. A list of objects is one `key: [k1, k2]` header line, then
/// one `[v1, v2]` line per item: `-` for a missing value, a `\` written `\\`, a `,` `\,`, a `]` `\]` and a line
/// break `\n`. In the listing of a folder (a result whose `path` names it), a path under that folder is written
/// relative to it. A text with a line break, or longer than `blockLength`, comes last after its `key:` line, as it is.
public enum AdapterText {

    /// The format in a few sentences, for the `app_call` description.
    public static let legend = """
        The answer is text: its first line is the outcome (ok, unverified, noop, miss, ambiguous, refused) and the \
        message, then one `key: value` line per field, dates as MM-DD HH:mm in the Mac's time zone (with the year \
        when not this one). A list is one `key: [k1, k2]` line, then one `[v1, v2]` line per item, - for a missing \
        value and \\, for a comma, \\] for a ] and \\\\ for a backslash inside one; in a folder's listing, paths \
        are relative to that folder. A text of several lines, or a long one, comes last after its `key:` line, \
        exactly as it is.
        """

    /// The longest text written on its field's line; a longer one, or one with a line break, is written last.
    static let blockLength = 120

    /// The word an outcome's answer starts with.
    public static func word(_ kind: ActOutcomeKind) -> String {
        switch kind {
            case .foundActed     : "ok"
            case .actedUnverified: "unverified"
            case .actedNoop      : "noop"
            case .honestMiss     : "miss"
            case .ambiguous      : "ambiguous"
            case .refused        : "refused"
            case .dryRun         : "dry_run"
        }
    }

    /// An outcome as the model reads it; `now` is the instant whose year a date leaves out.
    public static func outcome(_ outcome: AdapterOutcome, now: Date = Date()) -> String {
        var lines = ["\(word(outcome.kind)) \(outcome.message)"]
        guard case .object(let fields) = outcome.result else {
            if outcome.result != .null { lines.append(Writer(folder: nil, now: now).scalar(outcome.result)) }
            return lines.joined(separator: "\n")
        }
        let writer = Writer(folder: fields["path"]?.string, now: now)
        var blocks: [String] = []
        for key in ordered(fields.keys) {
            guard let value = fields[key] else { continue }
            if case .string(let text) = value {
                if text.contains("\n") || text.count > blockLength {
                    blocks.append("\(key):\n\(text)")
                    continue
                }
                // The message names it already: a path, a recipient, a title.
                if says(outcome.message, text) { continue }
            }
            lines += writer.lines(key, value)
        }
        return (lines + blocks).joined(separator: "\n")
    }

    /// An adapter's availability and verbs as the model reads them: one line for the adapter, the meaning of each
    /// parameter once (a name the verbs describe apart once per sense, with its verbs), then one line per verb,
    /// `adapter.verb param optional? — summary [safety]`.
    public static func capabilities(
        of adapter  : any AppAdapting,
        availability: AdapterAvailability,
        verbs       : [AdapterVerb]
    ) -> String {
        var lines = ["\(adapter.name) (\(adapter.appNames.joined(separator: ", "))): \(state(availability))"]
        var senses: [(name: String, meaning: String, verbs: [String])] = []
        for verb in verbs {
            for parameter in verb.parameters {
                let meaning = Self.meaning(parameter)
                if let index = senses.firstIndex(where: { $0.name == parameter.name && $0.meaning == meaning }) {
                    senses[index].verbs.append(verb.name)
                } else {
                    senses.append((parameter.name, meaning, [verb.name]))
                }
            }
        }
        for sense in senses {
            let shared = senses.count { $0.name == sense.name } == 1
            lines.append(shared ? "\(sense.name): \(sense.meaning)"
                                : "\(sense.name) (\(sense.verbs.joined(separator: ", "))): \(sense.meaning)")
        }
        for verb in verbs {
            let parameters = verb.parameters.map { $0.isRequired ? $0.name : $0.name + "?" }
            lines.append((["\(adapter.name).\(verb.name)"] + parameters).joined(separator: " ")
                         + " — \(verb.summary) [\(verb.safety.rawValue)]")
        }
        if verbs.isEmpty { lines.append("No verb matches the query.") }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func state(_ availability: AdapterAvailability) -> String {
        switch availability {
            case .ready                      : "ready"
            case .needsPermission(let reason): "needs permission: \(reason)"
            case .unavailable(let reason)    : "unavailable: \(reason)"
            case .unknown(let reason)        : "unknown: \(reason)"
        }
    }

    /// What a parameter takes: its kind when it is not a text, its range or choices, then its summary.
    private static func meaning(_ parameter: AdapterParameter) -> String {
        var parts: [String] = []
        if parameter.kind != .string {
            parts.append(parameter.kind.rawValue + (parameter.range.map {
                " \(Writer.number($0.lowerBound))-\(Writer.number($0.upperBound))"
            } ?? ""))
        }
        if let choices = parameter.choices { parts.append("one of " + choices.joined(separator: "|")) }
        return (parts + [parameter.summary]).joined(separator: ", ")
    }

    /// Whether `message` holds `text` whole: not inside a longer word or number, so `4` is not said by `40`.
    static func says(_ message: String, _ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        func isWord(_ character: Character?) -> Bool { character?.isLetter == true || character?.isNumber == true }
        var searched = message.startIndex..<message.endIndex
        while let found = message.range(of: text, range: searched) {
            let before = found.lowerBound > message.startIndex ? message[message.index(before: found.lowerBound)] : nil
            let after  = found.upperBound < message.endIndex ? message[found.upperBound] : nil
            if !(isWord(before) && isWord(text.first)), !(isWord(after) && isWord(text.last)) { return true }
            searched = message.index(after: found.lowerBound)..<message.endIndex
        }
        return false
    }

    /// Keys in the order a reader looks for them: the identifying ones first, the others by name.
    static func ordered(_ keys: some Collection<String>) -> [String] {
        let first = ["id", "name", "title", "path"]
        return first.filter { keys.contains($0) } + keys.filter { !first.contains($0) }.sorted()
    }

    /// An ISO 8601 instant as `MM-DD HH:mm` in the Mac's time zone, with the year first outside `now`'s year; nil for
    /// any other text, a day alone included.
    static func date(_ text: String, now: Date) -> String? {
        guard text.count >= 16, text.dropFirst(10).first == "T",
              let date = AdapterArguments.date(from: text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%02d-%02d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
                         parts.minute ?? 0)
        let year = parts.year ?? 0
        return year == calendar.component(.year, from: now) ? day : "\(year)-\(day)"
    }

    /// Writer writes the fields of one result: `folder` is the folder a listing names, `now` the instant whose year a
    /// date leaves out.
    private struct Writer {
        let folder: String?
        let now   : Date

        func lines(_ key: String, _ value: JSONValue) -> [String] {
            switch value {
                case .null:
                    return []
                case .object(let fields):
                    return ordered(fields.keys).flatMap { lines("\(key).\($0)", fields[$0] ?? .null) }
                case .array(let items) where !items.isEmpty && items.allSatisfy({ $0.object != nil }):
                    let keys = ordered(Set(items.flatMap { $0.object.map { Array($0.keys) } ?? [] }))
                    return ["\(key): [\(keys.joined(separator: ", "))]"]
                        + items.map { item in "[" + keys.map { cell(item[$0]) }.joined(separator: ", ") + "]" }
                case .array(let items):
                    return items.isEmpty ? [] : ["\(key): " + scalar(value, listed: true)]
                default:
                    return ["\(key): \(scalar(value))"]
            }
        }

        /// A value on one line: a number or a boolean bare, a date short, a line break as `\n`. A listed path under the
        /// listing's folder is relative to it.
        func scalar(_ value: JSONValue, listed: Bool = false, inRow: Bool = false) -> String {
            switch value {
                case .string(let text):
                    var shown = date(text, now: now) ?? text
                    if listed, let folder {
                        let prefix = folder == "~" ? "~/" : folder + "/"
                        if shown.hasPrefix(prefix), shown.count > prefix.count { shown.removeFirst(prefix.count) }
                    }
                    if inRow {
                        for mark in ["\\", ",", "]"] { shown = shown.replacingOccurrences(of: mark, with: "\\" + mark) }
                    }
                    return shown.replacingOccurrences(of: "\n", with: "\\n")
                case .number(let number):
                    return Self.number(number)
                case .bool(let flag):
                    return String(flag)
                case .null:
                    return "-"
                case .array(let items):
                    return items.map { scalar($0, listed: listed, inRow: inRow) }
                        .joined(separator: inRow ? "\\, " : ", ")
                case .object(let fields):
                    return ordered(fields.keys).map { scalar(fields[$0] ?? .null, listed: listed, inRow: inRow) }
                        .joined(separator: " ")
            }
        }

        /// A value in a list's row: as `scalar`, `""` for an empty text, a `\`, `,` and `]` escaped, so the value ends
        /// at its own comma and the row at its own `]`.
        func cell(_ value: JSONValue) -> String {
            value == .string("") ? "\"\"" : scalar(value, listed: true, inRow: true)
        }

        /// A number as a person writes it: without a fraction when it has none.
        static func number(_ number: Double) -> String {
            number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        }
    }
}
