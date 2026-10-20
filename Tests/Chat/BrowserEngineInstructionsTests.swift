//
//  BrowserEngineInstructionsTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import LocalMCP
import Testing

/// The web composed, the instructions say what the browser engine is to the person: Braus's own Chrome and profile,
/// with no window unless they show it, their own sign-in in that window, and no move to their browser without asking;
/// their own Chrome only when they turn on Use My Chrome or choose a paired profile, said under browser, asking before
/// acting as them.
/// Without the web, nothing of it.
@Suite("What the instructions say of Braus's own browser")
struct BrowserEngineInstructionsTests {

    @Test("the browser engine is named as Braus's own Chrome and profile exactly when the web is composed")
    func browserEngineProfileFollowsTheWeb() {
        let sentence = AutomationTools.browserEngineProfile
        for part in ["Braus's own Chrome with its own profile", "never the person's Chrome, profile or sign-ins",
                     "Show Chrome Window", "the person's own sign-in in that window",
                     "do not move to their own browser without asking them",
                     "unless the person turns on Use My Chrome for the conversation",
                     "or chooses one of their Chrome profiles paired with Braus",
                     "each answer says so under browser",
                     "ask the person before anything that posts, sends, buys, deletes or changes their accounts"] {
            #expect(sentence.contains(part), "\(part)")
        }
        for channels: AutomationChannels in [[], [.native], [.web], [.native, .web], .all] {
            #expect(AutomationTools.instructions(for: channels).contains(sentence) == channels.contains(.web),
                    "\(channels)")
        }
    }

    @Test("collect_posts is offered to every provider, and named for bulk reading, exactly when the web is composed")
    func collectPostsFollowsTheWeb() {
        for channels: AutomationChannels in [[], [.native], [.web], [.native, .web], .all] {
            let names = AutomationTools.definitions(for: channels).compactMap { $0["name"].string }
            #expect(names.contains("collect_posts") == channels.contains(.web), "\(channels)")
            #expect(AutomationTools.instructions(for: channels).contains(AutomationTools.bulkReading)
                        == channels.contains(.web), "\(channels)")
        }
    }
}
