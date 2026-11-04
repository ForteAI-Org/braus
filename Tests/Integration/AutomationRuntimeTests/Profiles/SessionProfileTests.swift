import AutomationRuntime
import Capabilities
import Foundation
import LocalMCP
import Testing

@Suite("SessionProfile")
struct SessionProfileTests {
    @Test func presetsMatchTheRegister() {
        #expect(SessionProfile.app.attendance == .app)
        #expect(SessionProfile.app.memory == .readLearn)
        #expect(SessionProfile.app.takeover)
        #expect(SessionProfile.cli.attendance == .none)
        #expect(!SessionProfile.cli.takeover)
        let client = SessionProfile.mcpClient(name: "Juniper", attendance: .client)
        #expect(client.level == .act && client.memory == .read && client.catalogue == .open)
        #expect(client.options.holdsFromPlanToEnd)
    }

    @Test(arguments: SessionProfile.Memory.allCases)
    func memoryPermissionsAreIndependent(_ mode: SessionProfile.Memory) {
        #expect(mode.reads == (mode == .read || mode == .readLearn))
        #expect(mode.learns == (mode == .learn || mode == .readLearn))
        #expect(mode.teachesBrain == mode.learns)
        #expect(mode.enrichesScenes == (mode != .off))
    }

    @Test func credentialsUseAnExplicitSingleKey() throws {
        for value: SessionProfile.ProviderCredential in [.none, .keychainService("Juniper"), .namedVariable("JUNIPER_TOKEN")] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(SessionProfile.ProviderCredential.self, from: data) == value)
            #expect(!String(decoding: data, as: UTF8.self).contains("_0"))
        }
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode(SessionProfile.ProviderCredential.namedVariable(""))
        }
        for json in [#"{"none":false}"#, #"{"none":true,"namedVariable":"X"}"#, #"{"unknown":"X"}"#, #"{"namedVariable":""}"#] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SessionProfile.ProviderCredential.self, from: Data(json.utf8))
            }
        }
    }

    @Test func fileStartsFromAPresetAndRejectsUnknownKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { Issue.record(error) }
        }
        let url = folder.appendingPathComponent("profile.json")
        try Data(#"{"preset":"cli","name":"Juniper","memory":"learn"}"#.utf8).write(to: url)
        let profile = try SessionProfileFile.load(url)
        #expect(profile.name == "Juniper" && profile.memory == .learn && profile.level == .actConnectors)
        try Data(#"{"preset":"cli","typo":true}"#.utf8).write(to: url)
        #expect(throws: SessionProfileFile.ProfileError.unknownKey("typo")) { try SessionProfileFile.load(url) }
    }
}

extension SessionProfileTests {
    @Test func relativePathsResolveFromTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { Issue.record(error) }
        }
        let guide = folder.appendingPathComponent("Juniper.md")
        try Data("A guide".utf8).write(to: guide)
        let url = folder.appendingPathComponent("profile.json")
        try Data(#"{"preset":"cli","archive":"Archive","mandate":"Juniper.md","options":{"guides":["Juniper.md"]}}"#.utf8).write(to: url)
        let profile = try SessionProfileFile.load(url)
        #expect(profile.archive == folder.appendingPathComponent("Archive"))
        #expect(profile.mandate == guide && profile.options.guides == [guide])
        try Data(#"{"options":{"guides":["Absent.md"]}}"#.utf8).write(to: url)
        #expect(throws: SessionProfileFile.ProfileError.missingFile(key: "guides", path: folder.appendingPathComponent("Absent.md").path)) {
            try SessionProfileFile.load(url)
        }
    }

    @Test func removedSwitchesAreRejectedByTheProfileFile() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { do { try FileManager.default.removeItem(at: url) } catch { Issue.record(error) } }
        try Data(#"{"options":{"switches":{"outcome":"v1"}}}"#.utf8).write(to: url)
        #expect(throws: SessionProfileFile.ProfileError.unknownKey("switches")) { try SessionProfileFile.load(url) }
    }

    @Test func profilesRoundTrip() throws {
        for base in [SessionProfile.app, .cli, .mcpClient(name: "Juniper", attendance: .client)] {
            for mode in SessionProfile.Memory.allCases {
                var options = base.options
                options.harnessWebSearch.toggle()
                options.guides = [URL(fileURLWithPath: "/tmp/Juniper.md")]
                let changed = base.replacing(memory: mode, archive: URL(fileURLWithPath: "/tmp/Juniper"), options: options)
                #expect(try JSONDecoder().decode(SessionProfile.self, from: JSONEncoder().encode(changed)) == changed)
            }
        }
    }
}

extension SessionProfileTests {
    @Test func malformedFilesHaveTypedErrors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        #expect(throws: SessionProfileFile.ProfileError.unreadable(path: url.path)) { try SessionProfileFile.load(url) }
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record(error) }
        }
        let cases: [(String, SessionProfileFile.ProfileError)] = [
            (#"{"preset":"juniper"}"#, .unknownPreset("juniper")),
            (#"{"memory":"unknown"}"#, .invalidValue(key: "memory")),
            (#"{"options":{"seatWarmSeconds":-1}}"#, .invalidValue(key: "seatWarmSeconds")),
            (#"{"options":{"unknown":true}}"#, .unknownKey("unknown")),
            (#"{"options":{"providerCredential":{"none":true,"namedVariable":"X"}}}"#, .invalidValue(key: "providerCredential")),
        ]
        for (json, error) in cases {
            try Data(json.utf8).write(to: url)
            #expect(throws: error) { try SessionProfileFile.load(url) }
        }
    }
}

extension SessionProfileTests {
    @Test func cliSeatDefaultPreservesImmediateRelease() {
        #expect(SessionProfile.cli.options.seatWarmSeconds == 0)
        #expect(SessionProfile.app.options.seatWarmSeconds == 30)
    }

    @Test func statusContainsOnlyBooleansAndCounts() throws {
        var options = SessionProfile.cli.options
        options.guides = [URL(fileURLWithPath: "/private/Juniper.md")]
        options.forbiddenApps = ["com.private.Juniper"]
        options.providerCredential = .namedVariable("JUNIPER_TOKEN")
        let profile = SessionProfile.cli.replacing(archive: URL(fileURLWithPath: "/private/archive"), options: options)
        func inspect(_ value: JSONValue) {
            if let fields = value.object { for child in fields.values { inspect(child) }; return }
            switch value {
            case .bool, .number: break
            default: Issue.record("Status contains text or an array")
            }
        }
        inspect(profile.status)
        let text = String(decoding: try JSONEncoder().encode(profile.status), as: UTF8.self)
        #expect(!text.contains("/private") && !text.contains("com.private.Juniper"))
        #expect(!text.contains("JUNIPER_TOKEN"))
    }
}
