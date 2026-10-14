//
//  KnowledgeLocation.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation

/// KnowledgeLocation is the one place that says where the user's knowledge lives: the application
/// support folder of Braus (`BRAUS_APP_SUPPORT_DIR` when set, the user's Application Support otherwise)
/// and, under it, the one Knowledge directory every producer of the user shares, the app's workers, its
/// external MCP clients, `braus` and `braus chat` alike. An explicit directory a caller passes (a test's,
/// `--knowledge`) is used as it is and never resolved here.
///
/// Before G76 each external MCP client kept a private archive in `MCP/Knowledge/<profile>`. Those
/// directories are inventoried here, read only, as the origins the shared archive unifies
/// (`MemoryUnification`); nothing writes to them any more, and nothing removes them.
nonisolated public enum KnowledgeLocation {

    /// The environment variable that moves the whole support folder, for a check run or a test.
    public static let supportOverride = "BRAUS_APP_SUPPORT_DIR"

    /// The support folder: the override when it is set and not empty, else `<Application Support>/Braus`.
    public static func support(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[supportOverride], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Braus", isDirectory: true)
    }

    /// The user's one Knowledge directory under a support folder.
    public static func knowledge(under support: URL) -> URL {
        support.appendingPathComponent("Knowledge", isDirectory: true)
    }

    /// The Knowledge directory of the default support folder.
    public static func knowledge(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        knowledge(under: support(environment: environment))
    }

    /// LegacyKnowledge is one directory of an earlier layout: an external client's private Knowledge, with
    /// what it holds, read without opening or changing anything.
    public struct LegacyKnowledge: Sendable, Equatable {
        /// The origin's identity in the shared archive's journal: `mcp-profile:<profile>`.
        public let originID: String
        /// The directory, and its path relative to the support folder, as the journal records it.
        public let directory: URL
        public let location: String
        /// Whether a SQLite archive is there, and how many JSON Brains.
        public let hasArchive: Bool
        public let jsonBrains: Int

        public var archive: URL { directory.appendingPathComponent("memory.sqlite") }
    }

    /// The external clients' private Knowledge directories under a support folder, by name: each
    /// `MCP/Knowledge/<profile>` that holds an archive or a JSON Brain. An empty one is left out.
    public static func legacyProfiles(under support: URL) -> [LegacyKnowledge] {
        let root  = support.appendingPathComponent("MCP/Knowledge", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        return names.compactMap { name -> LegacyKnowledge? in
            guard !name.hasPrefix(".") else { return nil }
            return inventory(root.appendingPathComponent(name, isDirectory: true), originID: "mcp-profile:\(name)",
                             location: "MCP/Knowledge/\(name)")
        }
    }

    /// One Knowledge directory as an origin: whether it holds an archive, and how many JSON Brains; nil when it is not a
    /// directory or holds neither.
    static func inventory(_ directory: URL, originID: String, location: String) -> LegacyKnowledge? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasArchive = files.contains("memory.sqlite")
        let json = files.filter {
            $0.hasSuffix(".json") && $0 != "allowlist.json" && !$0.contains(".corrupt-")
        }.count
        guard hasArchive || json > 0 else { return nil }
        return LegacyKnowledge(originID: originID, directory: directory, location: location, hasArchive: hasArchive,
                               jsonBrains: json)
    }

    // MARK: The product's earlier name

    /// The origin of the Knowledge directory of the product's earlier name: an archive there is adopted whole by an open
    /// that finds none of its own (`MemoryService`), else taken in like an external client's.
    public static let previousKnowledgeOrigin = "previous-product:knowledge"

    /// The environment variable naming the support folder of the product's earlier name whose knowledge the user's one
    /// archive takes in, for a check run or a test; set and empty, none is read.
    public static let previousSupportOverride = "BRAUS_PREVIOUS_SUPPORT_DIR"

    /// The support folder of the product's earlier name, read only: only the one `BRAUS_PREVIOUS_SUPPORT_DIR` names, and
    /// none by default, so no folder of the person's is read unless someone names it (a check run, a test, a migration
    /// decided). The earlier name is kept nowhere in the product.
    public static func previousSupport(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let named = environment[previousSupportOverride], !named.isEmpty else { return nil }
        return URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The knowledge the product kept under its earlier name, as origins of the user's one archive, inventoried without
    /// opening or changing anything: its Knowledge directory (`previous-product:knowledge`: the archive of the app, the
    /// MCP server and the command line, and its JSON Brains) and its external clients' private ones
    /// (`previous-product:mcp-profile:<name>`). None when that folder is the support folder itself. Profiles,
    /// conversations, credentials and settings of the earlier name are not knowledge and are never read here.
    public static func previousProductOrigins(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [LegacyKnowledge] {
        guard let previous = previousSupport(environment: environment) else { return [] }
        func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        guard resolved(previous) != resolved(support(environment: environment)) else { return [] }
        let name = previous.lastPathComponent
        var origins: [LegacyKnowledge] = []
        if let own = inventory(knowledge(under: previous), originID: previousKnowledgeOrigin, location: "\(name)/Knowledge") {
            origins.append(own)
        }
        for profile in legacyProfiles(under: previous) {
            origins.append(LegacyKnowledge(originID: "previous-product:" + profile.originID, directory: profile.directory,
                                           location: "\(name)/" + profile.location, hasArchive: profile.hasArchive,
                                           jsonBrains: profile.jsonBrains))
        }
        return origins
    }
}
