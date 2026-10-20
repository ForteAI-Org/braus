import Foundation

/// MacLaunchLog appends one JSON line per launch: what the launched app did to the person's front app and
/// what `revert` did about it. It only records; nothing reads it back to decide. It is there so the launch
/// style can be chosen from data (how often each app grabs the front) rather than from a few launches.
public struct MacLaunchLog: Sendable {

    public struct Entry: Codable, Sendable, Equatable {
        public var bundleID: String
        public var style: MacLaunchStyle?
        /// How many times `revert` brought the person's app back.
        public var reverts: Int
        /// The app was still in front after the launch.
        public var selfActivated: Bool
        public var focusRestored: Bool
        public var personActed: Bool
        /// The app came forward with a dialog or a sheet and was left in front.
        public var dialogInFront: Bool
        public var at: Date
    }

    public static let fileName = "mac-launches.jsonl"

    public let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent(Self.fileName)
    }

    public func append(_ report: MacLaunchReport, at date: Date = Date()) {
        let entry = Entry(bundleID: report.app.bundleID, style: report.style, reverts: report.reverts,
                          selfActivated: report.selfActivated, focusRestored: report.focusRestored,
                          personActed: report.personActedMeanwhile, dialogInFront: report.dialogInFront, at: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }

    /// Every entry, oldest first; a line that cannot be read is skipped.
    public func entries() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
