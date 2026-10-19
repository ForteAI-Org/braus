import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// The adapters' answers as the model reads them: one format for every adapter, from the JSON the records keep.
@Suite("Adapter answers as text")
struct AdapterTextTests {

    /// An ISO 8601 instant of the Mac's time zone, as the adapters write one.
    private static func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static let now = { () -> Date in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
    }()

    @Test("the first line is the outcome's word and the message; each field a key: value line, numbers bare")
    func scalars() {
        let outcome = AdapterOutcome(.actedUnverified, "Wrote 6 bytes to ~/notes.txt.", result: .object([
            "path"   : .string("~/notes.txt"),
            "bytes"  : .number(6),
            "ratio"  : .number(2.5),
            "cut"    : .bool(false),
            "missing": .null,
            "event"  : .object(["title": .string("Lunch"), "all_day": .bool(true)]),
            "to"     : .array([.string("a@x.com"), .string("b@x.com")]),
        ]))
        #expect(AdapterText.outcome(outcome, now: Self.now) == """
            unverified Wrote 6 bytes to ~/notes.txt.
            bytes: 6
            cut: false
            event.title: Lunch
            event.all_day: true
            ratio: 2.5
            to: a@x.com, b@x.com
            """, "the path the message says is not repeated, a null is left out")
        #expect(AdapterText.word(.foundActed) == "ok" && AdapterText.word(.honestMiss) == "miss"
                && AdapterText.word(.actedNoop) == "noop" && AdapterText.word(.refused) == "refused")
        #expect(AdapterText.outcome(.refused("Nothing was done."), now: Self.now) == "refused Nothing was done.")
    }

    @Test("a field is repeated unless the message says it whole, not inside a longer word or number")
    func repetition() {
        let outcome = AdapterOutcome.confirmed("Read 40 bytes of ~.", .object([
            "path": .string("~"), "size": .string("4"), "unit": .string("byte"),
        ]))
        #expect(AdapterText.outcome(outcome, now: Self.now) == "ok Read 40 bytes of ~.\nsize: 4\nunit: byte")
    }

    @Test("a list of objects is one header of its keys and one row per item: - for a missing value, \\, comma and ] escaped")
    func lists() {
        let outcome = AdapterOutcome.confirmed("2 matches under ~/Documents.", .object([
            "path"   : .string("~/Documents"),
            "matches": .array([
                .object(["name": .string("Report 2026.md"), "path": .string("~/Documents/Work/Report 2026.md"),
                         "bytes": .number(40)]),
                .object(["name": .string("a]b\nc"), "path": .string("~/Elsewhere/x, y\\z"), "note": .string("")]),
            ]),
            "entries": .array([.object(["label": .string("mobile"), "value": .string("+39 333")])]),
        ]))
        #expect(AdapterText.outcome(outcome, now: Self.now) == #"""
            ok 2 matches under ~/Documents.
            entries: [label, value]
            [mobile, +39 333]
            matches: [name, path, bytes, note]
            [Report 2026.md, Work/Report 2026.md, 40, -]
            [a\]b\nc, ~/Elsewhere/x\, y\\z, -, ""]
            """#, "a path under the listing's folder is relative to it, never escaped")
    }

    @Test("a text of several lines, or a long one, comes last after its key line, as it is")
    func longText() {
        let long = String(repeating: "0123456789", count: 13)
        let outcome = AdapterOutcome.confirmed("Read it.", .object([
            "text": .string("# Title\n\nA ] stays, \"quoted\".\n"), "bytes": .number(30), "line": .string(long),
            "short": .string("one line"),
        ]))
        #expect(AdapterText.outcome(outcome, now: Self.now) == """
            ok Read it.
            bytes: 30
            short: one line
            line:
            \(long)
            text:
            # Title

            A ] stays, "quoted".

            """)
    }

    @Test("an ISO 8601 instant is MM-DD HH:mm in the Mac's time zone, with the year outside the current one")
    func dates() {
        let outcome = AdapterOutcome.confirmed("2 events.", .object([
            "start"   : .string(Self.instant(2026, 10, 20, 9, 5)),
            "end"     : .string(Self.instant(2027, 1, 2, 18, 30)),
            "birthday": .string("1931-07-14"),
            "events"  : .array([.object(["start": .string(Self.instant(2026, 3, 1, 23, 59))])]),
        ]))
        #expect(AdapterText.outcome(outcome, now: Self.now) == """
            ok 2 events.
            birthday: 1931-07-14
            end: 2027-01-02 18:30
            events: [start]
            [03-01 23:59]
            start: 10-20 09:05
            """, "a day alone is not an instant and stays as it is")
    }

    @Test("capabilities: one line for the adapter, each argument's meaning once, then one line per verb")
    func capabilities() {
        let path  = AdapterParameter("path", .string, "a path: ~ is the home folder")
        let verbs = [
            AdapterVerb("read", "Read a file.", parameters: [
                path, AdapterParameter("max_bytes", .integer, "how many bytes", required: false, range: 1...65536),
            ], safety: .read, readBack: "the text"),
            AdapterVerb("copy", "Copy a file.", parameters: [path, AdapterParameter("to", .string, "the new path")],
                        safety: .write, readBack: "the copy"),
            AdapterVerb("send", "Send it.", parameters: [
                AdapterParameter("to", .string, "an address"),
                AdapterParameter("mode", .string, "how", required: false, choices: ["fast", "slow"]),
                AdapterParameter("quiet", .boolean, "say nothing", required: false),
            ], safety: .irreversible, readBack: "the sent box", confirms: .readBack),
        ]
        let text = AdapterText.capabilities(of: Named(), availability: .needsPermission("Allow it."), verbs: verbs)
        #expect(text == """
            named (Named, Other): needs permission: Allow it.
            path: a path: ~ is the home folder
            max_bytes: integer 1-65536, how many bytes
            to (copy): the new path
            to (send): an address
            mode: one of fast|slow, how
            quiet: boolean, say nothing
            named.read path max_bytes? — Read a file. [read]
            named.copy path to — Copy a file. [write]
            named.send to mode? quiet? — Send it. [irreversible]
            """)
        #expect(AdapterText.capabilities(of: Named(), availability: .ready, verbs: [])
                    .hasSuffix("No verb matches the query."))
    }

    @Test("the files adapter's capabilities take less than half of their JSON")
    func filesCapabilitiesAreSmaller() async throws {
        let listing = await AppAdapters([FilesAdapter()]).capabilities(of: "files", query: nil)
        let json    = try JSONEncoder().encode(listing.json)
        #expect(listing.text.hasPrefix("files (Files, Finder): "))
        #expect(listing.text.components(separatedBy: "path: a path: ~ is the home folder").count == 2, "said once")
        #expect(listing.text.utf8.count * 2 < json.count, "\(listing.text.utf8.count) of \(json.count)")
    }
}

/// Named is an adapter with no verbs of its own, for the capabilities' header.
private struct Named: AppAdapting {
    let name                 = "named"
    let appNames             = ["Named", "Other"]
    let bundleIDs: Set<String> = []
    let verbs: [AdapterVerb] = []

    func availability() async -> AdapterAvailability { .ready }
    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome { .refused("none") }
}
