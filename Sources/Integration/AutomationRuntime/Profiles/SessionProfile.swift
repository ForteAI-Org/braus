import Capabilities
import Foundation
import LocalMCP

/// SessionProfile fixes a session's permissions and resources at composition.
public nonisolated struct SessionProfile: Sendable, Equatable, Codable {
    public typealias Attendance = ToolList.Attendance
    public typealias Level = ToolList.Level
    public nonisolated enum Memory: String, Sendable, Codable, CaseIterable { case off, read, learn, readLearn }
    public nonisolated enum Catalogue: String, Sendable, Codable { case open, openAndPrivate = "open+private" }

    public let attendance: Attendance
    public let level: Level
    public let memory: Memory
    public let archive: URL?
    public let catalogue: Catalogue
    public let takeover: Bool
    public let mandate: URL?
    public let options: Options
    public let name: String

    public init(attendance: Attendance, level: Level, memory: Memory, archive: URL? = nil,
                catalogue: Catalogue, takeover: Bool, mandate: URL? = nil, options: Options, name: String) {
        self.attendance = attendance
        self.level = level
        self.memory = memory
        self.archive = archive
        self.catalogue = catalogue
        self.takeover = takeover
        self.mandate = mandate
        self.options = options
        self.name = name
    }

    /// Reports permissions and resource counts without disclosing profile text or local identifiers.
    public var status: JSONValue {
        .object([
            "readsMemory": .bool(memory.reads), "learnsMemory": .bool(memory.learns),
            "enrichesScenes": .bool(memory.enrichesScenes), "takeover": .bool(takeover),
            "attended": .bool(attendance != .none), "canAct": .bool(level != .observe),
            "allowsConnectors": .bool(level == .actConnectors),
            "hasArchive": .bool(archive != nil), "hasMandate": .bool(mandate != nil),
            "includesPrivateCatalogue": .bool(catalogue == .openAndPrivate),
            "options": .object([
                "harnessWebSearch": .bool(options.harnessWebSearch), "seatWarmSeconds": .number(Double(options.seatWarmSeconds)),
                "holdsFromPlanToEnd": .bool(options.holdsFromPlanToEnd),
                "hasProviderCredential": .bool(options.providerCredential != .none),
                "hasEffort": .bool(options.effort != nil),
                "guideCount": .number(Double(options.guides.count)),
                "forbiddenAppCount": .number(Double(options.forbiddenApps.count))
            ])
        ])
    }

    public var memoryAccess: MemoryAccess {
        MemoryAccess(reads: memory.reads, learns: memory.learns, enrichesScenes: memory.enrichesScenes)
    }

    /// Returns the profile with composition overrides, keeping all other values fixed.
    public func replacing(memory: Memory? = nil, archive: URL? = nil, options: Options? = nil) -> Self {
        Self(attendance: attendance, level: level, memory: memory ?? self.memory, archive: archive ?? self.archive,
             catalogue: catalogue, takeover: takeover, mandate: mandate, options: options ?? self.options, name: name)
    }
}

extension SessionProfile.Memory {
    public nonisolated var reads: Bool { self == .read || self == .readLearn }
    public nonisolated var learns: Bool { self == .learn || self == .readLearn }
    public nonisolated var enrichesScenes: Bool { self != .off }
    public nonisolated var teachesBrain: Bool { learns }
}
