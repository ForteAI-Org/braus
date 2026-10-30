import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import InteractionListener
import Perception
import PerceptionCore
import ScreenCapture

/// InteractionSceneReader reads the exact surface recorded by the listener, including popup windows.
/// The caller supplies the production pipeline. No memory, agent, Seat or application UI is constructed.
public struct InteractionSceneReader: Sendable {
    private let pipeline: ScenePipeline
    private let capturer: StillCapturer

    public init(pipeline: ScenePipeline) {
        self.pipeline = pipeline
        capturer = StillCapturer()
    }

    public func scene(window: InteractionWindow, bundleID: String, appName: String) async throws -> SceneSnapshot {
        let image = try await capturer.captureWindow(number: window.number, frame: window.frame,
                                                     expectedProcessID: window.processID)
        return try await pipeline.perceive(image, of: ScenePipeline.Window(
            bundleID: bundleID, appName: appName, title: window.title ?? "",
            processID: window.processID, frame: window.frame, windowNumber: window.number
        ))
    }

    /// Reports AX in the routed application at the current point, explicitly after input.
    /// App-scoped hit testing avoids unrelated overlays; a process mismatch still rejects the hit.
    @MainActor
    public static func accessibility(at point: CGPoint, processID: Int32) -> AccessibilityPointResult {
        guard AXIsProcessTrusted() else { return AccessibilityPointResult(status: "permission_missing") }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element)
        guard result == .success, let element else {
            return AccessibilityPointResult(status: "unavailable(\(result.rawValue))")
        }
        AXUIElementSetMessagingTimeout(element, 0.1)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == processID else {
            return AccessibilityPointResult(status: "different_process", processID: owner)
        }
        // The deadline bounds traversal; each AX message also has a short timeout.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        func attribute(_ node: AXUIElement, _ key: CFString) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.02)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, key, &value) == .success else { return nil }
            return value
        }
        func facts(_ node: AXUIElement) -> InteractionAXLabel.Facts {
            let role = attribute(node, kAXRoleAttribute as CFString) as? String
            let title = attribute(node, kAXTitleAttribute as CFString) as? String
            let description = attribute(node, kAXDescriptionAttribute as CFString) as? String
            let filename = attribute(node, kAXFilenameAttribute as CFString) as? String
            var displayValue: String?
            let subrole = attribute(node, kAXSubroleAttribute as CFString) as? String
            if subrole != "AXSecureTextField", ProcessInfo.processInfo.systemUptime < deadline {
                var settable = DarwinBoolean(true)
                let readOnlyField = role == "AXTextField"
                    && AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success
                    && !settable.boolValue
                if InteractionAXLabel.allowsDisplayValue(role: role, subrole: subrole,
                                                        valueIsSettable: readOnlyField ? false : nil) {
                    displayValue = attribute(node, kAXValueAttribute as CFString) as? String
                }
            }
            return .init(role: role, title: title, description: description, displayValue: displayValue,
                         filename: filename.map { ($0 as NSString).lastPathComponent })
        }
        let role = attribute(element, kAXRoleAttribute as CFString) as? String
        let name = InteractionAXLabel.resolve(element, facts: facts, children: { node in
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, 12, &values) == .success
            else { return [] }
            return (values as? [AXUIElement]) ?? []
        })
        return AccessibilityPointResult(status: "read_after_event", role: role, label: name?.label,
                                        processID: owner, labelSource: name?.source)
    }
}

extension InteractionSceneReader {
    /// Reads point or focused-element metadata without field values. A menu-bar hit starts at AXMenuBar;
    /// label values come only from a separate static title element. IPC has a 20 ms timeout and a 150 ms deadline.
    @concurrent
    public static func metadata(
        at point: CGPoint?,
        processID: Int32,
        menuBar: Bool = false,
        isReservedLabel: @escaping @Sendable (String) -> Bool
    ) async -> InteractionElementMetadata? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.02)
        func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.02)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
            return value
        }
        var element: AXUIElement?
        if menuBar {
            guard let point, let value = attribute(application, "AXMenuBar"),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let bar = value as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, 0.02)
            var children: CFArray?
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  AXUIElementCopyAttributeValues(bar, kAXChildrenAttribute as CFString, 0, 64, &children) == .success,
                  let items = children as? [AXUIElement] else { return nil }
            element = items.first { item in
                guard attribute(item, "AXRole") as? String == "AXMenuBarItem",
                      let position = attribute(item, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
                      let size = attribute(item, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                      AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return false }
                return CGRect(origin: origin, size: dimensions).contains(point)
            }
        } else if let point {
            guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element) == .success
            else { return nil }
        } else {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            element = (focused as! AXUIElement)
        }
        guard let element else { return nil }
        // The application's own hit test or focus can answer with content another process hosts in its window,
        // a remote view or extension: it is still that window's element.
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              owner == processID || !menuBar && owner != ProcessInfo.processInfo.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.02)
        var titleElement: AXUIElement?
        var didReadTitleElement = false
        return InteractionElementMetadata.read(
            isReservedLabel: isReservedLabel,
            titleElementAttribute: { key in
                if !didReadTitleElement {
                    didReadTitleElement = true
                    if let value = attribute(element, "AXTitleUIElement"),
                       CFGetTypeID(value) == AXUIElementGetTypeID(), !CFEqual(value, element) {
                        let label = value as! AXUIElement
                        var labelOwner: pid_t = 0
                        if AXUIElementGetPid(label, &labelOwner) == .success, labelOwner == owner {
                            titleElement = label
                        }
                    }
                }
                return titleElement.flatMap { attribute($0, key) as? String }
            },
            isWindowButton: { key in
                guard let window = attribute(element, "AXWindow"), CFGetTypeID(window) == AXUIElementGetTypeID(),
                      let button = attribute(window as! AXUIElement, key), CFGetTypeID(button) == AXUIElementGetTypeID()
                else { return false }
                return CFEqual(button, element)
            },
            attribute: { attribute(element, $0) as? String }
        )
    }
}
