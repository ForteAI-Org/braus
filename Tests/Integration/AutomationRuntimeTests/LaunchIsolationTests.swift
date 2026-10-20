import AutomationRuntime
import Foundation
import Testing

/// B2: an isolated run is decided from the environment alone, and an isolated run that is asked for but not valid is
/// refused rather than run on the person's folder.
@Suite("Launch isolation (B2)")
struct LaunchIsolationTests {

    private let personal = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Braus", isDirectory: true)

    private func isolation(_ environment: [String: String]) -> LaunchIsolation {
        LaunchIsolation(environment: environment, personal: personal)
    }

    @Test("not asked for, unset or empty, nothing changes, whatever the support folder")
    func off() {
        #expect(isolation([:]) == .off)
        #expect(isolation(["BRAUS_ISOLATED_RUN": ""]) == .off)
        #expect(isolation(["BRAUS_APP_SUPPORT_DIR": "/tmp/braus-smoke"]) == .off)
        #expect(!isolation([:]).isIsolated && isolation([:]).refusal == nil)
    }

    @Test("asked for with an absolute folder of its own: isolated in that folder, and the app may start")
    func isolated() {
        let run = isolation(["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": "/tmp/braus-smoke/support/"])
        #expect(run == .isolated(support: URL(fileURLWithPath: "/tmp/braus-smoke/support", isDirectory: true)))
        #expect(run.isIsolated && run.refusal == nil)
    }

    @Test("asked for and not valid: refused, isolated all the same, never the person's folder",
          arguments: [
            ["BRAUS_ISOLATED_RUN": "1"],
            ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": ""],
            ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": "smoke/support"],
            ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": "~/braus-smoke"],
            ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": "/"],
            ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": "/Users/someone/Library/Application Support/Braus"],
            ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": "/Users/someone/Library/Application Support/Braus/../Braus/"],
            ["BRAUS_ISOLATED_RUN": "true", "BRAUS_APP_SUPPORT_DIR": "/tmp/braus-smoke"],
            ["BRAUS_ISOLATED_RUN": "0", "BRAUS_APP_SUPPORT_DIR": "/tmp/braus-smoke"],
          ])
    func invalid(environment: [String: String]) {
        let run = isolation(environment)
        guard case .invalid = run else {
            Issue.record("\(environment) gave \(run)")
            return
        }
        #expect(run.isIsolated, "the keychain and the launch checks stay away even when the run is refused")
        #expect(run.refusal?.isEmpty == false)
    }

    @Test("the smoke build starts only isolated: without isolation, as from Finder or the system, it is refused; Braus runs as before")
    func smokeBundle() {
        let smoke = LaunchIsolation.smokeBundleID
        let valid = ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": "/tmp/braus-smoke/support"]
        #expect(isolation([:]).refusal(bundleID: smoke)?.isEmpty == false, "no environment at all")
        #expect(isolation(["BRAUS_APP_SUPPORT_DIR": "/tmp/braus-smoke/support"]).refusal(bundleID: smoke) != nil)
        #expect(isolation(["BRAUS_ISOLATED_RUN": "1"]).refusal(bundleID: smoke) != nil, "isolation not valid")
        #expect(isolation(valid).refusal(bundleID: smoke) == nil)
        for bundle in ["dev.forte.Braus", nil] as [String?] {
            #expect(isolation([:]).refusal(bundleID: bundle) == nil, "\(String(describing: bundle)) unchanged")
            #expect(isolation(valid).refusal(bundleID: bundle) == nil)
            #expect(isolation(["BRAUS_ISOLATED_RUN": "1"]).refusal(bundleID: bundle) != nil)
        }
    }

    @Test("the person's support folder reached through a symbolic link is refused too")
    func throughALink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("braus-isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("Braus", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)
        let run = LaunchIsolation(environment: ["BRAUS_ISOLATED_RUN": "1", "BRAUS_APP_SUPPORT_DIR": link.path],
                                  personal: own)
        guard case .invalid = run else {
            Issue.record("a link to the person's folder gave \(run)")
            return
        }
    }
}
