// desk permissions: one JSON line with the Accessibility and Screen Recording grants of this process chain
// (the terminal that runs bench.sh), which is what the benchmark's child binaries inherit. Never prompts.
// desk press <pid> <menu> <item>: AXPress on one menu bar item without activating the app (a File > New Window
// opens a window and leaves the app in the background). One JSON line {"ok": bool, "error": ...}. Built to .build/desk.
// desk quit <pid>: asks the app to quit as the Quit menu command does; a signal makes some apps (DaVinci Resolve)
// relaunch with a crash report instead.
// desk set-text <pid> <window title> <file>: writes the file into that window's first text area, caret and scroll
// bars at the start, through accessibility and without activation (the state reset between benchmark blocks).
// desk button <pid> <title>: AXPress on the first button with that title in any window of the app.
// desk escape <pid>: posts Escape to the app alone; refused for DaVinci Resolve, which quits on it (ADR 0039).
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func titled(_ elements: [AXUIElement], _ title: String) -> AXUIElement? {
    elements.first { (attribute($0, kAXTitleAttribute) as? String) == title }
}

/// Every descendant of `root` with `role`, depth first, at most `limit` elements visited.
func descendants(_ root: AXUIElement, role: String, limit: Int = 3000) -> [AXUIElement] {
    var found: [AXUIElement] = [], stack = [root], visited = 0
    while let element = stack.popLast(), visited < limit {
        visited += 1
        if (attribute(element, kAXRoleAttribute) as? String) == role { found.append(element) }
        stack += children(element).reversed()
    }
    return found
}

func application(_ text: String) -> AXUIElement? {
    guard let pid = Int32(text), kill(pid, 0) == 0 else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    return app
}

func windows(_ app: AXUIElement) -> [AXUIElement] {
    attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
}

func emit(_ report: [String: Any]) {
    print(String(decoding: try! JSONSerialization.data(withJSONObject: report), as: UTF8.self))
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "permissions":
    emit(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()])
case "press" where arguments.count == 4:
    guard let pid = Int32(arguments[1]), kill(pid, 0) == 0 else {
        emit(["ok": false, "error": "no such process"])
        exit(1)
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    guard let bar = attribute(app, kAXMenuBarAttribute) else {
        emit(["ok": false, "error": "no menu bar"])
        exit(1)
    }
    guard let menu = titled(children(bar as! AXUIElement), arguments[2]),
          let list = children(menu).first,
          let item = titled(children(list), arguments[3]) else {
        emit(["ok": false, "error": "menu item not found"])
        exit(1)
    }
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    emit(["ok": result == .success, "error": result == .success ? NSNull() : "AXPress \(result.rawValue)"])
    exit(result == .success ? 0 : 1)
case "quit" where arguments.count == 2:
    guard let pid = Int32(arguments[1]), let app = NSRunningApplication(processIdentifier: pid) else {
        emit(["ok": false, "error": "no such process"])
        exit(1)
    }
    let asked = app.terminate()
    emit(["ok": asked, "error": asked ? NSNull() : "the app refused the quit request"])
    exit(asked ? 0 : 1)
case "set-text" where arguments.count == 4:
    guard let app = application(arguments[1]), let text = try? String(contentsOfFile: arguments[3], encoding: .utf8) else {
        emit(["ok": false, "error": "no such process or file"])
        exit(1)
    }
    let window = windows(app).first { (attribute($0, kAXTitleAttribute) as? String ?? "").contains(arguments[2]) }
    guard let window, let area = descendants(window, role: kAXTextAreaRole).first else {
        emit(["ok": false, "error": "no text area in a window titled like \(arguments[2])"])
        exit(1)
    }
    let written = AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, text as CFString)
    var start = CFRange(location: 0, length: 0)
    let caret = AXValueCreate(.cfRange, &start).map {
        AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, $0)
    }
    let bars = descendants(window, role: kAXScrollBarRole)
    let scrolled = bars.filter {
        AXUIElementSetAttributeValue($0, kAXValueAttribute as CFString, NSNumber(value: 0.0)) == .success
    }.count
    emit(["ok": written == .success, "error": written == .success ? NSNull() : "AXValue \(written.rawValue)",
          "caret": caret == .success, "scrollBars": bars.count, "scrolled": scrolled])
    exit(written == .success ? 0 : 1)
case "button" where arguments.count == 3:
    guard let app = application(arguments[1]) else {
        emit(["ok": false, "error": "no such process"])
        exit(1)
    }
    // Photoshop titles the button with a typographic apostrophe.
    let wanted = arguments[2].replacingOccurrences(of: "\u{2019}", with: "'")
    let button = windows(app).lazy.flatMap { descendants($0, role: kAXButtonRole) }.first {
        (attribute($0, kAXTitleAttribute) as? String)?.replacingOccurrences(of: "\u{2019}", with: "'") == wanted
    }
    guard let button else {
        emit(["ok": false, "error": "no button titled \(arguments[2])"])
        exit(1)
    }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    emit(["ok": result == .success, "error": result == .success ? NSNull() : "AXPress \(result.rawValue)"])
    exit(result == .success ? 0 : 1)
case "escape" where arguments.count == 2:
    guard let pid = Int32(arguments[1]), let running = NSRunningApplication(processIdentifier: pid) else {
        emit(["ok": false, "error": "no such process"])
        exit(1)
    }
    let name = (running.localizedName ?? "") + (running.bundleIdentifier ?? "")
    guard !name.localizedCaseInsensitiveContains("resolve") else {
        emit(["ok": false, "error": "refused: Escape on its only window quits DaVinci Resolve"])
        exit(1)
    }
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid)
    }
    emit(["ok": true, "error": NSNull()])
default:
    emit(["ok": false, "error": "usage: desk permissions | desk press <pid> <menu> <item> | desk quit <pid> | "
                               + "desk set-text <pid> <window title> <file> | desk button <pid> <title> | desk escape <pid>"])
    exit(2)
}
