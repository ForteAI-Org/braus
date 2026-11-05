import Foundation
import AutomationRuntime
import Memory

extension ModelText {
    nonisolated static let openingFailureTexts: [Entry] = [
        Entry(key: .init(rawValue: "opening.applicationNotFound"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 90, text: "No installed application matches {app}. No application launch was requested.", legacy: false),
        Entry(key: .init(rawValue: "opening.applicationAmbiguous"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 120,
            text: "{app} matches {count} installed applications. Use a precise bundle identifier. No application launch was requested.", legacy: false),
        Entry(key: .init(rawValue: "opening.exactWindow"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 100, text: "No unique exact window title {title} in {app} ({count} matches).", legacy: false),
        Entry(key: .init(rawValue: "opening.availableTitles"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 60, text: "Available window titles: {titles}.", legacy: false),
        Entry(key: .init(rawValue: "opening.noTitles"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 20, text: "none", legacy: false),
        Entry(key: .init(rawValue: "opening.openingAttempted"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 120,
            text: "Opening may already have launched or reopened the app. The requested window was not adopted.", legacy: false),
        Entry(key: .init(rawValue: "opening.heldSelectionRefused"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 170,
            text: "No explicit window switch, app opening or quit was requested. The preceding observation may already have changed the selected window.", legacy: false),
        Entry(key: .init(rawValue: "opening.notQuit"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 90, text: "{app} was already running; no quit was requested.", legacy: false),
        Entry(key: .init(rawValue: "opening.empty"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 50, text: "No application session is active.", legacy: false),
        Entry(key: .init(rawValue: "opening.unverified"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 90, text: "The requested application could not be verified after switching applications.", legacy: false),
        Entry(key: .init(rawValue: "opening.lost"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 110,
            text: "The app switch failed; no active session remains. The previous app was not reopened automatically.", legacy: false),
        Entry(key: .init(rawValue: "opening.retained"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 90,
            text: "The previous application session is still active.", legacy: false),
        Entry(key: .init(rawValue: "opening.launched"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 100,
            text: "{app} was launched in the background and showed no window within {seconds} s.", legacy: false),
        Entry(key: .init(rawValue: "opening.running"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 90, text: "{app} is running and showed no window within {seconds} s.", legacy: false),
        Entry(key: .init(rawValue: "opening.quitRequested"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 100, text: "{app} was asked to quit; its exit was not verified.", legacy: false),
        Entry(key: .init(rawValue: "opening.quitUnconfirmed"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 110,
            text: "A quit request for {app} was not confirmed; check whether it is still running.", legacy: false),
        Entry(key: .init(rawValue: "opening.leftRunning"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 90, text: "{app} was left running, since it was already open.", legacy: false),
        Entry(key: .init(rawValue: "opening.cleanup"), owner: "AutomationMCP", delivery: .refusal(tool: "open_session"),
            budgetCharacters: 60, text: "Cleanup still needs attention: {detail}", legacy: false)
    ]

    /// Renders shared opening facts for both tools and direct CLI diagnostics.
    public nonisolated static func openingFailure(_ failure: ApplicationOpeningFailure,
        minimization: ValueMinimization = .init()) -> String {
        func admitted(_ text: String) -> String { minimization.minimize(text: text).0 }
        func detail(_ error: any Error) -> String {
            if let opening = error as? ApplicationOpeningFailure {
                return openingFailure(opening, minimization: minimization)
            }
            if let refusal = error as? AutomationFailure { return admitted(refusal.description) }
            return admitted(error.localizedDescription)
        }
        var lines: [String] = []
        if let reason = failure.reason {
            switch reason {
            case .applicationNotFound(let application):
                lines.append(render(.init(rawValue: "opening.applicationNotFound"), ["app": .minimized(admitted(application))]))
            case .applicationAmbiguous(let application, let matches):
                lines.append(render(.init(rawValue: "opening.applicationAmbiguous"),
                    ["app": .minimized(admitted(application)), "count": .count(matches)]))
            case .windowTitleMismatch(let selection):
                let slots: [String: ModelTextSlot] = ["app": .minimized(admitted(selection.application)),
                    "title": .minimized(admitted(selection.requested)), "count": .count(selection.matches)]
                lines.append(render(.init(rawValue: "opening.exactWindow"), slots))
                let titles = selection.available.isEmpty ? text(.init(rawValue: "opening.noTitles"))
                    : selection.available.map(admitted).joined(separator: ", ")
                lines.append(render(.init(rawValue: "opening.availableTitles"), ["titles": .minimized(titles)]))
                if selection.openingAttempted {
                    lines.append(text(.init(rawValue: "opening.openingAttempted")))
                    let key = selection.wasLaunched
                        ? (selection.quitRequestAccepted ? "opening.quitRequested" : "opening.quitUnconfirmed") : "opening.notQuit"
                    lines.append(render(.init(rawValue: key), slots))
                } else { lines.append(text(.init(rawValue: "opening.heldSelectionRefused"))) }
            }
            switch failure.state {
            case .previousRetained: lines.append(text(.init(rawValue: "opening.retained")))
            case .noActiveSession: lines.append(text(.init(rawValue: "opening.empty")))
            case .unverifiedTarget: lines.append(text(.init(rawValue: "opening.unverified")))
            }
        } else {
            switch failure.state {
            case .unverifiedTarget: lines.append(text(.init(rawValue: "opening.unverified")))
            case .noActiveSession:
                lines.append(text(.init(rawValue: "opening.lost")))
                if let primary = failure.underlying { lines.append(detail(primary)) }
            case .previousRetained:
                if let launch = failure.launch {
                    let slots: [String: ModelTextSlot] = ["app": .minimized(admitted(launch.application)),
                        "seconds": .count(Int(clamping: launch.seconds))]
                    lines.append(render(.init(rawValue: launch.wasLaunched ? "opening.launched" : "opening.running"), slots))
                    let key = launch.wasLaunched
                        ? (launch.quitRequestAccepted ? "opening.quitRequested" : "opening.quitUnconfirmed") : "opening.leftRunning"
                    lines.append(render(.init(rawValue: key), slots))
                } else if let primary = failure.underlying { lines.append(detail(primary)) }
                lines.append(text(.init(rawValue: "opening.retained")))
            }
        }
        if let warning = failure.cleanupWarning, !lines.contains(where: { $0.contains(admitted(warning)) }) {
            lines.append(render(.init(rawValue: "opening.cleanup"), ["detail": .minimized(admitted(warning))]))
        }
        return lines.joined(separator: " ")
    }
}
