import Foundation

/// InteractionSemanticSnapshot is intervention-only AX evidence. Node IDs belong to this one probe;
/// they are not object identities or click targets. No field value, text range or input count is stored.
package struct InteractionSemanticSnapshot: Codable, Equatable, Sendable {
    package enum Answer<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        case value(Value)
        case unsupported
        case unread
        case protected

        package var value: Value? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    /// Interval uses CLOCK_UPTIME_RAW seconds, the listener's clock. Invalid intervals are unknown.
    package struct Interval: Codable, Equatable, Sendable {
        package let start: Double
        package let end: Double

        package init(start: Double, end: Double) { self.start = start; self.end = end }
        package var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end >= start }
        package func overlaps(_ other: Self) -> Bool {
            isValid && other.isValid && start <= other.end && other.start <= end
        }
        package var milliseconds: Double { isValid ? (end - start) * 1000 : 0 }
    }

    package struct Element: Codable, Equatable, Sendable {
        package let id: Int
        package var window: Int?
        package var role: String?
        package var label: String?
        package var identifier: String?
        package var parent: Int?
        package var isProtected = false
        package var selected: Answer<Bool> = .unread
        package var expanded: Answer<Bool> = .unread
        package var index: Answer<Int> = .unread
        package var selectedRows: Answer<[Int]> = .unread
        package var selectedChildren: Answer<[Int]> = .unread
        package var members: Answer<[Int]> = .unread
        package var membershipComplete = false
        package var selectionIncomplete = false
        /// A slider's or stepper's position: a number, never text. Absent in older sidecars.
        package var level: String? = nil

        package init(id: Int, window: Int? = nil, role: String? = nil, label: String? = nil,
                     parent: Int? = nil) {
            self.id = id; self.window = window; self.role = role; self.label = label; self.parent = parent
        }
    }

    /// Controls whose value is a position a person sets by dragging or stepping, read as a number.
    package static let levelRoles: Set<String> = ["AXSlider", "AXIncrementor", "AXStepper"]

    package let version: Int
    package let processID: Int32
    package var interval: Interval
    package var focused: Answer<Int> = .unread
    package var elements: [Element] = []
    package var windowTitles: [Int: String] = [:]
    package var truncated = false
    /// True when the role-only collection search finished inside its bounds, so every collection in the
    /// in-scope windows had its selection read before the capped walk. Absent in older sidecars.
    package var selectionScan: Bool? = nil
    /// Windows whose collection search is complete, possibly over several probes of the same process.
    package var scannedWindows: [Int]? = nil
    package var attributeReads = 0

    package init(processID: Int32, interval: Interval) {
        version = 1; self.processID = processID; self.interval = interval
    }

    package var focusedElement: Element? {
        focused.value.flatMap { id in elements.first { $0.id == id } }
    }

    /// Only positive, native selection is returned. Unsupported, false, unread and protected stay separate.
    package var selectedElements: [Element] {
        let ids = Set(elements.flatMap { ($0.selectedRows.value ?? []) + ($0.selectedChildren.value ?? []) })
        return elements.filter { element in
            !element.isProtected && !ancestors(of: element).contains(where: \.selectionIncomplete)
                && (element.selected == .value(true) || ids.contains(element.id))
        }
    }

    package struct Selection {
        package let collection: Element
        package let objects: [Element]
    }

    /// A focused collection is the scope. Without focus, only a whole probe with one selected
    /// collection can name a scope. Partial lists and ambiguous parallel selections remain unknown.
    package func selection(in window: Int) -> Selection? {
        let collections = elements.filter {
            $0.window == window && !$0.isProtected && !$0.selectionIncomplete
                && ["AXTable", "AXOutline", "AXList", "AXGrid", "AXBrowser"].contains($0.role ?? "")
        }
        let candidates = collections.compactMap { collection -> Selection? in
            let rows = collection.selectedRows.value
            let children = collection.selectedChildren.value
            guard rows != nil || children != nil else { return nil }
            let ids = Set((rows ?? []) + (children ?? []))
            let objects = elements.filter { ids.contains($0.id) }
            guard !objects.isEmpty, objects.count == ids.count,
                  objects.allSatisfy({ !$0.isProtected && $0.window == window && identityKey($0) != nil }),
                  identityKey(collection) != nil else { return nil }
            return Selection(collection: collection, objects: objects)
        }
        if let focus = focusedElement, focus.window == window {
            let owners = Set(ancestors(of: focus).map(\.id))
            let scoped = candidates.filter { owners.contains($0.collection.id) }
            if scoped.count == 1 { return scoped[0] }
        }
        // A truncated walk is no obstacle once the bounded search has read every collection's selection.
        let searched = selectionScan == true || scannedWindows?.contains(window) == true
        return (!truncated || searched) && candidates.count == 1 ? candidates[0] : nil
    }

    /// This key compares bounded observations, not persistent app objects. Duplicate names or
    /// identifiers in the same ancestry are ambiguous and never establish continuity.
    package func identityKey(_ element: Element) -> String? {
        func key(_ item: Element) -> String? {
            guard !item.isProtected, let window = item.window, let role = item.role,
                  let name = item.identifier?.isEmpty == false ? item.identifier : item.label,
                  !name.isEmpty else { return nil }
            let parents = ancestors(of: item).dropFirst().map {
                "\($0.role ?? "?"):\($0.identifier ?? $0.label ?? "?")"
            }.joined(separator: "/")
            return "\(window)|\(role)|\(name)|\(parents)"
        }
        guard let value = key(element), elements.filter({ key($0) == value }).count == 1 else { return nil }
        return value
    }

    private func ancestors(of element: Element) -> [Element] {
        var current: Element? = element
        var result: [Element] = []
        var visited = Set<Int>()
        while let node = current, visited.insert(node.id).inserted {
            result.append(node)
            current = node.parent.flatMap { id in elements.first { $0.id == id } }
        }
        return result
    }

    package func row(containing element: Element) -> Element? {
        var current: Element? = element
        var visited = Set<Int>()
        while let node = current, visited.insert(node.id).inserted {
            if node.isProtected { return nil }
            if node.role == "AXRow" { return node }
            current = node.parent.flatMap { id in elements.first { $0.id == id } }
        }
        return nil
    }

    package var retainedBytes: Int {
        256 + elements.reduce(0) { total, element in
            total + 512 + [element.label, element.identifier].compactMap { $0 }.reduce(0) { $0 + $1.utf8.count * 4 }
        } + windowTitles.values.reduce(0) { $0 + $1.utf8.count * 4 }
    }

    package func withholding(_ transform: (String) -> String) -> Self {
        var result = self
        result.windowTitles = windowTitles.mapValues(transform)
        for index in result.elements.indices {
            result.elements[index].label = elements[index].label.map(transform)
            result.elements[index].identifier = elements[index].identifier.map(transform)
        }
        return result
    }
}
