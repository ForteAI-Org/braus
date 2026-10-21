//
//  NativeHostRegistration.swift
//  Braus
//

import Foundation

/// NativeHostRegistration is one Chrome's registration of Braus's native messaging host: the manifest
/// `dev.forte.braus.chrome_profiles.json` in the `NativeMessagingHosts` folder of that Chrome's user data folder,
/// which lets every profile of that Chrome start the host for the Braus extension, and only for it.
///
/// It writes only when asked, and only a manifest of Braus's own: it creates one where there is none, and
/// updates one Braus wrote that names another host (another copy of Braus, or the app moved). A file Braus did
/// not write, a link, or a manifest it cannot read is left exactly as it is, and so is a Chrome that never ran
/// (no user data folder): Braus creates no browser folder. Removing takes away only a manifest of Braus's own.
public struct NativeHostRegistration: Sendable {

    public static let hostName    = "dev.forte.braus.chrome_profiles"
    public static let extensionID = "edkkpkeigbhcbmkpoglcgnklpmoemnje"
    public static var extensionOrigin: String { "chrome-extension://\(extensionID)/" }
    /// The description of every manifest Braus writes, part of how it recognizes its own.
    static let description = "Braus: relays the Braus extension of a paired Chrome profile to the Braus app"
    /// The names of the hosts a manifest of Braus's names: the host the app carries, or its launcher.
    static let hostFileNames: Set<String> = ["braus-chrome-host", HostLauncher.fileName]

    /// The Chrome's user data folder.
    public let userDataDirectory: URL
    /// The absolute path of the host the manifest should name.
    public let hostPath: String

    public init(userDataDirectory: URL, hostPath: String) {
        self.userDataDirectory = userDataDirectory
        self.hostPath          = hostPath
    }

    public var manifestURL: URL {
        userDataDirectory.appending(path: "NativeMessagingHosts/\(Self.hostName).json", directoryHint: .notDirectory)
    }

    public enum State: Sendable, Equatable {
        /// The Chrome has no user data folder: it is not installed, or never ran.
        case browserNotFound
        case notRegistered
        /// A manifest of Braus's names `hostPath`.
        case registered
        /// A manifest of Braus's names another host.
        case registeredElsewhere(path: String)
        /// Something Braus did not write is there, and stays.
        case foreign(String)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case browserNotFound(String)
        case foreign(String)
        case hostMissing(String)
        case notWritten(String)

        public var description: String {
            switch self {
                case .browserNotFound(let folder):
                    "Chrome's folder \(folder) does not exist: open that Chrome once, then try again"
                case .foreign(let reason):
                    "Braus left the registration as it is: \(reason)"
                case .hostMissing(let path):
                    "this copy of Braus has no Chrome host at \(path)"
                case .notWritten(let reason):
                    "Braus could not write the registration: \(reason)"
            }
        }
    }

    /// The registration as it is now. Reads only.
    public func state() -> State {
        guard Self.kind(of: userDataDirectory, following: true) == .directory else { return .browserNotFound }
        switch Self.kind(of: manifestURL.deletingLastPathComponent()) {
            case .missing  : return .notRegistered
            case .directory: break
            case .link     : return .foreign("its NativeMessagingHosts folder is a link")
            case .other    : return .foreign("its NativeMessagingHosts is not a folder")
        }
        switch Self.kind(of: manifestURL) {
            case .missing: return .notRegistered
            case .other  : break
            case .link   : return .foreign("\(manifestURL.lastPathComponent) is a link")
            case .directory: return .foreign("\(manifestURL.lastPathComponent) is a folder")
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(manifest.keys) == ["name", "description", "path", "type", "allowed_origins"],
              manifest["name"] as? String == Self.hostName,
              manifest["description"] as? String == Self.description,
              manifest["type"] as? String == "stdio",
              manifest["allowed_origins"] as? [String] == [Self.extensionOrigin],
              let path = manifest["path"] as? String, path.hasPrefix("/"),
              Self.hostFileNames.contains(URL(filePath: path).lastPathComponent)
        else { return .foreign("\(manifestURL.lastPathComponent) was not written by Braus") }
        return path == hostPath ? .registered : .registeredElsewhere(path: path)
    }

    /// Registers the host: writes the manifest where there is none, or updates Braus's own that names another
    /// host. Does nothing when it is registered already. Throws, writing nothing, in every other case.
    @discardableResult
    public func register() throws -> State {
        let replacing: Bool
        switch state() {
            case .registered         : return .registered
            case .browserNotFound    : throw Failure.browserNotFound(userDataDirectory.path(percentEncoded: false))
            case .foreign(let reason): throw Failure.foreign(reason)
            case .notRegistered      : replacing = false
            case .registeredElsewhere: replacing = true
        }
        guard FileManager.default.isExecutableFile(atPath: hostPath) else { throw Failure.hostMissing(hostPath) }
        let manifest: [String: Any] = [
            "name": Self.hostName, "description": Self.description, "path": hostPath, "type": "stdio",
            "allowed_origins": [Self.extensionOrigin],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let folder = manifestURL.deletingLastPathComponent()
            if Self.kind(of: folder) == .missing {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            // A new manifest never replaces a file made meanwhile; Braus's own is replaced whole.
            try data.write(to: manifestURL, options: replacing ? .atomic : .withoutOverwriting)
        } catch {
            throw Failure.notWritten(error.localizedDescription)
        }
        return state()
    }

    /// Removes Braus's own manifest. Does nothing when there is none; throws, removing nothing, for a file Braus
    /// did not write.
    @discardableResult
    public func unregister() throws -> State {
        switch state() {
            case .registered, .registeredElsewhere:
                do { try FileManager.default.removeItem(at: manifestURL) } catch {
                    throw Failure.notWritten(error.localizedDescription)
                }
                return state()
            case .foreign(let reason):
                throw Failure.foreign(reason)
            case let unchanged:
                return unchanged
        }
    }

    enum Kind { case missing, directory, link, other }

    /// What is at `url`: a link is reported as one unless `following`. A trailing slash would read through a link,
    /// so the item itself is read without one.
    static func kind(of url: URL, following: Bool = false) -> Kind {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if following {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
            return isDirectory.boolValue ? .directory : .other
        }
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        else { return .missing }
        switch type {
            case .typeSymbolicLink: return .link
            case .typeDirectory   : return .directory
            default               : return .other
        }
    }
}

/// HostLauncher is what a manifest names when the hub's socket is not where the host looks by default
/// (`~/Library/Application Support/Braus/ChromeProfiles/hub.sock`), as with `BRAUS_APP_SUPPORT_DIR`: a small
/// script beside the socket that runs the host with `--socket`, since Chrome passes the host no argument of
/// Braus's. Written only when a registration is asked for.
public enum HostLauncher {

    public static let fileName = "braus-chrome-host-launcher"

    /// The socket the host uses when given none.
    public static func defaultSocket(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appending(path: "Library/Application Support/Braus/ChromeProfiles/hub.sock").path(percentEncoded: false)
    }

    /// The host a manifest names for the hub at `socket`: `host` itself for the default socket, else the launcher.
    public static func path(host: String, socket: String,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard socket != defaultSocket(home: home) else { return host }
        return URL(filePath: socket).deletingLastPathComponent().appending(path: fileName).path(percentEncoded: false)
    }

    /// Writes the launcher `path` names, when it names one: a script that runs `host` with `--socket socket`,
    /// in the socket's private folder. A link there is refused.
    public static func prepare(host: String, socket: String,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let launcher = path(host: host, socket: socket, home: home)
        guard launcher != host else { return }
        let url = URL(filePath: launcher)
        guard NativeHostRegistration.kind(of: url) != .link else {
            throw NativeHostRegistration.Failure.foreign("\(fileName) is a link")
        }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nexec \(quoted(host)) --socket \(quoted(socket)) \"$@\"\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher)
        } catch {
            throw NativeHostRegistration.Failure.notWritten(error.localizedDescription)
        }
    }
}
