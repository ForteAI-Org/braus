//
//  ChromeOnboardingTests.swift
//  Braus
//

import Foundation
import Testing
@testable import ChromeProfiles

/// What Settings, Chrome Profiles writes, on temporary folders only: a Chrome's registration of Braus's host,
/// written, updated and removed only when it is Braus's own, never over a file Braus did not write, a link or an
/// unreadable manifest, and never for a Chrome that has no user data folder; the launcher a non-default hub needs;
/// the extension folder prepared and updated from the copy the app carries, and left alone when it is not Braus's.
/// No Chrome runs and nothing of the person's is touched.
@Suite("Chrome profiles: connecting Chrome and preparing the extension", .serialized)
struct ChromeOnboardingTests {

    /// A temporary folder holding a fake Chrome user data folder and a fake executable host, removed by `clean`.
    struct Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "braus-onboarding-\(UUID().uuidString)", directoryHint: .isDirectory)
        var chrome: URL { root.appending(path: "Google/Chrome", directoryHint: .isDirectory) }
        var host  : String { ChromeOnboardingTests.plain(root.appending(path: "Braus.app/\(helper)")) }
        var other : String { ChromeOnboardingTests.plain(root.appending(path: "Old/Braus.app/\(helper)")) }
        let helper = "Contents/Helpers/braus-chrome-host"

        init(chromeRan: Bool = true) throws {
            for host in [host, other] {
                try FileManager.default.createDirectory(at: URL(filePath: host).deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: URL(filePath: host))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host)
            }
            if chromeRan { try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true) }
        }

        func registration(_ host: String? = nil) -> NativeHostRegistration {
            NativeHostRegistration(userDataDirectory: chrome, hostPath: host ?? self.host)
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    static func manifest(_ registration: NativeHostRegistration) throws -> [String: Any] {
        let data = try Data(contentsOf: registration.manifestURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `url`'s path without percent encoding or a trailing slash.
    static func plain(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: Registration

    @Test("a Chrome that never ran is reported, and nothing is created for it")
    func browserNotFound() throws {
        let fixture = try Fixture(chromeRan: false)
        defer { fixture.clean() }
        let registration = fixture.registration()
        #expect(registration.state() == .browserNotFound)
        #expect(throws: NativeHostRegistration.Failure.self) { try registration.register() }
        #expect(!FileManager.default.fileExists(atPath: fixture.chrome.path(percentEncoded: false)))
    }

    @Test("connecting writes Braus's manifest once, for the extension alone; connecting again changes nothing")
    func registerOnce() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let registration = fixture.registration()
        #expect(registration.state() == .notRegistered)
        #expect(try registration.register() == .registered)
        let manifest = try Self.manifest(registration)
        #expect(manifest["name"] as? String == "dev.forte.braus.chrome_profiles")
        #expect(manifest["path"] as? String == fixture.host)
        #expect(manifest["type"] as? String == "stdio")
        #expect(manifest["allowed_origins"] as? [String] == ["chrome-extension://edkkpkeigbhcbmkpoglcgnklpmoemnje/"])
        let written = try Data(contentsOf: registration.manifestURL)
        let path = Self.plain(registration.manifestURL)
        let date = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate]
        #expect(try registration.register() == .registered)
        #expect(try Data(contentsOf: registration.manifestURL) == written)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == date as? Date)
    }

    @Test("Braus's manifest naming another copy is reported, and updated only when asked")
    func registeredElsewhere() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.registration(fixture.other).register()
        let registration = fixture.registration()
        #expect(registration.state() == .registeredElsewhere(path: fixture.other))
        #expect(try Self.manifest(registration)["path"] as? String == fixture.other, "reading changed nothing")
        #expect(try registration.register() == .registered)
        #expect(try Self.manifest(registration)["path"] as? String == fixture.host)
    }

    @Test("a manifest Braus did not write, a link or an unreadable file is left exactly as it is",
          arguments: ["another program", "extra key", "not JSON", "link", "folder is a link"])
    func foreignLeftAlone(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let registration = fixture.registration()
        let folder = registration.manifestURL.deletingLastPathComponent()
        let elsewhere = fixture.root.appending(path: "elsewhere.json")
        var expected = Data("{\"name\":\"dev.forte.braus.chrome_profiles\",\"path\":\"/usr/bin/true\"}".utf8)
        switch kind {
            case "folder is a link":
                let real = fixture.root.appending(path: "RealHosts", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: real)
            default:
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                switch kind {
                    case "extra key":
                        try registration.register()
                        var manifest = try Self.manifest(registration)
                        manifest["note"] = "edited by hand"
                        expected = try JSONSerialization.data(withJSONObject: manifest)
                        try expected.write(to: registration.manifestURL)
                    case "not JSON":
                        expected = Data("not json".utf8)
                        try expected.write(to: registration.manifestURL)
                    case "link":
                        try expected.write(to: elsewhere)
                        try FileManager.default.createSymbolicLink(at: registration.manifestURL,
                                                                   withDestinationURL: elsewhere)
                    default:
                        try expected.write(to: registration.manifestURL)
                }
        }
        guard case .foreign = registration.state() else {
            Issue.record("\(kind): \(registration.state())")
            return
        }
        #expect(throws: NativeHostRegistration.Failure.self) { try registration.register() }
        #expect(throws: NativeHostRegistration.Failure.self) { try registration.unregister() }
        switch kind {
            case "folder is a link":
                let real = fixture.root.appending(path: "RealHosts", directoryHint: .isDirectory)
                #expect(try FileManager.default.contentsOfDirectory(atPath: Self.plain(real)).isEmpty)
            case "link":
                let link = Self.plain(registration.manifestURL)
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == Self.plain(elsewhere))
                #expect(try Data(contentsOf: elsewhere) == expected)
            default:
                #expect(try Data(contentsOf: registration.manifestURL) == expected)
        }
    }

    @Test("a copy of Braus without its host writes nothing")
    func hostMissing() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let registration = fixture.registration(Self.plain(fixture.root.appending(path: "none/braus-chrome-host")))
        #expect(throws: NativeHostRegistration.Failure.self) { try registration.register() }
        #expect(registration.state() == .notRegistered)
    }

    @Test("disconnecting removes Braus's manifest only")
    func unregister() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let registration = fixture.registration()
        try registration.register()
        #expect(try registration.unregister() == .notRegistered)
        #expect(try registration.unregister() == .notRegistered, "nothing left to remove")
    }

    // MARK: Launcher

    @Test("the host's default hub needs no launcher; another hub gets one that passes its socket")
    func launcher() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let home = fixture.root.appending(path: "home", directoryHint: .isDirectory)
        let standard = HostLauncher.defaultSocket(home: home)
        #expect(HostLauncher.path(host: fixture.host, socket: standard, home: home) == fixture.host)
        try HostLauncher.prepare(host: fixture.host, socket: standard, home: home)
        #expect(!FileManager.default.fileExists(atPath: Self.plain(home)), "nothing written for the default hub")

        let socket = fixture.root.appending(path: "support's/ChromeProfiles/hub.sock").path(percentEncoded: false)
        let launcher = HostLauncher.path(host: fixture.host, socket: socket, home: home)
        #expect(launcher.hasSuffix("/ChromeProfiles/braus-chrome-host-launcher"))
        try HostLauncher.prepare(host: fixture.host, socket: socket, home: home)
        let script = try String(contentsOfFile: launcher, encoding: .utf8)
        #expect(script == "#!/bin/sh\nexec '\(fixture.host)' --socket '"
                    + socket.replacingOccurrences(of: "'", with: "'\\''") + "' \"$@\"\n")
        #expect(FileManager.default.isExecutableFile(atPath: launcher))
        let registration = fixture.registration(launcher)
        #expect(try registration.register() == .registered, "a manifest naming the launcher is Braus's own")
    }

    // MARK: Extension folder

    static func carried(in fixture: Fixture) throws -> URL {
        let source = fixture.root.appending(path: "Braus.app/Contents/Resources/ChromeExtension",
                                            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for file in ExtensionFolder.files {
            try Data("version 1 of \(file)".utf8).write(to: source.appending(path: file))
        }
        return source
    }

    @Test("the extension folder is prepared when asked, then updated from a newer app, file by file")
    func prepareAndUpdate() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let source = try Self.carried(in: fixture)
        let destination = fixture.root.appending(path: "Support/ChromeExtension")
        let folder = ExtensionFolder(source: source, destination: destination)
        #expect(folder.state() == .notPrepared)
        #expect(try folder.prepare() == .current)
        for file in ExtensionFolder.files {
            #expect(try Data(contentsOf: folder.destination.appending(path: file))
                        == Data(contentsOf: source.appending(path: file)))
        }
        try Data("version 2".utf8).write(to: source.appending(path: "background.js"))
        #expect(folder.state() == .outdated)
        #expect(try folder.prepare() == .current)
        #expect(try Data(contentsOf: folder.destination.appending(path: "background.js")) == Data("version 2".utf8))
    }

    @Test("a folder Braus did not prepare, or a link, is left as it is; an app with no extension writes nothing",
          arguments: ["no marker", "link", "not bundled", "outdated then a link"])
    func extensionFolderLeftAlone(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let source = try Self.carried(in: fixture)
        let destination = fixture.root.appending(path: "Support/ChromeExtension", directoryHint: .isDirectory)
        var folder = ExtensionFolder(source: source, destination: destination)
        let mine = fixture.root.appending(path: "MyExtension", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: mine.appending(path: "background.js"))
        switch kind {
            case "no marker":
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("mine".utf8).write(to: destination.appending(path: "background.js"))
            case "link":
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: mine)
            case "outdated then a link":
                // Prepared by Braus, then an old first file and a link in place of a later one.
                try folder.prepare()
                try Data("an older manifest".utf8).write(to: destination.appending(path: "manifest.json"))
                try FileManager.default.removeItem(at: destination.appending(path: "background.js"))
                try FileManager.default.createSymbolicLink(at: destination.appending(path: "background.js"),
                                                           withDestinationURL: mine.appending(path: "background.js"))
                #expect(folder.state() == .foreign("background.js in it is not a file Braus wrote"))
            default:
                folder = ExtensionFolder(source: fixture.root.appending(path: "none"), destination: destination)
        }
        #expect(throws: ExtensionFolder.Failure.self) { try folder.prepare() }
        switch kind {
            case "no marker":
                #expect(try Data(contentsOf: destination.appending(path: "background.js")) == Data("mine".utf8))
                let manifest = Self.plain(destination.appending(path: "manifest.json"))
                #expect(!FileManager.default.fileExists(atPath: manifest))
            case "link":
                #expect(try FileManager.default.contentsOfDirectory(atPath: Self.plain(mine)) == ["background.js"])
            case "outdated then a link":
                let link = Self.plain(destination.appending(path: "background.js"))
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link)
                            == Self.plain(mine.appending(path: "background.js")))
                #expect(try Data(contentsOf: mine.appending(path: "background.js")) == Data("mine".utf8))
                #expect(try Data(contentsOf: destination.appending(path: "manifest.json"))
                            == Data("an older manifest".utf8), "nothing replaced, the out-of-date file included")
            default:
                #expect(folder.state() == .notBundled)
                #expect(!FileManager.default.fileExists(atPath: Self.plain(destination)))
        }
    }

    // MARK: Browsers

    @Test("a fixture's support folder replaces Application Support only when absolute")
    func supportDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        #expect(Self.plain(ChromeBrowser.supportDirectory(environment: [:])) == Self.plain(home))
        #expect(Self.plain(ChromeBrowser.supportDirectory(environment: ["BRAUS_CHROME_SUPPORT_DIR": "relative"]))
                    == Self.plain(home))
        #expect(Self.plain(ChromeBrowser.supportDirectory(environment: ["BRAUS_CHROME_SUPPORT_DIR": "/tmp/fixture"]))
                    == "/tmp/fixture")
        #expect(Self.plain(ChromeBrowser.googleChrome.userDataDirectory(under: URL(filePath: "/tmp/fixture")))
                    == "/tmp/fixture/Google/Chrome")
    }
}
