import Foundation
import Testing
@testable import SeatBroker

/// P13 names parity, the Seat side: an application's names in each of the person's languages its bundle localizes count
/// for the Seat as they do for the launcher, for discovery (`ranked`, the `apps` tool) and for opening (`resolve`)
/// alike, read from the bundle for each call and kept nowhere. Offline on temporary bundles with their own tables;
/// the languages are given explicitly, so nothing depends on the test machine's.
@Suite("P13: the Seat's resolver on names in the person's languages")
struct ApplicationOpeningLocalizedTests {

    static func bundle(_ name: String, id: String, in root: URL, loctable: [String: [String: String]]) throws -> URL {
        let files = FileManager.default
        let app = root.appending(path: "\(name).app")
        let resources = app.appending(path: "Contents/Resources")
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name,
                                   "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        for language in loctable.keys {
            try files.createDirectory(at: resources.appending(path: "\(language).lproj"), withIntermediateDirectories: true)
        }
        try PropertyListSerialization.data(fromPropertyList: loctable, format: .xml, options: 0)
            .write(to: resources.appending(path: "InfoPlist.loctable"))
        return app
    }

    static func app(_ name: String, _ id: String, at url: URL) -> TargetApp {
        TargetApp(pid: nil, bundleID: id, name: name, bundleURL: url, windows: [], bundleName: name)
    }

    static let italian = ["en-IT", "it-IT"]
    static let english = ["en"]

    @Test("with en-IT and it-IT, \"Calendario\" and \"Note\" are discovered and opened as the Apple bundles that declare them, \"Calendar\" and \"Notes\" still are; with en alone the Italian names are refused; discovery and opening agree; Notion Calendar is never meant")
    func italianNamesCount() throws {
        let root = URL.temporaryDirectory.appending(path: "p13-seat-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let calendarURL = try Self.bundle("Calendar", id: "com.apple.iCal", in: root, loctable: [
            "en": ["CFBundleDisplayName": "Calendar", "CFBundleName": "Calendar"],
            "it": ["CFBundleDisplayName": "Calendario", "CFBundleName": "Calendario"],
        ])
        let notesURL = try Self.bundle("Notes", id: "com.apple.Notes", in: root, loctable: [
            "en": ["CFBundleDisplayName": "Notes", "CFBundleName": "Notes"],
            "it": ["CFBundleDisplayName": "Note", "CFBundleName": "Note"],
        ])
        let calendar = Self.app("Calendar", "com.apple.iCal", at: calendarURL)
        let notes = Self.app("Notes", "com.apple.Notes", at: notesURL)
        let notion = Self.app("Notion Calendar", "com.cron.electron", at: URL(fileURLWithPath: "/Applications/Notion Calendar.app"))
        let installed = [notion, calendar, notes]

        for (query, expected) in [("Calendar", "com.apple.iCal"), ("Calendario", "com.apple.iCal"), ("calendario", "com.apple.iCal"),
                                  ("Notes", "com.apple.Notes"), ("Note", "com.apple.Notes")] {
            #expect(ApplicationOpening.ranked(query, in: installed, languages: Self.italian).first?.bundleID == expected,
                    "query: \(query)")
            #expect(try ApplicationOpening.resolve(query, in: installed, languages: Self.italian).bundleID == expected,
                    "query: \(query)")
        }
        // The names the Seat already had stay first and as they were.
        #expect(ApplicationOpening.names(of: calendar, languages: Self.italian).first == "Calendar")
        #expect(ApplicationOpening.names(of: calendar, languages: Self.italian).contains("Calendario"))
        #expect(!ApplicationOpening.names(of: calendar, languages: Self.english).contains("Calendario"))

        // With English alone, the Italian names answer to nothing: refused truthfully, with nothing chosen.
        #expect(ApplicationOpening.ranked("Calendario", in: installed, languages: Self.english).isEmpty)
        #expect(throws: SeatBrokerError.self) { try ApplicationOpening.resolve("Calendario", in: installed, languages: Self.english) }
        // "Note" by its word start still names Notes in English, as before.
        #expect(try ApplicationOpening.resolve("Note", in: installed, languages: Self.english).bundleID == "com.apple.Notes")
    }

    @Test("\"Apple Calendario\" and \"Apple Note\" are Apple's own by their Italian names, never Notion's, for discovery and opening; a third party's \"Calendario\" is not Apple's")
    func appleRuleReadsTheItalianNames() throws {
        let root = URL.temporaryDirectory.appending(path: "p13-seat-apple-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let calendarURL = try Self.bundle("Calendar", id: "com.apple.iCal", in: root, loctable: [
            "en": ["CFBundleDisplayName": "Calendar"], "it": ["CFBundleDisplayName": "Calendario"],
        ])
        let notesURL = try Self.bundle("Notes", id: "com.apple.Notes", in: root, loctable: [
            "en": ["CFBundleDisplayName": "Notes"], "it": ["CFBundleDisplayName": "Note"],
        ])
        let customURL = try Self.bundle("Agenda", id: "com.example.cal", in: root, loctable: [
            "en": ["CFBundleDisplayName": "Agenda"], "it": ["CFBundleDisplayName": "Calendario"],
        ])
        let calendar = Self.app("Calendar", "com.apple.iCal", at: calendarURL)
        let notes = Self.app("Notes", "com.apple.Notes", at: notesURL)
        let notion = Self.app("Notion Calendar", "com.cron.electron", at: URL(fileURLWithPath: "/Applications/Notion Calendar.app"))
        let installed = [notion, calendar, notes]
        #expect(ApplicationOpening.ranked("Apple Calendario", in: installed, languages: Self.italian).map(\.bundleID) == ["com.apple.iCal"])
        #expect(try ApplicationOpening.resolve("Apple Calendario", in: installed, languages: Self.italian).bundleID == "com.apple.iCal")
        #expect(try ApplicationOpening.resolve("Apple Note", in: installed, languages: Self.italian).bundleID == "com.apple.Notes")
        // A third party whose Italian name is "Calendario" is not Apple's: "Apple Calendario" refuses, nothing chosen.
        let custom = Self.app("Agenda", "com.example.cal", at: customURL)
        #expect(ApplicationOpening.ranked("Apple Calendario", in: [notion, custom], languages: Self.italian).isEmpty)
        #expect(throws: SeatBrokerError.self) {
            try ApplicationOpening.resolve("Apple Calendario", in: [notion, custom], languages: Self.italian)
        }
        // "Calendario" alone, with both, names two: refused as ambiguous, both identities named.
        let ambiguity = { () -> String in
            do { _ = try ApplicationOpening.resolve("Calendario", in: installed + [custom], languages: Self.italian); return "resolved" }
            catch { return error.localizedDescription }
        }()
        #expect(ambiguity.contains("names 2 installed applications") && ambiguity.contains("com.apple.iCal")
                && ambiguity.contains("com.example.cal"), "\(ambiguity)")
    }
}
