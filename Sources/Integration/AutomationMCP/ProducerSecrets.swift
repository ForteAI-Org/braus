import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// ProducerSecrets owns withheld values in memory for the lifetime of this producer.
final class ProducerSecrets {
    /// Values withheld from the record so far (the task's secrets, typed secrets), in memory only, so
    /// every later record withholds them too. Never stored, never shown.
    var secrets: [String] = []

    /// The confidential content the calls so far saw or read (P1-06): withheld from every later record and transcript
    /// line, on any surface, never from an answer, which the model needs to work with. In memory only, the most recent
    /// kept up to `confidentialLimit` of each kind.
    private var confidentialFragments: [String] = []

    private(set) var confidentialValues: [String] = []

    static let confidentialLimit = 2_000

    /// A text the host writes beside these records, such as what a command line's own web search asks or reads
    /// (`WebToolRecords`), with what they withhold withheld: the producer's secrets and the credential shapes (M07).
    func withheld(_ text: String) -> String {
        recordMinimization.minimize(text: text).0
    }

    /// What an answer of the current call may not show the model: the producer's secrets (declared by its task, or
    /// typed into a secure field by an earlier call) and the texts the current call withholds. Credential shapes are
    /// the records' concern, not the answer's.
    var shownMinimization: ValueMinimization {
        ValueMinimization(secrets: secrets, classified: CallScope.current.withheld, scrubsCredentials: false)
    }

    /// What a record or a transcript line of the current call withholds: the producer's secrets, everything the call
    /// withholds (from its answers and from its records only) and the confidential content seen so far (P1-06).
    var recordMinimization: ValueMinimization {
        ValueMinimization(secrets: secrets, classified: CallScope.current.recordClassified)
            .adding(.confidentialContent, fragments: confidentialFragments, wholes: confidentialValues)
    }

    /// A JSON value with every string in it minimized, the keys left as they are.
    static func minimized(_ value: JSONValue, by minimization: ValueMinimization) -> JSONValue {
        switch value {
            case .string(let text)  : return .string(minimization.minimize(text: text).0)
            case .array(let items)  : return .array(items.map { minimized($0, by: minimization) })
            case .object(let fields): return .object(fields.mapValues { minimized($0, by: minimization) })
            default                 : return value
        }
    }

    /// Keeps the values a call withheld, so every later record of this producer withholds them too.
    func collect(from recorder: CallRecorder) async {
        for text in await recorder.withheldTexts where !secrets.contains(text) { secrets.append(text) }
        Self.keep(await recorder.confidentialFragments, in: &confidentialFragments)
        Self.keep(await recorder.confidentialValues, in: &confidentialValues)
    }

    /// Keeps confidential values available live while withholding them from this and every later record.
    func withholdConfidential(_ texts: [String], from recorder: CallRecorder?) async {
        var scope = CallScope()
        for text in texts { Self.withholdContent(text, in: &scope, recordsOnly: true) }
        let protected = Array(scope.recordWithheld.keys)
        await recorder?.withholdConfidential(fragments: protected, wholes: protected)
        Self.keep(Set(protected), in: &confidentialValues)
        Self.keep(Set(protected.filter { $0.count >= ConfidentialSurfaces.shortestTrackedText }), in: &confidentialFragments)
    }

    /// Classifies every string leaf, including those beyond the limit on fields retained for learning.
    private static func confidentialTexts(in value: JSONValue, path: String = "", keeping: (String) -> Bool) -> [String] {
        switch value {
            case .string(let text): return keeping(path) ? [] : [text]
            case .array(let items):
                return items.enumerated().flatMap {
                    confidentialTexts(in: $0.element, path: path + "/\($0.offset)", keeping: keeping)
                }
            case .object(let fields):
                return fields.flatMap {
                    confidentialTexts(in: $0.value, path: path + "/" + StructuredLeaves.escape($0.key), keeping: keeping)
                }
            default: return []
        }
    }

    /// Adds confidential texts to a producer's list, the most recent last, the oldest dropped past the limit.
    private static func keep(_ texts: Set<String>, in list: inout [String]) {
        guard !texts.isEmpty else { return }
        let known = Set(list)
        list += texts.subtracting(known).sorted()
        if list.count > confidentialLimit { list.removeFirst(list.count - confidentialLimit) }
    }

    /// Withholds a content text as written and as JSON escapes it: the record keeps a verb's arguments as JSON text
    /// (`canonical`), where a quote or a line break of the text is escaped. A confidential value (`recordsOnly`) is
    /// withheld from the records and the transcript only, as `confidential_content`.
    static func withholdContent(_ text: String, in scope: inout CallScope, recordsOnly: Bool = false) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var forms = [text]
        if let data = try? encoder.encode(JSONValue.string(text)), data.count > 2 {
            forms.append(String(decoding: data.dropFirst().dropLast(), as: UTF8.self))
        }
        for form in forms {
            if recordsOnly { scope.withholdFromRecords(form, .confidentialContent) } else { scope.withhold(form, .unclassifiedTarget) }
        }
    }

}
