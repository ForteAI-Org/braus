//
//  AppDefaults.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import Foundation

/// AppDefaults supplies the app's preference store. IsolatedLaunchEnvironment installs an absolute
/// path suite before any app state or AppStorage wrapper is constructed; regular launches keep the
/// standard store. CFFIXED_USER_HOME alone does not redirect cfprefsd's writes on every macOS build.
@MainActor
enum AppDefaults {

    private static var isolated: UserDefaults?
    private static let snapshots = WindowSnapshots.isRequested ? WindowSnapshots.appStorage : nil

    static var current: UserDefaults { isolated ?? snapshots ?? .standard }

    static func isolate(in support: URL) throws {
        isolated = try isolatedStore(in: support)
    }

    /// Uses CFPreferences' absolute-path domain so the plist is inside support, including its writes.
    static func isolatedStore(in support: URL) throws -> UserDefaults {
        guard let store = UserDefaults(suiteName: support.appending(path: "preferences").path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return store
    }
}
