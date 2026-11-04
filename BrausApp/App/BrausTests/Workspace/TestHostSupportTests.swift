//
//  TestHostSupportTests.swift
//  Braus
//

import AutomationRuntime
import Foundation
import SeatBroker
import Testing
@testable import Braus

/// The isolation proof of a reviewed app test run: asked for with `BRAUS_REQUIRE_TEST_HOST_ISOLATION=1`, the test host
/// must be a valid isolated run whose support folder is exactly the one the run named, never the person's, and it
/// leaves a marker there that the run then requires. Each condition is required before anything is written. Without
/// that variable the proof is not asked for, and the run that needs it fails on the missing marker.
@MainActor
struct TestHostSupportTests {

    nonisolated static let requirement = "BRAUS_REQUIRE_TEST_HOST_ISOLATION"

    /// The file the run checks for in its support folder.
    nonisolated static let marker = "test-host-support.txt"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[requirement] == "1"))
    func theSupportFolderIsTheRunsOwn() throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(BrausApp.isTestHost, "not the test host of BrausTests")
        let named = try #require(environment[KnowledgeLocation.supportOverride], "no support folder override")
        try #require(!named.isEmpty, "an empty support folder override")
        let isolated: URL? = if case .isolated(let support) = LaunchIsolation.current { support } else { nil }
        let isolation = try #require(isolated, "not a valid isolated run: \(LaunchIsolation.current)")

        func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let override = URL(fileURLWithPath: named, isDirectory: true)
        let support  = WorkspaceLaunch.directory
        let personal = KnowledgeLocation.support(environment: [:])
        try #require(resolved(support) == resolved(override), "the host's support folder is not the override")
        try #require(resolved(isolation) == resolved(override), "the isolation keeps another folder")
        try #require(resolved(support) != resolved(personal), "the host's support folder is the person's")

        // Inspect the broker the app really constructs, not an unused configuration value. RunRecorder
        // creates Runs during broker initialization, before a seat or an application is opened.
        let model = AppModel()
        let configuration = model.broker.configuration
        let runs = support.appending(path: "Runs", directoryHint: .isDirectory)
        let perception = support.appending(path: "Perception", directoryHint: .isDirectory)
        try #require(resolved(configuration.recordingDirectory) == resolved(runs),
                     "the broker's recorder is outside the isolated support folder")
        try #require(resolved(configuration.perceptionStoreDirectory) == resolved(perception),
                     "the broker's perception path is outside the isolated support folder")
        var isDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: runs.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                     "the broker did not create its recorder directory under the isolated support folder")

        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "pid \(getpid())\nsupport \(resolved(support))\n".write(
            to: support.appending(path: Self.marker), atomically: true, encoding: .utf8
        )
    }
}
