// probe <pid>: one JSON line about the desktop around a target process, read independently of
// either driver: the frontmost process, the physical cursor, the target's windows and the display each
// one is on, and hashes of what the target shows (values, selection, focus, scroll position, window
// titles), which change when an action's effect lands.
// probe <pid> --pixels <file> --window <id> [--against <file>]: also captures the window with that window
// server id (the one a driver is bound to) as 8-bit gray at one pixel per point into <file>, and counts the
// pixels that changed against an earlier capture.
// probe --system: machine facts for the run meta row (thermal state, Low Power mode, displays).
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The vendor ID of the Seat's virtual display (VirtualDisplayConfiguration.vendorID): a window on it is
/// inside the seat, a window on any other display is on the person's desktop.
let seatVendor: UInt32 = 0xF0A7

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name) as? String).map { String($0.prefix(120)) } ?? ""
}

/// What a person would see change in a window, kept apart so an oracle can ask for one part.
struct Reading {
    var values: [String] = []
    var scroll: [String] = []
    var budget = 4000
}

func walk(_ element: AXUIElement, depth: Int, into reading: inout Reading) {
    guard depth < 40, reading.budget > 0 else { return }
    reading.budget -= 1
    let role = text(element, kAXRoleAttribute)
    if let value = attribute(element, kAXValueAttribute) {
        // The whole value: a 200-character prefix missed an insert at the end of a long document.
        let shown = (value as? String) ?? (value as? NSNumber)?.stringValue
        if let shown { if role == "AXScrollBar" { reading.scroll.append(shown) } else { reading.values.append(shown) } }
    }
    if let selected = attribute(element, kAXSelectedAttribute) as? Bool, selected { reading.values.append("selected") }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        walk(child, depth: depth + 1, into: &reading)
    }
}

/// FNV-1a: String.hashValue is seeded per process, so it cannot compare two readings.
func fnv1a(_ text: String) -> UInt64 {
    text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
}

func hash(_ parts: [String]) -> String { String(fnv1a(parts.joined(separator: "\u{1f}")), radix: 16) }

/// A pixel counts as changed when its gray level moves by this much: text and controls differ from their
/// background by far more, while scaling and color management of an unchanged window stay well below it.
let pixelStep = 24

/// The window as 8-bit gray at one pixel per point, without the cursor; nil when it cannot be captured or
/// is not a window of `owner`.
func grayCapture(_ windowID: CGWindowID, of owner: pid_t) -> (width: Int, height: Int, bytes: [UInt8])? {
    let done = DispatchSemaphore(value: 0)
    var image: CGImage?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
        guard let window = content?.windows.first(where: {
            $0.windowID == windowID && $0.owningApplication?.processID == owner
        }) else {
            done.signal()
            return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width))
        configuration.height = max(1, Int(window.frame.height))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                         configuration: configuration) { captured, _ in
            image = captured
            done.signal()
        }
    }
    guard done.wait(timeout: .now() + 3) == .success, let image else { return nil }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? (width, height, bytes) : nil
}

/// "<width>x<height>\n" then the gray bytes, the format `changedPixels` reads back.
func store(_ capture: (width: Int, height: Int, bytes: [UInt8]), at path: String) {
    var data = Data("\(capture.width)x\(capture.height)\n".utf8)
    data.append(contentsOf: capture.bytes)
    FileManager.default.createFile(atPath: path, contents: data)
}

/// Pixels that moved by `pixelStep` or more; nil without an earlier capture of the same size, as a resized
/// window compares nothing.
func changedPixels(_ capture: (width: Int, height: Int, bytes: [UInt8]), against path: String) -> Int? {
    guard let data = FileManager.default.contents(atPath: path), let end = data.firstIndex(of: 10) else { return nil }
    let size = String(decoding: data[..<end], as: UTF8.self)
    let earlier = [UInt8](data[(end + 1)...])
    guard size == "\(capture.width)x\(capture.height)", earlier.count == capture.bytes.count else { return nil }
    var changed = 0
    for index in 0..<earlier.count where abs(Int(earlier[index]) - Int(capture.bytes[index])) >= pixelStep {
        changed += 1
    }
    return changed
}

struct Screen {
    let id: CGDirectDisplayID
    let frame: CGRect
    var isSeat: Bool { CGDisplayVendorNumber(id) == seatVendor }
    var json: [String: Any] {
        ["id": id, "x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height,
         "builtin": CGDisplayIsBuiltin(id) != 0, "main": id == CGMainDisplayID(),
         "vendor": CGDisplayVendorNumber(id), "model": CGDisplayModelNumber(id), "seat": isSeat]
    }
}

func screens() -> [Screen] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).map { Screen(id: $0, frame: CGDisplayBounds($0)) }
}

func emit(_ report: [String: Any]) {
    print(String(decoding: try! JSONSerialization.data(withJSONObject: report), as: UTF8.self))
}

let argument = CommandLine.arguments.dropFirst().first ?? ""
if argument == "--system" {
    let info = ProcessInfo.processInfo
    let thermal = ["nominal", "fair", "serious", "critical"][min(info.thermalState.rawValue, 3)]
    emit(["thermalState": thermal, "lowPowerMode": info.isLowPowerModeEnabled,
          "physicalMemory": info.physicalMemory, "cores": info.activeProcessorCount,
          "os": info.operatingSystemVersionString, "displays": screens().map(\.json)])
    exit(0)
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    return arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

let pid = pid_t(Int32(argument) ?? 0)
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
var reading = Reading()
if let window = attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute) {
    walk(window as! AXUIElement, depth: 0, into: &reading)
}
var focusedValue: String?
var focus = ""
var selection = ""
if let focused = attribute(app, kAXFocusedUIElementAttribute) {
    let element = focused as! AXUIElement
    focusedValue = (attribute(element, kAXValueAttribute) as? String).map { String($0.prefix(200)) }
    focus = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
        .map { text(element, $0) }.joined(separator: "|")
    if let range = attribute(element, kAXSelectedTextRangeAttribute) {
        var value = CFRange()
        if AXValueGetValue(range as! AXValue, .cfRange, &value) { selection = "\(value.location),\(value.length)" }
    }
}
let axWindows: [[String: Any]] = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { window in
    ["title": text(window, kAXTitleAttribute), "role": text(window, kAXRoleAttribute),
     "subrole": text(window, kAXSubroleAttribute),
     "main": (attribute(window, kAXMainAttribute) as? Bool) ?? false,
     "minimized": (attribute(window, kAXMinimizedAttribute) as? Bool) ?? false]
}
let seats = screens()
let rows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let windows: [[String: Any]] = rows.compactMap { row in
    guard (row[kCGWindowOwnerPID as String] as? Int32) == pid, (row[kCGWindowLayer as String] as? Int) == 0,
          let bounds = row[kCGWindowBounds as String] as? [String: Double] else { return nil }
    let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
    let home = seats.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    return ["id": row[kCGWindowNumber as String] as? Int ?? 0, "onscreen": row[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "title": row[kCGWindowName as String] as? String ?? "",
            "x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height,
            "display": home.map { Int($0.id) } ?? -1, "seat": home?.isSeat ?? false]
}
let front = rows.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
// Only the window the caller names: a guess at the front window could be a person's window of the same app.
var pixels: Any = NSNull()
if let path = option("--pixels") {
    let id = option("--window").flatMap { Int($0) } ?? 0
    if let capture = id == 0 ? nil : grayCapture(CGWindowID(id), of: pid) {
        let changed = option("--against").flatMap { changedPixels(capture, against: $0) }
        store(capture, at: path)
        pixels = ["window": id, "width": capture.width, "height": capture.height,
                  "changed": changed.map { $0 as Any } ?? NSNull()]
    } else {
        FileManager.default.createFile(atPath: path, contents: nil)
        pixels = ["window": id, "error": id == 0 ? "no --window id" : "capture failed or not a window of the pid"]
    }
}
let cursor = CGEvent(source: nil)?.location ?? .zero
let frontmost = NSWorkspace.shared.frontmostApplication
let parts = [
    "values": hash(reading.values), "scroll": hash(reading.scroll), "selection": hash([selection]),
    "focus": hash([focus]),
    "windows": hash(axWindows.map { ($0["title"] as? String ?? "") + ($0["subrole"] as? String ?? "") } + ["\(windows.count)"])
]
emit([
    "frontmost": frontmost?.processIdentifier ?? 0,
    "frontmostName": frontmost?.localizedName ?? "",
    "frontWindowOwner": front?[kCGWindowOwnerPID as String] as? Int32 ?? 0,
    "cursor": [cursor.x, cursor.y],
    "windows": windows,
    "axWindows": axWindows,
    "displays": seats.map(\.json),
    "parts": parts,
    "digest": hash(["values", "scroll", "selection", "focus", "windows"].map { parts[$0] ?? "" }),
    "valueCount": reading.values.count,
    "selection": selection,
    "focusedValue": focusedValue ?? NSNull(),
    "pixels": pixels
])
