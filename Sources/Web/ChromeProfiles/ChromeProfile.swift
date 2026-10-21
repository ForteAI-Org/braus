//
//  ChromeProfile.swift
//  Braus
//

import Foundation

/// ChromeProfile is one Chrome profile the person paired with Braus through the Braus extension: the
/// extension instance's own random ID, kept in that profile's `chrome.storage.local`, and the name the
/// person confirmed for it on the instance's pairing page.
///
/// The ID names the extension instance, not Chrome's profile directory, which no extension API gives; the
/// name is the person's, never a site's account. A profile appears here only once paired, never by
/// discovering what Chrome has installed.
public struct ChromeProfile: Sendable, Hashable, Codable {

    public let instanceID: String
    public let label     : String
    /// Whether its extension instance is connected to Braus now.
    public var isConnected: Bool

    public init(instanceID: String, label: String, isConnected: Bool) {
        self.instanceID  = instanceID
        self.label       = label
        self.isConnected = isConnected
    }
}

/// ChromeProfileError says why a paired profile cannot be used now. In every case nothing was sent to any
/// extension instance and nothing was opened.
public enum ChromeProfileError: Error, Sendable, Equatable, CustomStringConvertible {

    /// No paired profile has this instance ID.
    case unknown(instanceID: String)
    /// The profile is paired, but its extension instance is not connected: Chrome closed, or the
    /// extension stopped.
    case disconnected(label: String)
    /// The hub is not listening.
    case notRunning

    public var description: String {
        switch self {
            case .unknown:
                "no paired Chrome profile has this ID: it was never paired, or the person revoked the pairing"
            case .disconnected(let label):
                "the Chrome profile '\(label)' is paired but not connected: its Chrome is closed or its Braus "
                    + "extension stopped"
            case .notRunning:
                "Braus is not listening for its Chrome extension"
        }
    }
}

/// PairedProfiles keeps the paired profiles' IDs and names in one JSON file, so a choice survives a relaunch
/// and a profile whose Chrome is closed is still shown, as disconnected. It holds no secret: the person's
/// names and the instances' random IDs.
struct PairedProfiles {

    let file: URL

    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }
        return Dictionary(entries.map { ($0.instanceID, $0.label) }, uniquingKeysWith: { _, last in last })
    }

    /// Writes the pairings; a failed write only loses them at the next launch.
    func save(_ labels: [String: String]) {
        let entries = labels.map { Entry(instanceID: $0.key, label: $0.value) }.sorted { $0.instanceID < $1.instanceID }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private struct Entry: Codable {
        let instanceID: String
        let label     : String
    }
}
