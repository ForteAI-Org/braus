import AutomationRuntime
import Foundation
import MacSession
import PrivateSymbols
import Router
import SeatBroker
import WebDriver
import WebSession

extension ChatSession {
    static func session(
        desktop  : BrokeredAutomationSession,
        options  : ChatOptions,
        knowledge: URL,
        owner    : UUID,
        web      : WebAutomationSession?
    ) throws -> any AutomationSessionOperating {
        guard !options.channels.isDisjoint(with: [.native, .web]) else { return desktop }
        return RoutingAutomationSession(
            native : options.channels.contains(.native)
                ? MacAutomationSession(knowledgeDirectory: knowledge, allowsDestructive: options.allowDestructive,
                                       leaseOwner: owner)
                : nil,
            desktop: desktop,
            web    : web
        )
    }
    static func chatChrome(options: ChatOptions, history: URL, knowledge: URL) -> WebAutomationSession {
        WebAutomationSession(
            knowledgeDirectory   : knowledge,
            launchOptions        : ChromeLaunchOptions(
                executableURL      : options.chromeExecutable.map { URL(fileURLWithPath: $0) }
                    ?? ChromeLaunchOptions.applicationsChrome,
                userDataDirectory  : history.appendingPathComponent("Chrome", isDirectory: true),
                isHeadless         : true
            ),
            allowsDestructive    : options.allowDestructive,
            connectPersonalChrome: {
                throw AutomationFailure("braus chat opens pages only in its own Chrome, never the person's: nothing "
                                        + "was opened.")
            }
        )
    }
}
