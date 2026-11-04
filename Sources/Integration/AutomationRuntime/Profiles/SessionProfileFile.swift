import Foundation
import Capabilities

/// SessionProfileFile reads strict JSON overrides relative to the profile's file.
public nonisolated enum SessionProfileFile {
    public nonisolated enum ProfileError: Error, Equatable {
        case unreadable(path: String), unknownPreset(String), unknownKey(String)
        case invalidValue(key: String), missingFile(key: String, path: String)
        case attendedCommandLine
    }

    public static func load(_ url: URL) throws(ProfileError) -> SessionProfile {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw .unreadable(path: url.path) }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProfileError.invalidValue(key: "profile")
            }
            object = decoded
        } catch { throw .invalidValue(key: "profile") }
        try keys(object, allowed: ["preset", "name", "attendance", "level", "memory", "archive", "catalogue",
                                   "takeover", "mandate", "options"])
        let preset: String = try value(object, "preset", default: "cli")
        let base: SessionProfile
        switch preset {
        case "app": base = .app
        case "cli": base = .cli
        case "mcp-client": base = .mcpClient(name: "mcp-client", attendance: .client)
        default: throw .unknownPreset(preset)
        }
        var options = base.options
        if let raw = object["options"] {
            guard let fields = raw as? [String: Any] else { throw .invalidValue(key: "options") }
            try keys(fields, allowed: ["harnessWebSearch", "seatWarmSeconds", "holdsFromPlanToEnd", "providerCredential",
                                      "effort", "guides", "forbiddenApps"])
            options.harnessWebSearch = try value(fields, "harnessWebSearch", default: options.harnessWebSearch)
            options.seatWarmSeconds = try value(fields, "seatWarmSeconds", default: options.seatWarmSeconds)
            guard options.seatWarmSeconds >= 0 else { throw .invalidValue(key: "seatWarmSeconds") }
            options.holdsFromPlanToEnd = try value(fields, "holdsFromPlanToEnd", default: options.holdsFromPlanToEnd)
            options.providerCredential = try value(fields, "providerCredential", default: options.providerCredential)
            options.effort = try value(fields, "effort", default: options.effort)
            options.forbiddenApps = try value(fields, "forbiddenApps", default: options.forbiddenApps)
            if fields["guides"] != nil {
                let paths: [String] = try value(fields, "guides", default: [])
                options.guides = []
                for text in paths { options.guides.append(try path(text, key: "guides", relativeTo: url, mustExist: true)) }
            }
        }
        let archive = try optionalPath(object, "archive", relativeTo: url, mustExist: false) ?? base.archive
        let mandate = try optionalPath(object, "mandate", relativeTo: url, mustExist: true) ?? base.mandate
        let name: String = try value(object, "name", default: base.name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidValue(key: "name") }
        return SessionProfile(attendance: try value(object, "attendance", default: base.attendance),
            level: try value(object, "level", default: base.level), memory: try value(object, "memory", default: base.memory),
            archive: archive, catalogue: try value(object, "catalogue", default: base.catalogue),
            takeover: try value(object, "takeover", default: base.takeover), mandate: mandate, options: options, name: name)
    }

    private static func keys(_ object: [String: Any], allowed: Set<String>) throws(ProfileError) {
        if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) { throw .unknownKey(key) }
    }

    private static func value<T: Decodable>(_ object: [String: Any], _ key: String,
                                            default fallback: T) throws(ProfileError) -> T {
        guard let raw = object[key] else { return fallback }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
            return try JSONDecoder().decode(T.self, from: data)
        } catch { throw .invalidValue(key: key) }
    }

    private static func optionalPath(_ object: [String: Any], _ key: String, relativeTo url: URL,
                                     mustExist: Bool) throws(ProfileError) -> URL? {
        guard let raw = object[key] else { return nil }
        guard let text = raw as? String else { throw .invalidValue(key: key) }
        return try path(text, key: key, relativeTo: url, mustExist: mustExist)
    }

    private static func path(_ text: String, key: String, relativeTo url: URL,
                             mustExist: Bool) throws(ProfileError) -> URL {
        guard !text.isEmpty else { throw .invalidValue(key: key) }
        let expanded = (text as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        if mustExist && !FileManager.default.fileExists(atPath: resolved.path) {
            throw .missingFile(key: key, path: resolved.path)
        }
        return resolved
    }
}
