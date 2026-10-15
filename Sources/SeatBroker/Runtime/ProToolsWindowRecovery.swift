import AppKit
import ApplicationServices

/// Requests a window from an already running Pro Tools instance. A session keeps its editor;
/// without a session, File > Dashboard opens the starting window. Neither command requests activation.
@MainActor
enum ProToolsWindowRecovery {
    struct Item<Element> {
        let element: Element
        let enabled: Bool
    }

    /// The menu state chooses one command. A timeout still counts as its single attempt;
    /// the broker's subsequent window reading establishes whether a window appeared.
    static func request<Element>(
        edit           : Item<Element>?,
        dashboard      : Item<Element>?,
        sessionOpen    : Bool?,
        windowAvailable: () -> Bool,
        press          : (Element) -> AXError
    ) throws -> String? {
        guard !windowAvailable() else { return nil }
        guard let sessionOpen,
              let item = sessionOpen ? edit : dashboard, item.enabled
        else {
            throw SeatBrokerError.driver("Pro Tools has no available window command. Open its Dashboard or Edit window and ask again.")
        }
        let path = sessionOpen ? "Window > Edit" : "File > Dashboard..."
        let answer = press(item.element)
        guard answer == .success || answer == .cannotComplete else {
            throw SeatBrokerError.driver("Pressing \(path) returned AXError \(answer.rawValue). The command was not repeated.")
        }
        return path
    }

    static func request(processID: pid_t) throws {
        guard let application = NSRunningApplication(processIdentifier: processID),
              application.bundleIdentifier == "com.avid.ProTools", !application.isTerminated
        else { throw SeatBrokerError.driver("The Pro Tools instance is no longer available.") }
        let reader = MenuReader()
        let root = AXUIElementCreateApplication(processID)
        guard let raw = try reader.value(root, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { throw SeatBrokerError.driver("Pro Tools does not expose its menu bar.") }
        let bar = unsafeDowncast(raw, to: AXUIElement.self)
        let edit = try reader.item("Edit", in: "Window", bar: bar)
        let dashboard = try reader.item("Dashboard...", in: "File", bar: bar)
        let close = try reader.item("Close Session", in: "File", bar: bar)
        try Task.checkCancellation()
        guard !application.isTerminated else {
            throw SeatBrokerError.driver("The Pro Tools instance ended before the window request.")
        }
        if TargetEnumerator.hasWindowOnAnotherDesktop(of: processID) {
            throw SeatBrokerError.windowOnAnotherDesktop(application: "Pro Tools")
        }
        _ = try request(
            edit           : edit,
            dashboard      : dashboard,
            sessionOpen    : close?.enabled,
            windowAvailable: { !TargetEnumerator.windows(of: processID).isEmpty },
            press          : { item in
                var owner: pid_t = 0
                guard AXUIElementGetPid(item, &owner) == .success, owner == processID else { return .invalidUIElement }
                var actions: CFArray?
                guard AXUIElementCopyActionNames(item, &actions) == .success,
                      (actions as? [String])?.contains(kAXPressAction) == true
                else { return .actionUnsupported }
                AXUIElementSetMessagingTimeout(item, 0.5)
                return AXUIElementPerformAction(item, kAXPressAction as CFString)
            }
        )
    }

    /// A bounded reading of the measured English menu paths. Missing or localized paths refuse;
    /// an unreadable enabled state never means that the session is closed.
    private struct MenuReader {
        let deadline = ContinuousClock.now + .seconds(1)

        func value(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { throw SeatBrokerError.driver("Pro Tools menu reading timed out.") }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            switch status {
                case .success: return raw
                case .noValue, .attributeUnsupported: return nil
                default: throw SeatBrokerError.driver("Pro Tools menu reading returned AXError \(status.rawValue).")
            }
        }

        func item(_ title: String, in menu: String, bar: AXUIElement) throws -> Item<AXUIElement>? {
            let headers = try (value(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
                try value($0, kAXTitleAttribute) as? String == menu
            }
            guard headers.count == 1,
                  let content = try value(headers[0], kAXChildrenAttribute) as? [AXUIElement], content.count == 1
            else { return nil }
            let found = try (value(content[0], kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
                let name = try value($0, kAXTitleAttribute) as? String
                return name?.replacingOccurrences(of: "…", with: "...") == title
            }
            guard found.count == 1,
                  try value(found[0], kAXRoleAttribute) as? String == kAXMenuItemRole,
                  let enabled = try value(found[0], kAXEnabledAttribute) as? Bool
            else { return nil }
            return Item(element: found[0], enabled: enabled)
        }
    }
}
