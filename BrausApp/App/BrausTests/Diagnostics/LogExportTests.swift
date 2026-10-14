//
//  LogExportTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import Foundation
import Testing
@testable import Braus

/// The pure parts of the log export: what `log` is asked, the header that
/// opens the file and the name the save panel proposes.
@Suite("Log export")
struct LogExportTests {

    /// 2 October 2026, 09:42:07 UTC.
    private static let date = Date(timeIntervalSince1970: 1_790_934_127)

    @Test("The log tool is asked for 24 hours of this process and the kit's subsystems")
    func arguments() {
        #expect(LogExport.arguments(processName: "Braus") == [
            "show",
            "--last", "24h",
            "--info",
            "--debug",
            "--style", "compact",
            "--predicate", #"process == "Braus" OR subsystem BEGINSWITH "dev.forte""#
        ])
    }

    @Test("A quote or backslash in the process name stays inside its string")
    func predicateEscapes() {
        #expect(LogExport.predicate(processName: #"Me"cu\m"#)
                == #"process == "Me\"cu\\m" OR subsystem BEGINSWITH "dev.forte""#)
    }

    @Test("The header names the version, commit, system, reports and date, then a blank line")
    func header() {
        let header = LogExport.header(
            version     : "1.0",
            build       : "42",
            commit      : "598669a3",
            system      : "Version 26.3 (Build 25D125)",
            crashReports: 2,
            exportedAt  : Self.date
        )
        #expect(header == """
            Braus 1.0 (42)
            Commit 598669a3
            macOS Version 26.3 (Build 25D125)
            Crash reports attached at the end: 2
            Exported 2026-10-02T09:42:07Z


            """)
    }

    @Test("Reports are the app's own, from the last day, newest first")
    func recentReports() {
        let since = Self.date
        let names = LogExport.recentReports(
            in: [
                (name: "Braus-2026-10-02-090000.ips",     modified: since.addingTimeInterval(10)),
                (name: "Mecum-2026-10-02-100000.ips",     modified: since.addingTimeInterval(30)),
                (name: "Braus-2026-10-01-080000.ips",     modified: since.addingTimeInterval(-1)),
                (name: "Safari-2026-10-02-100000.ips",    modified: since.addingTimeInterval(30)),
                (name: "BrausHelper-2026-10-02-1.ips",    modified: since.addingTimeInterval(30)),
                (name: "Braus-2026-10-02-110000.ips.tmp", modified: since.addingTimeInterval(30)),
                (name: "Braus-2026-10-02-120000.ips",     modified: since)
            ],
            since: since
        )
        #expect(names == [
            "Mecum-2026-10-02-100000.ips",
            "Braus-2026-10-02-090000.ips",
            "Braus-2026-10-02-120000.ips"
        ])
    }

    @Test("The build commit is the stamped file, trimmed, or unknown without it")
    func buildCommit() throws {
        let empty   = try Self.bundle(commit: nil)
        let stamped = try Self.bundle(commit: "598669a3\n")
        #expect(LogExport.buildCommit(in: empty) == "unknown")
        #expect(LogExport.buildCommit(in: stamped) == "598669a3")
    }

    /// A fresh folder bundle, with BuildCommit.txt when `commit` is given.
    /// Each call uses a new path because Foundation caches bundles by path.
    private static func bundle(commit: String?) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let commit {
            try Data(commit.utf8).write(to: folder.appendingPathComponent("BuildCommit.txt"))
        }
        return try #require(Bundle(url: folder))
    }

    @Test("The default file name is local time with no colons or slashes")
    func defaultFileName() throws {
        let rome = try #require(TimeZone(identifier: "Europe/Rome"))
        let name = LogExport.defaultFileName(
            at      : Self.date,
            timeZone: rome
        )
        #expect(name == "Braus Log 2026-10-02 11.42.txt")
        #expect(!name.contains(":"))
        #expect(!name.contains("/"))
    }
}
