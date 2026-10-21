import Foundation
import LocalMCP

/// AdapterVerb is one thing an adapter does: its name, a one-line description, its parameters, its
/// safety class and the read-back it promises. The parameters are the verb's whole schema: an
/// argument it does not list is refused before the adapter runs.
public struct AdapterVerb: Sendable, Equatable {

    /// The verb's name within its adapter, such as `create_event`. The tools also accept it
    /// qualified by the adapter, `calendar.create_event`.
    public typealias Name = String

    /// How far a verb reaches. `irreversible` verbs (send, delete, trash) run only when the engine's
    /// per-call approver allows them and their read-back contract can confirm the change.
    public enum Safety: String, Sendable, Equatable {
        case read, write, irreversible
    }

    /// Confirmation is how a verb confirms its change: `readBack` answers confirmed only from what it reads back after
    /// the change, through `AdapterOutcome.afterChange`; `none` promises nothing. An irreversible verb runs only with
    /// `readBack`, and its confirmed answer counts only when that read-back gave it (`IrreversiblePolicy`).
    public enum Confirmation: String, Sendable, Equatable {
        case readBack = "read_back"
        case none
    }

    public let name       : Name
    public let summary    : String
    public let parameters : [AdapterParameter]
    public let safety     : Safety
    /// How the adapter confirms the effect, in one phrase: what it reads after the call. A description for the model,
    /// not the contract: that is `confirmation`.
    public let readBack   : String
    public let confirmation: Confirmation
    /// The fields of the verb's result that hold a file's content (`files.read`'s `text`): the model reads them; the
    /// transcript line of the answer keeps the marker in their place, as it does for a content parameter.
    public let contentResults: [String]
    /// What of the verb's result is confidential content (P1-06): the model reads all of it; the record and the
    /// transcript keep none of its confidential fields.
    public let resultConfidentiality: ResultConfidentiality
    /// The parameter that names the account the verb acts from (P2-05), such as a mail's `from`: absent, the service
    /// uses its own default, which the record says without naming it. Nil for a verb that names no account.
    public let accountParameter: String?

    /// ResultConfidentiality is what of a verb's result the records may keep. `ordinary` keeps it all, as before.
    /// `confidential` withholds every text of it except the fields named, however deep: identifiers, dates and flags
    /// that say which item and when, never what it says or who it names.
    public enum ResultConfidentiality: Sendable, Equatable {
        case ordinary
        case confidential(keeping: Set<String>)

        /// The fields a confidential result keeps: an item's identifier, its dates and its flags.
        public static let identifiersAndDates = ResultConfidentiality.confidential(keeping: [
            "id", "calendar", "list", "date", "modified", "start", "end", "due", "all_day", "read", "completed",
            "writable", "default",
        ])
    }

    /// The confidential texts of a result of this verb: every string of it outside the fields its confidentiality keeps,
    /// in order, each once. Empty for an ordinary verb.
    public func confidentialTexts(of result: JSONValue) -> [String] {
        guard case .confidential(let keeping) = resultConfidentiality else { return [] }
        var texts: [String] = []
        func walk(_ value: JSONValue) {
            switch value {
                case .string(let text)  : if !text.isEmpty, !texts.contains(text) { texts.append(text) }
                case .array(let items)  : items.forEach(walk)
                case .object(let fields):
                    for (key, field) in fields.sorted(by: { $0.key < $1.key }) where !keeping.contains(key) { walk(field) }
                default                 : break
            }
        }
        walk(result)
        return texts
    }

    public init(
        _ name        : Name,
        _ summary     : String,
        parameters    : [AdapterParameter] = [],
        safety        : Safety,
        readBack      : String,
        confirms      : Confirmation = .none,
        contentResults: [String] = [],
        results       : ResultConfidentiality = .ordinary,
        account       : String? = nil
    ) {
        self.name                  = name
        self.summary               = summary
        self.parameters            = parameters
        self.safety                = safety
        self.readBack              = readBack
        self.confirmation          = confirms
        self.contentResults        = contentResults
        self.resultConfidentiality = results
        self.accountParameter      = account
    }

    /// The parameters as a JSON schema object, as `app_capabilities` shows them.
    public var schema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters { properties[parameter.name] = parameter.schema }
        return .object([
            "type"                : .string("object"),
            "properties"          : .object(properties),
            "required"            : .array(parameters.filter(\.isRequired).map { .string($0.name) }),
            "additionalProperties": .bool(false),
        ])
    }

    public func json(adapter: String) -> JSONValue {
        .object([
            "verb"     : .string("\(adapter).\(name)"),
            "summary"  : .string(summary),
            "safety"   : .string(safety.rawValue),
            "read_back": .string(readBack),
            "arguments": schema,
        ])
    }

    /// Whether the verb matches a query: every word of it appears in its name or its summary.
    public func matches(_ query: String) -> Bool {
        let haystack = "\(name.replacingOccurrences(of: "_", with: " ")) \(summary)".lowercased()
        return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
    }
}

/// AdapterParameter is one argument of a verb. Dates are ISO 8601 texts, paths are texts that may
/// start with `~`.
public struct AdapterParameter: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        case string, integer, number, boolean
    }

    public let name       : String
    public let kind       : Kind
    public let summary    : String
    public let isRequired : Bool
    /// The only values a string admits, when it is a choice.
    public let choices    : [String]?
    /// The inclusive range a number admits.
    public let range      : ClosedRange<Double>?
    /// Whether an empty string is a value (a text that empties a file, a replacement that removes): false, and
    /// refused, unless the verb says so.
    public let allowsEmpty: Bool
    /// Whether the value is a file's content (a text written, appended, found or put in place): the tools withhold
    /// it from every record, transcript line and echo of the call, as they withhold a typed text.
    public let isContent  : Bool
    /// What the value is to the person (P1-06), field by field: the tools withhold a confidential one from every record
    /// and transcript line of the call, and its answer shows it.
    public let confidentiality: Confidentiality

    /// Confidentiality is what a parameter's value is to the person. `content` is what they wrote, will send or keep (a
    /// mail's subject and body, a message, a note, an event's title or notes); `sensitiveMetadata` names a person, an
    /// address or an account, or searches for one (a recipient, a sender, a query of a mailbox). `ordinary` is kept.
    public enum Confidentiality: String, Sendable, Equatable {
        case ordinary
        case content
        case sensitiveMetadata = "sensitive_metadata"
    }

    public init(
        _ name     : String,
        _ kind     : Kind,
        _ summary  : String,
        required   : Bool = true,
        choices    : [String]? = nil,
        range      : ClosedRange<Double>? = nil,
        allowsEmpty: Bool = false,
        content    : Bool = false,
        confidential: Confidentiality = .ordinary
    ) {
        self.name            = name
        self.kind            = kind
        self.summary         = summary
        self.isRequired      = required
        self.choices         = choices
        self.range           = range
        self.allowsEmpty     = allowsEmpty
        self.isContent       = content
        self.confidentiality = confidential
    }

    var schema: JSONValue {
        var object: [String: JSONValue] = ["type": .string(kind.rawValue), "description": .string(summary)]
        if let choices { object["enum"] = .array(choices.map { .string($0) }) }
        if let range {
            object["minimum"] = .number(range.lowerBound)
            object["maximum"] = .number(range.upperBound)
        }
        return .object(object)
    }

    /// Why a value does not fit the parameter, nil when it fits.
    func problem(with value: JSONValue) -> String? {
        switch (kind, value) {
            case (.string, .string(let text)):
                if text.isEmpty, !allowsEmpty { return "\(name) is empty" }
                if let choices, !choices.contains(text) {
                    return "\(name) must be one of \(choices.joined(separator: ", "))"
                }
                return nil
            case (.integer, .number(let number)):
                guard number.rounded() == number else { return "\(name) must be a whole number" }
                return outOfRange(number)
            case (.number, .number(let number)):
                guard number.isFinite else { return "\(name) must be a finite number" }
                return outOfRange(number)
            case (.boolean, .bool):
                return nil
            default:
                return "\(name) must be a \(kind.rawValue)"
        }
    }

    private func outOfRange(_ number: Double) -> String? {
        guard let range, !range.contains(number) else { return nil }
        return "\(name) must be between \(Self.plain(range.lowerBound)) and \(Self.plain(range.upperBound))"
    }

    /// A number as a person writes it: without a fraction when it has none.
    private static func plain(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}
