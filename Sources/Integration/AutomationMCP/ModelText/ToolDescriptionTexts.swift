import Foundation

extension ModelText {
    nonisolated static let toolDescriptionTexts: [Entry] = [
        Entry(
            key: .init(rawValue: "tool_catalogue.webOpening.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 86,
            text: "With web:<host> (web:example.com) or an http(s) address as app, it opens that page in ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.webOpening.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 115,
            text: "the Chrome selected for this conversation, and the scene is the page; another address later loads in the same tab. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.webOpening.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 30,
            text: "A file:// address is refused. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.better.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 10,
            text: "a web page",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.better.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 19,
            text: "an app_call adapter",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.section.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 114,
            text: "Exact name of a ## section heading from the current scene, or of a {container} shown in it. Omit when unnecessary.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "status"),
            budgetCharacters: 58,
            text: "Read Braus's permission and session status. Never prompts.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "windows"),
            budgetCharacters: 92,
            text: "Discover exact running application names, bundle IDs and window titles. Optional app filter.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "apps"),
            budgetCharacters: 92,
            text: "List the applications open_session can open, best match first, with name, bundleID, version ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "apps"),
            budgetCharacters: 90,
            text: "and running, and defaultBrowser on the browser that opens web links by default. Use it to ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "apps"),
            budgetCharacters: 67,
            text: "find an application that is not running, then pass its bundleID to ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.6"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "apps"),
            budgetCharacters: 70,
            text: "open_session. Optional query: part of a name, a bundle ID or initials.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.7"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 65,
            text: "Adopt an app into one persistent background Seat and observe it. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.8"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 38,
            text: "Open an app or a page and observe it. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.9"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 1,
            text: " ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.10"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 92,
            text: "Use an exact window title when needed; an empty title selects one uniquely untitled window. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.11"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 162,
            text: "Omitting window selects the main window. For the held app, an exact window title switches within the same Seat. Close the session before opening a different app. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.12"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 85,
            text: "Set named true only when the person named this app or service: otherwise an app with ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.13"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 16,
            text: "a better route (",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.14"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 57,
            text: ") is not opened, and the answer says which route to use. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.15"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 1,
            text: " ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.16"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "open_session"),
            budgetCharacters: 53,
            text: "True only when the person named this app or service. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.17"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "observe"),
            budgetCharacters: 81,
            text: "Read a fresh scene in this session, including its current dialog. Required after ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.18"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "observe"),
            budgetCharacters: 89,
            text: "resuming chat. Not after an action whose result carries observation: that is already the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.19"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "observe"),
            budgetCharacters: 90,
            text: "scene after it. A window already read answers its changes since that revision, or that it ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.20"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "observe"),
            budgetCharacters: 88,
            text: "is unchanged; full true answers the whole scene, for when that revision is no longer in ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.21"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "observe"),
            budgetCharacters: 18,
            text: "the conversation. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.observeSection.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "observe"),
            budgetCharacters: 184,
            text: "Exact title of one ## section of this session's latest scene, such as one an answer left out: answers that section, in pages if needed, without reading the window again. Not with full.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.observePage.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "observe"),
            budgetCharacters: 54,
            text: "The page of a section too long for one answer, from 1.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.22"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "act"),
            budgetCharacters: 87,
            text: "Resolve a current label or element ID, act, and verify; observation is the scene after ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.23"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "act"),
            budgetCharacters: 87,
            text: "acting. set_toggle requires value on/off. Never automatically repeat acted_unverified. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.24"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "act"),
            budgetCharacters: 73,
            text: "Typing, keys, scrolling, drags and contextual menus have their own tools.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.25"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "select"),
            budgetCharacters: 92,
            text: "Choose a visible dropdown item and verify its new value. control is its current value/label.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.26"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "type_text"),
            budgetCharacters: 77,
            text: "Resolve a current field label or element ID, click it and type text into it. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.27"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "type_text"),
            budgetCharacters: 91,
            text: "replace (default true) selects what the field holds first; false adds the text at its end. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.28"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "type_text"),
            budgetCharacters: 86,
            text: "Verified by reading the field's value back. On acted_unverified read its observation; ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.29"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "type_text"),
            budgetCharacters: 21,
            text: "never retype blindly.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.30"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "insert_text"),
            budgetCharacters: 79,
            text: "Insert one intact text payload at the already established focus and selection. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.31"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "insert_text"),
            budgetCharacters: 97,
            text: "Does not click, move the caret or select text. Optional expected_value is the complete resulting ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.32"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "insert_text"),
            budgetCharacters: 94,
            text: "field value, verified only by native focused-field readback. Opaque fields remain unverified; ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.33"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "insert_text"),
            budgetCharacters: 61,
            text: "verify the committed effect separately. Never replay blindly.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.34"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press_key"),
            budgetCharacters: 81,
            text: "Press one key into the window, optionally with modifiers held and repeated count ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.35"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press_key"),
            budgetCharacters: 83,
            text: "times. For a shortcut or a navigation key, never for text: use type_text for that. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.36"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press_key"),
            budgetCharacters: 79,
            text: "Command-Q and Command-W are refused. Menu equivalents vary by app and surface: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.37"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press_key"),
            budgetCharacters: 90,
            text: "prefer menu or context_menu when background keys have not been qualified for that target. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.38"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press_key"),
            budgetCharacters: 83,
            text: "Verify the intended effect after a shortcut; never repeat acted_unverified blindly.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.39"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "scroll"),
            budgetCharacters: 86,
            text: "Scroll a target, or the window's centre without one, by wheel lines (default 3) up or ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.40"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "scroll"),
            budgetCharacters: 89,
            text: "down. Vertical only: the Seat has no horizontal wheel. Verified only by a visible change.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.41"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "drag"),
            budgetCharacters: 89,
            text: "Drag from one target to another target (to), or by an offset in points (dx, dy; positive ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.42"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "drag"),
            budgetCharacters: 95,
            text: "is right and down). Both ends must lie inside the window. Destructive drop targets are refused.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.43"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "context_menu"),
            budgetCharacters: 79,
            text: "Right-click a target and choose the item titled item in the contextual menu it ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.44"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "context_menu"),
            budgetCharacters: 93,
            text: "opens, by keyboard. Use the title as the app draws it, in its language. This is how Copy and ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.45"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "context_menu"),
            budgetCharacters: 49,
            text: "Paste are reached. Destructive items are refused.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.46"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "batch"),
            budgetCharacters: 102,
            text: "Run up to 20 steps of act, select, type_text, insert_text, press_key, scroll, drag or context_menu in ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.47"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "batch"),
            budgetCharacters: 58,
            text: "the current Seat. Stop on the first unsuccessful outcome. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.48"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "batch"),
            budgetCharacters: 72,
            text: "Earlier effects remain; no rollback or replay. Each step observes again.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.49"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 75,
            text: "List or press an item of the application's menu bar through accessibility. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.50"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 80,
            text: "Qualified targets may use a brief activation with verified foreground handback. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.51"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 46,
            text: "path names it from the menu bar down, such as ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.52"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 95,
            text: "\"File > Save As...\" or \"Layer > New > Layer...\". A path that ends on a menu answers its items; ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.53"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 89,
            text: "one that ends on an item presses it and answers with the scene after it. Listings do not ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.54"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 92,
            text: "activate the application: enabled flags and editing history may be stale in the background. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.55"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 89,
            text: "A complete command path is read again during qualified preparation. Disabled, hiding and ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.56"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "menu"),
            budgetCharacters: 30,
            text: "destructive items are refused.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.57"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press"),
            budgetCharacters: 83,
            text: "Press a button of the application's dialog or alert in front by its title, through ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.58"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press"),
            budgetCharacters: 96,
            text: "accessibility. For a button a click cannot reach: the click was refused, or the scene shows the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.59"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press"),
            budgetCharacters: 93,
            text: "button as text. Answers with the scene after the press. Disabled and destructive buttons are ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.60"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_capabilities"),
            budgetCharacters: 50,
            text: "List what Braus can do in an app through its API: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.61"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_capabilities"),
            budgetCharacters: 67,
            text: "the adapter's availability and its verbs, each with its arguments, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.62"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_capabilities"),
            budgetCharacters: 91,
            text: "safety class and read-back. Prefer a verb there over driving the app's interface. Optional ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.63"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_capabilities"),
            budgetCharacters: 33,
            text: "query: words of the verbs wanted.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.64"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_call"),
            budgetCharacters: 82,
            text: "Run one verb of an app's adapter (see app_capabilities) and read its effect back; ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.65"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_call"),
            budgetCharacters: 228,
            text: "a verb that scripts its app holds it on the Seat when available, switching apps if needed. A session: line names the session it opened, which observe can read. The outcome is found_acted when the read-back confirmed the effect, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.66"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_call"),
            budgetCharacters: 89,
            text: "acted_unverified when it did not (read the state again before anything else), acted_noop ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.67"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_call"),
            budgetCharacters: 89,
            text: "when nothing needed doing, honest_miss when the thing named does not exist, refused when ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.68"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_call"),
            budgetCharacters: 77,
            text: "nothing was done and the message says why. Setters answer the previous value.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.69"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "app_call"),
            budgetCharacters: 53,
            text: "The verb's arguments, as app_capabilities lists them.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.70"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "close_session"),
            budgetCharacters: 76,
            text: "Return the application's windows and release its Seat. Only when the person ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.71"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "close_session"),
            budgetCharacters: 107,
            text: "asks, or before calling open_session for a different app; never to finish a task, since Braus releases the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.72"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "close_session"),
            budgetCharacters: 15,
            text: "Seat by itself.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.73"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "collect_posts"),
            budgetCharacters: 76,
            text: "Read many posts or articles of the web page this session holds in one call, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.74"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "collect_posts"),
            budgetCharacters: 97,
            text: "scrolling it for more: each with its author, full text, link and date where the page shows them, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.75"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "collect_posts"),
            budgetCharacters: 99,
            text: "a quoted post kept apart, each counted once by the site's ID or its link. It stops at target, when ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.76"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "collect_posts"),
            budgetCharacters: 91,
            text: "scrolling brings nothing new, at the page's end, after max_scrolls (default 30) or seconds ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.77"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "collect_posts"),
            budgetCharacters: 97,
            text: "(default 60), or if the page changes, and says why; fewer than target is a partial answer, never ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.78"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "collect_posts"),
            budgetCharacters: 94,
            text: "padded. Reads X posts, Reddit posts and pages built of <article> elements; on another page it ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.step.v1.79"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "collect_posts"),
            budgetCharacters: 70,
            text: "answers unsupported. It scrolls the page: observe before acting on it.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool.human_step.v1.description"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "human_step"),
            budgetCharacters: 68,
            text: "Read human-control steps, a window's net diff, or a step's picture. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "human_step_tool.definition.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "human_step"),
            budgetCharacters: 80,
            text: "Available only during the resumed turn; use the digest's step numbers and § IDs.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "human_step_tool.definition.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "human_step"),
            budgetCharacters: 47,
            text: "One step or a range of at most 20, such as 3-5.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "human_step_tool.definition.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "human_step"),
            budgetCharacters: 50,
            text: "Window § ID from the digest, or its window number.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 105,
            text: "Tell Braus's memory what task you are working on, so the app actions that serve it are recorded under it ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.2"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 105,
            text: "and can later be learned and reused. begin: before acting on apps for a new request, with goal (what the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.3"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 105,
            text: "person wants, resolved from the conversation), result, constraints, and inputs (each with name, value or ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.4"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 105,
            text: "none when still missing, kind, role, source and source_ref; secret true for passwords, tokens and codes, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.5"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 106,
            text: "whose value is never kept). update: when the request or your understanding of it changes; revision is the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.6"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 105,
            text: "revision you last read. checkpoint: when a meaningful part is done, with its note and outputs. end: with ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.7"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 114,
            text: "outcome completed, failed or abandoned, a note and the outputs, and for a completed task result_check: what Braus ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.8"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 107,
            text: "reads itself to verify the result, one or a list of {file_written|file_changed|file_unchanged|file_absent: ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.9"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 150,
            text: "absolute path}, {file_moved|file_copied: path, to: path}, {file: path, contains: text}, {window: title, app, open}, {element: label, app, value|state|",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.10"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 111,
            text: "present}, or {none: why} when the task leaves nothing to read; also at a checkpoint, for a stage's own result, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.11"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 85,
            text: "and in interpret when the end gave none. resume: an unfinished task of yours, by its ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.12"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 106,
            text: "task id, after a restart; never begin it again. status: the open task. A checkpoint and an end answer the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.13"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 107,
            text: "candidate procedure Braus segmented from your actions (its steps and blocks, one step per UI action); then ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.14"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 109,
            text: "interpret it: candidate, procedure {label, outcome}, parts [{part b1.., label, outcome}], phases [{from, to, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.15"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 101,
            text: "label}] (the task's own stages, such as opening the file or saving a copy), steps [{step 1.., label, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.16"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 98,
            text: "outcome}], parameters [{name, role, kind, direction, value or none to take the task input of that ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.17"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 108,
            text: "name, source, secret}], uses [{step, argument, position, template such as {name}.{extension}}]. Only stated ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.18"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 102,
            text: "uses become parameters. candidate: the latest candidate of one of your tasks. begin also searches the ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.19"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 109,
            text: "procedures learned on this Mac for remaining (the work still to do; the goal when omitted) and needs [{text, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.20"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 108,
            text: "app}], unless recall is false, and answers recall_proposal: per need a few learned sources, each whole, one ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.21"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 107,
            text: "line per step (number, app, operation, label). choose: proposal, plan [{need, tracts [{source, from, to}], ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.22"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 111,
            text: "covered all, part, none or ambiguous, uncovered, alternatives, settled_by}]; Braus checks the plan and answers ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.23"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 110,
            text: "recall with the tracts' steps, the task's values bound, conditions and evidence. With no source, or none that ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.24"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 99,
            text: "fits, do not choose. recall: search again, with reason request_changed, input_changed, new_need or ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.25"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 108,
            text: "path_unusable. use (also in checkpoint and end): [{query (the one choose answered), need, outcome followed, ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.26"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 100,
            text: "adapted, abandoned or not_executed, cause, note}]. reconcile: call (the id of an earlier call whose ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.27"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 104,
            text: "effect was not known), finding happened, not_happened or unknown, evidence (the id of a later completed ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.28"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 101,
            text: "call that read it), note: until then Braus refuses to repeat that call or to act on what it reached. ",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "memory_task_tool.report.v1.29"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "memory_task"),
            budgetCharacters: 33,
            text: "This tool performs no app action.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool.press.v1.description.ending"),
            owner: "AutomationMCP",
            delivery: .toolDescription(tool: "press"),
            budgetCharacters: 8,
            text: "refused.",
            legacy: true
        ),
    ]
}
