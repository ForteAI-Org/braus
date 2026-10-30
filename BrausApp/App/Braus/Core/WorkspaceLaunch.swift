//
//  WorkspaceLaunch.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Observation

/// WorkspaceLaunch opens the workspace store when the app starts.
///
/// The app is where the path is decided, because the library takes its
/// directory as a parameter and resolves none of its own. This is the same
/// `~/Library/Application Support/Braus` the seat broker keeps `Runs` and
/// `Perception` under, so the workspace database sits beside them.
///
/// Opening is attempted once. A failure is kept rather than thrown away: the
/// team sidebar in T3 has to say that the store did not open instead of
/// showing an empty team as if there were none.
@Observable
@MainActor
final class WorkspaceLaunch {

    private(set) var store: WorkspaceStore?

    /// Why the store is not open, nil while it is or before the attempt.
    private(set) var failure: String?

    /// Where the store lives beside the kit's other directories.
    ///
    /// `BRAUS_APP_SUPPORT_DIR` replaces it for one launch, so a second copy of
    /// the app can run without opening the store another process holds. A
    /// check run (`BrausApp.isCheckRun`) that names none gets a temporary one, so
    /// those runs never open the person's workspace. Worker workspaces and the
    /// Brain follow it.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BRAUS_APP_SUPPORT_DIR"], !override.isEmpty {
            return URL(
                filePath     : override,
                directoryHint: .isDirectory
            )
        }

        if BrausApp.isCheckRun {
            return URL.temporaryDirectory.appending(
                path         : "BrausCheckSupport",
                directoryHint: .isDirectory
            )
        }

        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in : .userDomainMask
        )[0]
        .appending(
            path         : "Braus",
            directoryHint: .isDirectory
        )
    }

    /// The opening under way, which a second window awaits instead of
    /// opening the directory again. Nil once it has finished.
    private var opening: Task<Void, Never>?

    /// Opens the store, or records why it could not be opened. Calling it
    /// again once the store is open does nothing.
    ///
    /// The file is opened, copied and migrated off the main thread
    /// (`WorkspaceStore.openingOffMain`). Two windows calling at once get the
    /// same store: one store per directory.
    func open(in directory: URL = WorkspaceLaunch.directory) async {
        guard store == nil else { return }

        if opening == nil {
            opening = Task {
                do {
                    store   = try await WorkspaceStore.openingOffMain(in: directory)
                    failure = nil
                } catch {
                    store   = nil
                    failure = String(describing: error)
                }
                opening = nil
            }
        }
        await opening?.value
    }
}
