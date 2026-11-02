import ApplicationServices
import Foundation

/// NativeInteractionSemanticReader performs only optional intervention reads. Ordinary scene consumers
/// do not construct it. Each message has a 5 ms timeout (50 ms for structural reads) within the deadline, and lists
/// use count plus a capped slice.
package struct NativeInteractionSemanticReader: InteractionSemanticReading {
    let processID: Int32
    let deadline: Double
    let resolveWindow: @Sendable (AXUIElement) -> Int?
    /// Seconds one message may wait. An application still handling the input that triggered the read answers late:
    /// at 5 ms its window list did not answer and a whole structural read was lost (10 to 36% of reads).
    var messageTimeout = 0.005

    private func timeout() -> Float {
        Float(min(messageTimeout, max(0.0001, deadline - ProcessInfo.processInfo.systemUptime)))
    }

    func same(_ first: AXUIElement, _ second: AXUIElement) -> Bool { CFEqual(first, second) }

    func read(_ node: AXUIElement, _ attribute: String, limit: Int) -> InteractionSemanticProbe.Value<AXUIElement> {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return .unread }
        // Every node is reached from the application's own tree; one another process hosts in its window
        // (a remote view or extension) is read like the rest.
        var owner: pid_t = 0
        guard AXUIElementGetPid(node, &owner) == .success, owner > 0 else { return .unread }
        AXUIElementSetMessagingTimeout(node, timeout())
        if attribute == "windowNumber" {
            return resolveWindow(node).map { .integer($0) } ?? .unread
        }
        if ["AXWindows", "AXChildren", "AXRows", "AXSelectedRows", "AXSelectedChildren"].contains(attribute) {
            var count: CFIndex = 0
            let status = AXUIElementGetAttributeValueCount(node, attribute as CFString, &count)
            if status == .attributeUnsupported { return .unsupported }
            guard status == .success, count >= 0 else { return .unread }
            if count == 0 { return .nodes([], complete: true) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .unread }
            var values: CFArray?
            let copied = AXUIElementCopyAttributeValues(node, attribute as CFString, 0, min(count, limit), &values)
            guard copied == .success, let values = values as? [AnyObject],
                  values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return .unread }
            return .nodes(values.map { unsafeDowncast($0, to: AXUIElement.self) }, complete: count <= limit && values.count == count)
        }
        var value: CFTypeRef?
        // AXLevel is AXValue read as a number only: a level control's position, to two decimals.
        let status = AXUIElementCopyAttributeValue(node, (attribute == "AXLevel" ? "AXValue" : attribute) as CFString, &value)
        // A supported attribute without a value (common for AXSubrole on custom views) answers "none".
        // Reading it as unread left such nodes unclassified and stopped the walk beneath them.
        if status == .attributeUnsupported || status == .noValue { return .unsupported }
        guard status == .success, let value else { return .unread }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return .node(unsafeDowncast(value, to: AXUIElement.self)) }
        if let text = value as? String { return .string(text) }
        if CFGetTypeID(value) == CFBooleanGetTypeID(), let flag = value as? Bool { return .bool(flag) }
        if attribute == "AXLevel" {
            guard let number = value as? NSNumber else { return .unread }
            let level = (number.doubleValue * 100).rounded() / 100
            return .string(level == level.rounded() ? String(Int(level)) : String(level))
        }
        if attribute == "AXIndex", let number = value as? NSNumber { return .integer(number.intValue) }
        return .unread
    }

    func read(_ node: AXUIElement, _ attribute: String, from: Int, limit: Int) -> InteractionSemanticProbe.Value<AXUIElement> {
        guard ProcessInfo.processInfo.systemUptime < deadline, from >= 0, limit > 0 else { return .unread }
        AXUIElementSetMessagingTimeout(node, timeout())
        var values: CFArray?
        let status = AXUIElementCopyAttributeValues(node, attribute as CFString, from, limit, &values)
        if status == .attributeUnsupported { return .unsupported }
        guard status == .success, let values = values as? [AnyObject],
              values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return .unread }
        return .nodes(values.map { unsafeDowncast($0, to: AXUIElement.self) }, complete: values.count < limit)
    }

    func count(_ node: AXUIElement, _ attribute: String) -> Int? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(node, attribute as CFString, &count) == .success, count >= 0 else { return nil }
        return count
    }

    /// One message for several attributes; an attribute that fails reads as unsupported. "AXPositionX",
    /// "AXPositionY", "AXSizeWidth" and "AXSizeHeight" read AXPosition or AXSize as one number in whole points, for
    /// reading order and for a slider's thumb.
    func values(_ node: AXUIElement, _ attributes: [String]) -> [InteractionSemanticProbe.Value<AXUIElement>] {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return attributes.map { _ in .unread } }
        AXUIElementSetMessagingTimeout(node, timeout())
        let geometry = ["AXPositionX": "AXPosition", "AXPositionY": "AXPosition", "AXSizeWidth": "AXSize", "AXSizeHeight": "AXSize"]
        let asked = attributes.map { geometry[$0] ?? $0 }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, asked as CFArray, [], &values) == .success,
              let values = values as? [AnyObject], values.count == attributes.count else {
            return attributes.map { _ in .unread }
        }
        return zip(attributes, values).map { attribute, value in
            if geometry[attribute] != nil {
                guard CFGetTypeID(value) == AXValueGetTypeID() else { return .unsupported }
                let boxed = unsafeDowncast(value, to: AXValue.self)
                var point = CGPoint.zero, size = CGSize.zero
                let number: CGFloat? = switch attribute {
                case "AXPositionX": AXValueGetValue(boxed, .cgPoint, &point) ? point.x : nil
                case "AXPositionY": AXValueGetValue(boxed, .cgPoint, &point) ? point.y : nil
                case "AXSizeWidth": AXValueGetValue(boxed, .cgSize, &size) ? size.width : nil
                default: AXValueGetValue(boxed, .cgSize, &size) ? size.height : nil
                }
                return number.map { .integer(Int($0.rounded())) } ?? .unsupported
            }
            if CFGetTypeID(value) == AXUIElementGetTypeID() { return .node(unsafeDowncast(value, to: AXUIElement.self)) }
            if let text = value as? String { return .string(text) }
            if CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? URL { return .string(url.isFileURL ? url.lastPathComponent : url.absoluteString) }
            if CFGetTypeID(value) == CFBooleanGetTypeID(), let flag = value as? Bool { return .bool(flag) }
            return .unsupported
        }
    }

    func owner(_ node: AXUIElement) -> Int32? {
        var owner: pid_t = 0
        return AXUIElementGetPid(node, &owner) == .success && owner > 0 ? owner : nil
    }

    /// A structural read of the process's windows in `windows` (every window when empty), for the intervention
    /// report. Names and values pass `isReserved`; hosting processes are named by `hostName`.
    @concurrent
    package static func structure(
        processID: Int32, windows: Set<Int>, seconds: Double = 0.15,
        resolveWindow: @escaping @Sendable (AXUIElement) -> Int?,
        hostName: @escaping @Sendable (Int32) -> String?,
        isReserved: @escaping @Sendable (String) -> Bool
    ) async -> InteractionStructuralRead {
        let start = ProcessInfo.processInfo.systemUptime
        guard AXIsProcessTrusted() else { return .init(processID: processID, interval: .init(start: start, end: start), unread: windows.sorted()) }
        return InteractionStructuralReader.capture(
            reader: NativeInteractionSemanticReader(processID: processID, deadline: start + seconds, resolveWindow: resolveWindow,
                                                    messageTimeout: 0.05),
            application: AXUIElementCreateApplication(processID), processID: processID, windows: windows,
            seconds: seconds, hostName: hostName, isReserved: isReserved)
    }

    @concurrent
    package static func capture(
        processID: Int32, windows: Set<Int>, seconds: Double = 0.1,
        resolveWindow: @escaping @Sendable (AXUIElement) -> Int?,
        isReserved: @escaping @Sendable (String) -> Bool
    ) async -> InteractionSemanticSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        guard AXIsProcessTrusted() else {
            return .init(processID: processID, interval: .init(start: start, end: start))
        }
        let memory = Memory.shared.take(processID)
        defer { Memory.shared.put(memory, for: processID) }
        return InteractionSemanticProbe.capture(
            reader: NativeInteractionSemanticReader(processID: processID, deadline: start + seconds, resolveWindow: resolveWindow),
            application: AXUIElementCreateApplication(processID), processID: processID,
            windows: windows, seconds: seconds, memory: memory, isReserved: isReserved
        )
    }

    /// One collection search per process, handed to one probe at a time. AX element references stay
    /// in this process and are never encoded.
    private final class Memory: @unchecked Sendable {
        static let shared = Memory()
        private let lock = NSLock()
        private var scans: [Int32: InteractionSemanticProbe.ScanMemory<AXUIElement>] = [:]

        func take(_ processID: Int32) -> InteractionSemanticProbe.ScanMemory<AXUIElement> {
            lock.withLock {
                scans.removeValue(forKey: processID)
                    ?? .init(processID: processID, started: ProcessInfo.processInfo.systemUptime)
            }
        }

        func put(_ memory: InteractionSemanticProbe.ScanMemory<AXUIElement>, for processID: Int32) {
            lock.withLock {
                // Keep a few processes; a lent application is usually one.
                if scans.count >= 4, scans[processID] == nil, let oldest = scans.min(by: { $0.value.started < $1.value.started }) {
                    scans[oldest.key] = nil
                }
                scans[processID] = memory
            }
        }
    }
}
