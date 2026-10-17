import Foundation
import Testing
@testable import SeatBroker

/// P13, the Seat slice, on the names the real bundles declare (read on 18 October 2026: Calendar.app is
/// `com.apple.iCal`/"Calendar", Notes.app is `com.apple.Notes`/"Notes", Notion Calendar.app is
/// `com.cron.electron`/"Notion Calendar"), offline: the installed list is Spotlight's rows and the folder scan's together,
/// a name nothing answers to is refused truthfully with identities to choose from, and "Apple <name>" is Apple's own
/// application of exactly that name. Synthetic lists and rows; not the exact human turn, not the end-to-end host.
@Suite("P13: the Seat's installed list, refusal and the Apple rule")
struct ApplicationResolverIntakeTests {

    static func app(_ name: String, _ bundleID: String, at path: String, running: Bool = false) -> TargetApp {
        TargetApp(pid: running ? 42 : nil, bundleID: bundleID, name: name, bundleURL: URL(fileURLWithPath: path),
                  windows: [], bundleName: name)
    }

    static func row(_ path: String, _ bundleID: String?, name: String? = nil, lastUsed: Date? = nil)
        -> TargetEnumerator.InstalledRow {
        TargetEnumerator.InstalledRow(path: path, bundleID: bundleID, displayName: name, lastUsed: lastUsed)
    }

    /// A row as `installedApplications` would turn it into an application: named by the file when Spotlight gave no name.
    static func app(of row: TargetEnumerator.InstalledRow) -> TargetApp {
        let url = URL(fileURLWithPath: row.path)
        return TargetApp(pid: nil, bundleID: row.bundleID ?? "", name: row.displayName ?? url.deletingPathExtension().lastPathComponent,
                         bundleURL: url, windows: [], bundleName: nil, version: nil, lastUsed: row.lastUsed)
    }

    static let calendar = app("Calendar", "com.apple.iCal", at: "/System/Applications/Calendar.app")
    static let notes    = app("Notes", "com.apple.Notes", at: "/System/Applications/Notes.app")
    static let notion   = app("Notion Calendar", "com.cron.electron", at: "/Applications/Notion Calendar.app")
    static let safari   = app("Safari", "com.apple.Safari", at: "/Applications/Safari.app")

    static func refusal(_ name: String, in apps: [TargetApp]) -> String {
        do {
            let resolved = try ApplicationOpening.resolve(name, in: apps)
            return "RESOLVED \(resolved.name) (\(resolved.bundleID))"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: F1, the installed list

    @Test("Spotlight's residual row and the folder scan make one complete list: Calendar and Notes are there, Safari keeps Spotlight's date, and \"Calendar\" is Apple's, not Notion's")
    func residualSpotlightAndTheScanAreOneList() throws {
        let used = Date(timeIntervalSince1970: 1_760_000_000)
        let spotlight = [Self.row("/Applications/Safari.app", "com.apple.Safari", name: "Safari", lastUsed: used)]
        let scanned = [
            Self.row("/Applications/Notion Calendar.app", "com.cron.electron"),
            Self.row("/Applications/Safari.app", "com.apple.Safari"),
            Self.row("/System/Applications/Calendar.app", "com.apple.iCal"),
            Self.row("/System/Applications/Notes.app", "com.apple.Notes"),
        ]
        let merged = TargetEnumerator.merged(spotlight: spotlight, scanned: scanned)
        #expect(merged.map(\.path) == ["/Applications/Notion Calendar.app", "/Applications/Safari.app",
                                       "/System/Applications/Calendar.app", "/System/Applications/Notes.app"])
        #expect(merged.first { $0.bundleID == "com.apple.Safari" } == spotlight[0], "Spotlight's row, name and date kept")
        let kept = TargetEnumerator.installable(merged) { _ in nil }
        #expect(kept.count == 4 && kept.first { $0.bundleID == "com.apple.Safari" }?.lastUsed == used)
        let apps = kept.map(Self.app(of:))
        #expect(try ApplicationOpening.resolve("Calendar", in: apps).bundleID == "com.apple.iCal")
        #expect(try ApplicationOpening.resolve("Notes", in: apps).bundleID == "com.apple.Notes")
        #expect(try ApplicationOpening.resolve("Note", in: apps).bundleID == "com.apple.Notes")
        #expect(try ApplicationOpening.resolve("Notion Calendar", in: apps).bundleID == "com.cron.electron")
        // Spotlight answering nothing at all, as with indexing off and no residue: the scan alone is the list.
        let scanOnly = TargetEnumerator.merged(spotlight: [], scanned: scanned)
        #expect(scanOnly.map(\.bundleID) == scanned.sorted { $0.path < $1.path }.map(\.bundleID))
    }

    @Test("at one path, the identifier is the disk's: a Spotlight row without one keeps its date beside the scanned identifier, a stale one loses its name and date to the current identifier, and a path only Spotlight knows is kept as it is")
    func theDiskIdentityAtOnePath() throws {
        let used = Date(timeIntervalSince1970: 1_760_000_000)
        let merged = TargetEnumerator.merged(
            spotlight: [Self.row("/System/Applications/Calendar.app", nil, name: "Calendar", lastUsed: used),
                        Self.row("/Applications/Notion Calendar.app", "com.cron.previous", name: "Cron", lastUsed: used),
                        Self.row("/Users/me/Tools/Elsewhere.app", "com.example.elsewhere", name: "Elsewhere", lastUsed: used),
                        Self.row("/Applications/Broken.app", "com.example.broken", name: "Broken", lastUsed: used)],
            scanned  : [Self.row("/System/Applications/Calendar.app", "com.apple.iCal"),
                        Self.row("/Applications/Notion Calendar.app", "com.cron.electron"),
                        Self.row("/Applications/Broken.app", nil)]
        )
        let byPath = Dictionary(uniqueKeysWithValues: merged.map { ($0.path, $0) })
        // No identifier from Spotlight: the disk's, with Spotlight's name and date beside it.
        #expect(byPath["/System/Applications/Calendar.app"]
                == Self.row("/System/Applications/Calendar.app", "com.apple.iCal", name: "Calendar", lastUsed: used))
        // A stale identifier: the disk's identifier, and nothing of what Spotlight remembered of the other bundle.
        #expect(byPath["/Applications/Notion Calendar.app"] == Self.row("/Applications/Notion Calendar.app", "com.cron.electron"))
        // Only Spotlight knows the path: kept as it is. A scanned bundle with no identifier changes nothing.
        #expect(byPath["/Users/me/Tools/Elsewhere.app"]?.bundleID == "com.example.elsewhere"
                && byPath["/Users/me/Tools/Elsewhere.app"]?.lastUsed == used)
        #expect(byPath["/Applications/Broken.app"]?.bundleID == "com.example.broken")
        let kept = TargetEnumerator.installable(merged) { _ in nil }
        let apps = kept.map(Self.app(of:))
        #expect(try ApplicationOpening.resolve("Calendar", in: apps).bundleID == "com.apple.iCal")
        #expect(try ApplicationOpening.resolve("Notion Calendar", in: apps).bundleID == "com.cron.electron")
        #expect(Self.refusal("Cron", in: apps).hasPrefix("No installed application is named"), "no alias from the stale row")
    }

    @Test("one bundle at two paths keeps the path Launch Services names, and Spotlight's date of the other copy follows it; the filters for nested bundles, the Trash and system helpers are unchanged")
    func metadataFollowsTheIdentifierToThePathKept() {
        let used = Date(timeIntervalSince1970: 1_760_000_000)
        let rows = TargetEnumerator.merged(
            spotlight: [Self.row("/System/Cryptexes/App/System/Applications/Safari.app", "com.apple.Safari",
                                 name: "Safari", lastUsed: used)],
            scanned  : [Self.row("/Applications/Safari.app", "com.apple.Safari"),
                        Self.row("/Applications/Xcode.app/Contents/Applications/Instruments.app", "com.apple.dt.Instruments"),
                        Self.row("/Users/me/.Trash/Old.app", "com.example.Old"),
                        Self.row("/System/Library/Input Methods/CharacterPalette.app", "com.apple.CharacterPaletteIM"),
                        Self.row("/System/Library/CoreServices/Finder.app", "com.apple.finder")]
        )
        let kept = TargetEnumerator.installable(rows) { $0 == "com.apple.Safari" ? "/Applications/Safari.app" : nil }
        #expect(kept.map(\.path) == ["/Applications/Safari.app", "/System/Library/CoreServices/Finder.app"], "\(kept)")
        let safari = kept.first { $0.bundleID == "com.apple.Safari" }
        #expect(safari?.lastUsed == used && safari?.displayName == "Safari", "\(String(describing: safari))")
        // Without a preference the row under /Applications wins, and still takes the date.
        let plain = TargetEnumerator.installable(rows) { _ in nil }
        #expect(plain.first { $0.bundleID == "com.apple.Safari" }?.path == "/Applications/Safari.app"
                && plain.first { $0.bundleID == "com.apple.Safari" }?.lastUsed == used)
    }

    @Test("the folder scan reads the bundles it finds, two levels deep, and a folder that is not there scans as empty")
    func scannedRowsReadTheBundles() throws {
        let root  = URL.temporaryDirectory.appending(path: "p13-scan-\(UUID().uuidString)")
        let files = FileManager.default
        defer { try? files.removeItem(at: root) }
        for (path, bundleID) in [("Calendar.app", "com.apple.iCal"), ("Utilities/Terminal.app", "com.apple.Terminal")] {
            let contents = root.appending(path: "\(path)/Contents")
            try files.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID,
                                                                               "CFBundleName": "X"], format: .xml, options: 0)
            try plist.write(to: contents.appending(path: "Info.plist"))
        }
        try files.createDirectory(at: root.appending(path: "Nameless.app/Contents"), withIntermediateDirectories: true)
        let rows = TargetEnumerator.scannedRows(in: [root, root.appending(path: "not-there")])
        #expect(Set(rows.compactMap(\.bundleID)) == ["com.apple.iCal", "com.apple.Terminal"], "\(rows)")
        #expect(rows.contains { $0.path.hasSuffix("Nameless.app") && $0.bundleID == nil })
        #expect(rows.allSatisfy { $0.displayName == nil && $0.lastUsed == nil })
    }

    // MARK: F2, the refusal

    @Test("a name nothing answers to is refused without claiming the application is not installed: the installed applications sharing a word with it are named, six at most, and none is chosen")
    func truthfulRefusal() {
        let installed = [Self.notion, Self.calendar, Self.notes, Self.safari]
        let pro = Self.refusal("Calendar Pro", in: installed)
        #expect(pro.hasPrefix("No installed application is named \"Calendar Pro\"."), "\(pro)")
        #expect(pro.contains("Calendar — com.apple.iCal") && pro.contains("Notion Calendar — com.cron.electron"), "\(pro)")
        #expect(pro.contains("None was opened") && !pro.contains("not an application installed on this machine"), "\(pro)")
        let word = Self.refusal("Microsoft Word", in: installed)
        #expect(word == "No installed application is named \"Microsoft Word\"; call apps with a shorter query, then "
                + "open_session with the bundleID it lists.", "\(word)")
        let many = (1...8).map { Self.app("Calendar \($0)", "com.example.cal\($0)", at: "/Applications/Calendar \($0).app") }
        let bounded = Self.refusal("Calendar Pro", in: many)
        #expect(bounded.components(separatedBy: "com.example.cal").count - 1 == 6, "\(bounded)")
    }

    // MARK: F3, the anchored Apple rule

    @Test("\"Apple Calendar\" and \"apple notes\" are Apple's own applications of exactly those names; never a third party's, never a part of a name; two Apple applications of one name are refused as ambiguous; none is refused truthfully, nothing opened")
    func appleAnchored() throws {
        let installed = [Self.notion, Self.calendar, Self.notes, Self.safari]
        #expect(try ApplicationOpening.resolve("Apple Calendar", in: installed).bundleID == "com.apple.iCal")
        #expect(try ApplicationOpening.resolve("apple notes", in: installed).bundleID == "com.apple.Notes")
        #expect(try ApplicationOpening.resolve("Apple  Calendar", in: installed).bundleID == "com.apple.iCal")
        // A third party's "Calendar" is not Apple's: refused, named as an identity, not chosen.
        let custom = Self.app("Calendar", "com.example.cal", at: "/Applications/Calendar.app")
        let wrongVendor = Self.refusal("Apple Calendar", in: [Self.notion, custom, Self.notes])
        #expect(wrongVendor.hasPrefix("No installed application is named \"Apple Calendar\".")
                && wrongVendor.contains("Calendar — com.example.cal"), "\(wrongVendor)")
        // Apple's Calendar missing from the list: refused truthfully, with what shares the word, nothing opened.
        let missing = Self.refusal("Apple Calendar", in: [Self.notion, Self.notes])
        #expect(missing.hasPrefix("No installed application is named \"Apple Calendar\".")
                && missing.contains("Notion Calendar — com.cron.electron") && missing.contains("None was opened"), "\(missing)")
        // Two Apple applications of one name: ambiguous, both named by identifier.
        let twin = Self.app("Calendar", "com.apple.CalendarTwin", at: "/System/Applications/Calendar Twin.app")
        let twins = Self.refusal("Apple Calendar", in: installed + [twin])
        #expect(twins.contains("names 2 installed applications") && twins.contains("com.apple.iCal")
                && twins.contains("com.apple.CalendarTwin"), "\(twins)")
        // A part of a name is not the rule: "Apple Cal" names nothing exactly, and is refused.
        #expect(Self.refusal("Apple Cal", in: installed).hasPrefix("No installed application is named \"Apple Cal\""))
        // An application that is literally named "Apple Calendar" wins by its whole name, before the rule.
        let literal = Self.app("Apple Calendar", "com.example.applecal", at: "/Applications/Apple Calendar.app")
        #expect(try ApplicationOpening.resolve("Apple Calendar", in: installed + [literal]).bundleID == "com.example.applecal")
        // A bundle identifier or a whole name still comes first for every other query.
        #expect(try ApplicationOpening.resolve("com.cron.electron", in: installed).bundleID == "com.cron.electron")
        #expect(try ApplicationOpening.resolve("Calendar", in: installed).bundleID == "com.apple.iCal")
    }

    @Test("installable keeps a /System/Applications row, so a listing that holds one is not the filter's loss")
    func systemApplicationsAreInstallable() {
        let rows = [Self.row("/System/Applications/Calendar.app", "com.apple.iCal", name: "Calendar"),
                    Self.row("/Applications/Notion Calendar.app", "com.cron.electron", name: "Notion Calendar")]
        let kept = TargetEnumerator.installable(rows) { _ in nil }
        #expect(kept.map(\.bundleID) == ["com.cron.electron", "com.apple.iCal"], "\(kept)")
    }
}
