//
//  IsolatedLaunchEnvironment.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import Darwin
import Foundation

/// IsolatedLaunchEnvironment redirects CF preferences, framework caches and temporary files before
/// app state is constructed. The runner also exports these paths before exec, for framework startup.
@MainActor
enum IsolatedLaunchEnvironment {

    static func prepare() throws {
        guard case .isolated(let support) = LaunchIsolation.current else { return }
        for (variable, leaf) in [("CFFIXED_USER_HOME", "home"), ("TMPDIR", "tmp")] {
            let folder = support.appending(path: leaf)
            try FileManager.default.createDirectory(
                at                         : folder,
                withIntermediateDirectories: true
            )
            guard setenv(
                variable,
                folder.path + "/",
                1
            ) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        // Ignoring state sends new AppKit state to the shared system temp folder. Keep it in this home instead.
        let log = support.appending(path: "app.log")
        let descriptor = open(
            log.path,
            O_WRONLY | O_CREAT | O_APPEND,
            0o600
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard dup2(descriptor, STDOUT_FILENO) >= 0,
              dup2(descriptor, STDERR_FILENO) >= 0 else { throw CocoaError(.fileWriteUnknown) }
        try redirectMetalCache(under: support)
        try AppDefaults.isolate(in: support)
        UserDefaults.standard.setVolatileDomain(
            ["ApplePersistenceIgnoreState": false],
            forName: UserDefaults.argumentDomain
        )
    }

    /// Sets Metal's cache-path SPI before a device exists. Missing SPI refuses the isolated launch,
    /// because using Metal's default would write to the person's Darwin cache directory.
    private static func redirectMetalCache(under support: URL) throws {
        let folder = support.appending(path: "metal")
        try FileManager.default.createDirectory(
            at                         : folder,
            withIntermediateDirectories: true
        )
        guard let library = dlopen(
            "/System/Library/Frameworks/Metal.framework/Metal",
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            throw AutomationFailure("Isolated launch could not load Metal to redirect its cache.")
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(
            library,
            "MTLSetShaderCachePath"
        ) else {
            throw AutomationFailure("This macOS build cannot redirect Metal's cache for an isolated launch.")
        }
        typealias SetCachePath = @convention(c) (NSString) -> Void
        let setPath = unsafeBitCast(
            symbol,
            to: SetCachePath.self
        )
        setPath(folder.path as NSString)
    }

}
