//
//  LogExport.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import Foundation

/// LogExport writes Braus's unified log from the last 24 hours to a file, so a
/// tester can attach it to a bug report without the Terminal.
///
/// The file starts with a short header naming the app version, the build's git
/// commit, the system and the export date, followed by the output of
/// `/usr/bin/log show` and the app's crash reports from the same period. The
/// arguments, the header, the report selection and the default file name are
/// pure so tests can check them without running `log`.
nonisolated enum LogExport {

    /// LogExport.Failure is why `log` produced no usable file.
    struct Failure: LocalizedError {
        let status      : Int32
        let errorExcerpt: String

        var errorDescription: String? {
            let reason = "The log tool stopped with status \(status)."
            return errorExcerpt.isEmpty ? reason : "\(reason)\n\n\(errorExcerpt)"
        }
    }

    /// How far back the export reaches, in `log show --last` notation.
    static let period = "24h"

    /// Selects this process's entries and every entry of the kit's subsystems.
    static func predicate(processName: String) -> String {
        let quoted = processName
            .replacingOccurrences(
                of  : "\\",
                with: "\\\\"
            )
            .replacingOccurrences(
                of  : "\"",
                with: "\\\""
            )
        return "process == \"\(quoted)\" OR subsystem BEGINSWITH \"dev.forte\""
    }

    /// The arguments to `/usr/bin/log`, one element per word.
    static func arguments(processName: String) -> [String] {
        [
            "show",
            "--last", period,
            "--info",
            "--debug",
            "--style", "compact",
            "--predicate", predicate(processName: processName)
        ]
    }

    /// The process names whose crash reports belong to this app, the old name
    /// included because a tester may still have reports under it.
    static let reportPrefixes = ["Braus", "Mecum"]

    /// The file names of crash reports with one of the prefixes modified since
    /// `since`, newest first.
    static func recentReports(
        in entries: [(name: String, modified: Date)],
        prefixes  : [String] = reportPrefixes,
        since     : Date
    ) -> [String] {
        entries
            .filter { entry in
                entry.name.hasSuffix(".ips")
                    && entry.modified >= since
                    && prefixes.contains { entry.name.hasPrefix($0 + "-") }
            }
            .sorted { $0.modified > $1.modified }
            .map(\.name)
    }

    /// The lines that open the file, ending with a blank line before the log.
    static func header(
        version     : String,
        build       : String,
        commit      : String,
        system      : String,
        crashReports: Int,
        exportedAt  : Date
    ) -> String {
        """
        Braus \(version) (\(build))
        Commit \(commit)
        macOS \(system)
        Crash reports attached at the end: \(crashReports)
        Exported \(exportedAt.ISO8601Format())


        """
    }

    /// The name the save panel proposes, in local time and without colons,
    /// which Finder shows as slashes.
    static func defaultFileName(
        at date : Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter        = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.timeZone   = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Braus Log \(formatter.string(from: date)).txt"
    }

    /// The commit the build phase "Stamp Commit" wrote into the bundle, or
    /// "unknown" when the file is missing or empty.
    static func buildCommit(in bundle: Bundle = .main) -> String {
        let commit = bundle.url(forResource: "BuildCommit", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return commit.isEmpty ? "unknown" : commit
    }

    /// Writes the header, streams `log show` into the file at `url` and then
    /// appends the app's crash reports of the same period.
    ///
    /// The process runs on a global queue and writes straight into the file,
    /// so the log is never held in memory. On any failure the partial file is
    /// removed and the error is thrown.
    static func export(to url: URL) async throws {
        let info    = Bundle.main.infoDictionary ?? [:]
        let now     = Date.now
        let reports = crashReportFiles(since: now.addingTimeInterval(-24 * 3600))
        let header  = header(
            version     : info["CFBundleShortVersionString"] as? String ?? "unknown",
            build       : info["CFBundleVersion"] as? String ?? "unknown",
            commit      : buildCommit(),
            system      : ProcessInfo.processInfo.operatingSystemVersionString,
            crashReports: reports.count,
            exportedAt  : now
        )
        let arguments = arguments(processName: ProcessInfo.processInfo.processName)
        do {
            try Data(header.utf8).write(to: url)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Result {
                            try runLog(
                                arguments: arguments,
                                appending: url
                            )
                            try append(
                                reports,
                                to: url
                            )
                        }
                    )
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// The crash reports of this app in the system's report folder, newest first.
    private static func crashReportFiles(since: Date) -> [URL] {
        let folder = URL.libraryDirectory.appending(path: "Logs/DiagnosticReports")
        let files  = (try? FileManager.default.contentsOfDirectory(
            at                        : folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let entries = files.map { file in
            (
                name    : file.lastPathComponent,
                modified: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            )
        }
        return recentReports(
            in   : entries,
            since: since
        ).map { folder.appending(path: $0) }
    }

    /// Appends each report under a line naming it, so one file carries the lot.
    private static func append(
        _ reports: [URL],
        to url   : URL
    ) throws {
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.seekToEnd()
        for report in reports {
            try output.write(contentsOf: Data("\n\n===== Crash report \(report.lastPathComponent) =====\n".utf8))
            // A report that vanished or is unreadable leaves its title line only.
            try output.write(contentsOf: (try? Data(contentsOf: report)) ?? Data())
        }
    }

    /// Runs `log` to completion with its output appended to the file, blocking
    /// the calling thread until it exits.
    private static func runLog(
        arguments    : [String],
        appending url: URL
    ) throws {
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.seekToEnd()

        let errors                = Pipe()
        let process               = Process()
        process.executableURL     = URL(filePath: "/usr/bin/log")
        process.arguments         = arguments
        process.standardOutput    = output
        process.standardError     = errors
        try process.run()

        // Read stderr before waiting, so a full pipe cannot hold the process.
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let excerpt = String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n")
                .prefix(5)
                .joined(separator: "\n")
            throw Failure(
                status      : process.terminationStatus,
                errorExcerpt: excerpt
            )
        }
    }
}
