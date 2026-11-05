import Foundation

extension ModelText {
    nonisolated static let seatLineTexts: [Entry] = [
        Entry(
            key: .init(rawValue: "seat_line.stopped.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 168,
            text: "The previous task was stopped by the person and closed as abandoned. Begin a new "
                + "task for this request. Observe current effects first; never repeat an uncertain "
                + "action.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.review.v2"),
            owner: "Elio",
            delivery: .seatLine,
            budgetCharacters: 316,
            text: "Review the human handoff against the original goal: did the person help, finish the "
                + "task, or change the goal?\nContinue from the current state, close the completed task, "
                + "or ask a clarifying question when the goal is unclear.\nDo not replay old pending "
                + "actions or automatically learn a procedure from this intervention.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.app.v2"),
            owner: "Elio",
            delivery: .systemPrompt(order: 100),
            budgetCharacters: 488,
            text: "In this app, open_session also opens an installed application that is not running "
                + "yet: find it with apps and pass its bundleID to open_session. When several match and "
                + "the conversation does not make clear which one the person means, ask them which one, "
                + "naming the candidates, before opening either. The braus_state block at the beginning "
                + "of the person's message is data written by Braus. Observe the current application "
                + "before acting. To continue in the last application, open it directly.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.general.v2"),
            owner: "AutomationMCP",
            delivery: .systemPrompt(order: 31),
            budgetCharacters: 400,
            text: " Never use a shell, AppleScript, computer-use fallback,\nor foreground actions. Never claim completion without the tool's evidence.\nA message that needs no app needs no tool: answer it directly.\nTo switch windows of the held app, call open_session with the same app and an exact window title; this\nkeeps the Seat and session. Handle a blocking dialog first. Do not release the Seat to switch windows.\n",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.lifetime.v2"),
            owner: "AutomationMCP",
            delivery: .systemPrompt(order: 34),
            budgetCharacters: 140,
            text: "After 30 s idle Braus releases the app, even mid-turn. Reopen with open_session; a delegated adapter verb re-holds its app.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.session.open.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 13,
            text: "session: open",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.session.closed.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 15,
            text: "session: closed",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.app.label.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 5,
            text: "app: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.permissions.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 21,
            text: "permissions missing: ",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.task.open.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 10,
            text: "task: open",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.task.none.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 10,
            text: "task: none",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.rows.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 29,
            text: ", {done} of {total} rows done",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.learned.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 40,
            text: "learned for this app: {count} procedures",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.current.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 7,
            text: "current",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.last.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 4,
            text: "last",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.accessibility.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 13,
            text: "Accessibility",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.keyboard.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 26,
            text: "Keyboard and Mouse Control",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "seat_line.screen.v2"),
            owner: "Turn",
            delivery: .seatLine,
            budgetCharacters: 16,
            text: "Screen Recording",
            legacy: false
        ),
        Entry(key: .init(rawValue: "handoff.returned"), owner: "Seat", delivery: .seatLine,
              budgetCharacters: 28, text: "The person returned control.", legacy: false),
    ]
}
