//
//  WorkspaceStoreThreadTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/10/2026.
//

import Foundation
import Testing
@testable import Braus

/// Which thread the store's work runs on.
///
/// Measured on macOS 27 (SDK 27.0): the `@ModelActor` executor ran each call
/// on the thread that made the call, wherever the store was opened, so a call
/// from the main actor ran on the main thread. The store runs every call on a
/// queue of its own instead, and the app's opener moves the open off the main
/// thread as well.
@Suite("The thread the store's work runs on")
@MainActor
struct WorkspaceStoreThreadTests {

    @Test("The app's opener gives a working store, whose calls made off the main thread run off it")
    func offMainOpenerGivesAWorkingStore() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try await WorkspaceStore.openingOffMain(in: directory)
        try await store.createWorker(name: "Nova", appearance: TemporaryStore.appearance())

        #expect(try await store.workers().map(\.name) == ["Nova"])
        #expect(await Task.detached { await store.runsOnMainThread() }.value == false)
    }

    @Test("A call made on the main thread runs off it, whichever opener made the store")
    func mainThreadCallsRunOffMain() async throws {
        let synchronous = TemporaryStore.directory()
        let offMain     = TemporaryStore.directory()
        defer {
            TemporaryStore.discard(synchronous)
            TemporaryStore.discard(offMain)
        }

        let opened        = try WorkspaceStore.opening(in: synchronous)
        let openedOffMain = try await WorkspaceStore.openingOffMain(in: offMain)

        // A new main actor task starts on the main thread, so its first call is made from there.
        #expect(await Task { @MainActor in await opened.runsOnMainThread() }.value == false)
        #expect(await Task { @MainActor in await openedOffMain.runsOnMainThread() }.value == false)
    }

    @Test("Two windows opening at once share one store")
    func concurrentOpensShareOneStore() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let launch = WorkspaceLaunch()
        #expect(launch.store == nil)

        // Both start before either finishes: the second finds the first under way.
        let first  = Task { await launch.open(in: directory) }
        let second = Task {
            await launch.open(in: directory)
            return launch.store
        }
        await first.value
        let seen = await second.value

        let store = try #require(launch.store)
        #expect(seen === store)
        #expect(launch.failure == nil)

        await launch.open(in: directory)
        #expect(launch.store === store)
    }
}
