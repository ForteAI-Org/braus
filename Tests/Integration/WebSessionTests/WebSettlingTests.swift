import Foundation
import Testing
import WebDriver
@testable import WebDriving

/// W12: the web settler does not take a page that keeps changing for a quiet one. A text replaced by one of the same
/// length is counted by the observer `prepare` installs, so the wait lasts until the changes stop. Over `SyntheticPage`,
/// whose text takes one step at each settling read, with the production settler and its scripts; the DOM's own observer
/// is the Chrome tier's.
@Suite("Settling a web page that keeps changing (W12)")
struct WebSettlingTests {

    @Test("a text replaced by others of the same length, read after read: the settler returns only after the last one, before the cap")
    func sameLength() async throws {
        let stack = await SyntheticForm.stack()
        stack.page.step(texts: (1...8).map { "Passo \($0)" })
        let settler = WebSettler(tabs: stack.tabs)
        await settler.prepare(in: stack.processID)
        let started = ContinuousClock.now
        await settler.settle(in: stack.processID, cap: .seconds(3))
        #expect(stack.page.pendingSteps == 0, "the settler returned while the page was still changing")
        #expect(ContinuousClock.now - started < .seconds(3), "it returned once the page held still")
    }

    @Test("a page that holds still: the settler returns well before the cap (positive control)")
    func still() async throws {
        let stack = await SyntheticForm.stack()
        let settler = WebSettler(tabs: stack.tabs)
        await settler.prepare(in: stack.processID)
        let started = ContinuousClock.now
        await settler.settle(in: stack.processID, cap: .seconds(3))
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
