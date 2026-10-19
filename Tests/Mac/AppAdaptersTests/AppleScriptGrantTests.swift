import Carbon
import Testing
@testable import AppAdapters

/// A01: what the Mac's answer to "may Braus send this app events", asked without prompting, states. Only `noErr` is a
/// grant; consent needed or refused is refused; an app not running, or any other answer, is not known.
@Suite("AppleScript grant")
struct AppleScriptGrantTests {

    @Test("only noErr is allowed; consent needed or refused is refused; an app not running or another answer is not known")
    func grants() {
        #expect(AppleScriptRunner.grant(status: OSStatus(noErr)) == .allowed)
        #expect(AppleScriptRunner.grant(status: OSStatus(errAEEventWouldRequireUserConsent)) == .refused)
        #expect(AppleScriptRunner.grant(status: OSStatus(errAEEventNotPermitted)) == .refused)
        #expect(AppleScriptRunner.grant(status: OSStatus(procNotFound)) == .notAnswerable)
        #expect(AppleScriptRunner.grant(status: -1) == .notAnswerable)
    }

    @Test("a script goes only on an allowed grant; a refused one and an unanswered one stop it before any event, each saying which")
    func dispatch() throws {
        #expect((try? AppleScriptRunner.dispatch(for: .allowed, app: "Mail").get()) != nil)
        for grant in [AppleScriptRunner.Grant.refused, .notAnswerable] {
            guard case .failure(let stopped) = AppleScriptRunner.dispatch(for: grant, app: "Mail") else {
                Issue.record("\(grant) let the script go")
                continue
            }
            #expect(stopped.beforeAnyEvent, "\(grant): stopped before any event")
            #expect(stopped.isGrantUnknown == (grant == .notAnswerable), "\(grant): unknown is told apart from refused")
        }
    }
}
