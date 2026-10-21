import Foundation

/// MacRefusedApps are the apps Braus never drives, whatever the task: password managers. They are
/// refused before launch, by bundle id and, for builds with another id, by name.
public enum MacRefusedApps {

    public static let bundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.apple.Passwords",
    ]

    /// Lowercased names; an app whose name contains one of them is refused.
    public static let names: [String] = [
        "1password", "bitwarden", "dashlane", "lastpass", "nordpass", "proton pass", "passwords", "password",
    ]

    public static func refuses(_ app: MacApp) -> Bool {
        if bundleIDs.contains(app.bundleID) { return true }
        return app.names.contains { name in
            let lowered = name.lowercased()
            return names.contains { lowered.contains($0) }
        }
    }
}
