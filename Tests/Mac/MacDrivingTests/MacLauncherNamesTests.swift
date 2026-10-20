import Foundation
import MacDriver
import Synchronization
import Testing

/// P13 names parity, the native side: a name is one identity or a refusal that names the identities; "Apple <name>"
/// names Apple's own application of exactly that name, after an identifier or a whole name and never a third party's.
/// Offline on the fake workspace, with the names the real bundles declare; nothing is launched by a resolution.
@Suite("P13: the launcher on \"Apple <name>\" and on two applications of one name")
struct MacLauncherNamesTests {

    static let calendar = MacApp(bundleID: "com.apple.iCal", url: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                                 names: ["Calendar", "Calendario"])
    static let notes = MacApp(bundleID: "com.apple.Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"),
                              names: ["Notes", "Note"])
    static let notion = MacApp(bundleID: "com.cron.electron", url: URL(fileURLWithPath: "/Applications/Notion Calendar.app"),
                               names: ["Notion Calendar"])
    static let person = MacRunningApp(processID: 42, bundleID: "com.google.Chrome", name: "Google Chrome")

    private func workspace(_ apps: [MacApp]) -> FakeWorkspace { FakeWorkspace(apps: apps, front: Self.person) }

    private func launcher(_ workspace: FakeWorkspace) -> MacLauncher {
        MacLauncher(workspace: workspace, reader: FakeTreeReader(isTrusted: true, windows: [:]))
    }

    @Test("\"Apple Calendar\", \"apple notes\" and \"Apple Calendario\" are Apple's own applications of exactly those names, never Notion's; a third party's \"Calendar\" is not Apple's; a literal \"Apple Calendar\" wins by its whole name; an identifier and a path win over everything; a part of a name is nothing")
    func appleAnchored() throws {
        let installed = workspace([Self.notion, Self.calendar, Self.notes])
        #expect(try launcher(installed).resolve("Apple Calendar") == Self.calendar)
        #expect(try launcher(installed).resolve("apple notes") == Self.notes)
        #expect(try launcher(installed).resolve("Apple Calendario") == Self.calendar)
        #expect(try launcher(installed).resolve("Apple Note") == Self.notes)
        let custom = MacApp(bundleID: "com.example.cal", url: URL(fileURLWithPath: "/Applications/Calendar.app"), names: ["Calendar"])
        #expect(throws: MacLaunchFailure.notFound("Apple Calendar")) {
            try launcher(workspace([Self.notion, custom])).resolve("Apple Calendar")
        }
        let literal = MacApp(bundleID: "com.example.applecal", url: URL(fileURLWithPath: "/Applications/Apple Calendar.app"),
                             names: ["Apple Calendar"])
        #expect(try launcher(workspace([Self.notion, Self.calendar, Self.notes, literal])).resolve("Apple Calendar") == literal)
        #expect(try launcher(installed).resolve("com.cron.electron") == Self.notion)
        #expect(try launcher(installed).resolve("/System/Applications/Calendar.app") == Self.calendar)
        #expect(try launcher(installed).resolve("Calendar") == Self.calendar)
        #expect(throws: MacLaunchFailure.notFound("Apple Cal")) { try launcher(installed).resolve("Apple Cal") }
        #expect(installed.state.withLock(\.launches).isEmpty, "a resolution launches nothing")
    }

    @Test("two identities answering to one name are refused by their identifiers, sorted: two Apple calendars for \"Apple Calendar\", two applications named \"Calendar\" for \"Calendar\"; one identifier at two paths is one identity, taken at the path the workspace names; nothing launched")
    func twoOfOneNameAreRefused() throws {
        let twin = MacApp(bundleID: "com.apple.CalendarTwin", url: URL(fileURLWithPath: "/System/Applications/Calendar Twin.app"),
                          names: ["Calendar"])
        let apple = workspace([Self.notion, twin, Self.calendar])
        #expect(throws: MacLaunchFailure.ambiguous("Apple Calendar", ["com.apple.CalendarTwin", "com.apple.iCal"])) {
            try launcher(apple).resolve("Apple Calendar")
        }
        #expect(throws: MacLaunchFailure.ambiguous("Calendar", ["com.apple.CalendarTwin", "com.apple.iCal"])) {
            try launcher(apple).resolve("Calendar")
        }
        let custom = MacApp(bundleID: "com.example.cal", url: URL(fileURLWithPath: "/Applications/Calendar.app"), names: ["Calendar"])
        let mixed = workspace([custom, Self.calendar])
        #expect(throws: MacLaunchFailure.ambiguous("Calendar", ["com.apple.iCal", "com.example.cal"])) {
            try launcher(mixed).resolve("Calendar")
        }
        #expect(try launcher(mixed).resolve("com.example.cal") == custom, "an identifier still resolves one")
        #expect(try launcher(mixed).resolve("Apple Calendar") == Self.calendar, "Apple's alone answers to \"Apple Calendar\"")
        // The same identifier at two paths is one identity: the copy the workspace names for it is the one taken.
        let copy = MacApp(bundleID: "com.apple.iCal", url: URL(fileURLWithPath: "/Users/me/Downloads/Calendar.app"),
                          names: ["Calendar"])
        let doubled = workspace([copy, Self.calendar])
        #expect(try launcher(doubled).resolve("Calendar") == Self.copyOrPreferred(doubled, copy, Self.calendar))
        #expect(try launcher(doubled).resolve("Apple Calendar").bundleID == "com.apple.iCal")
        for fake in [apple, mixed, doubled] { #expect(fake.state.withLock(\.launches).isEmpty) }
    }

    /// The fake answers `application(bundleID:)` with the first app of that identifier it holds: that one is the
    /// path taken, and it is one of the two.
    static func copyOrPreferred(_ workspace: FakeWorkspace, _ a: MacApp, _ b: MacApp) -> MacApp {
        workspace.application(bundleID: a.bundleID) == a ? a : b
    }
}
