import Foundation

/// InteractionSemanticReading supplies one bounded AX message. Lists must respect the requested limit.
/// The native adapter and fake-reader benchmarks exercise the same probe and admission rules.
protocol InteractionSemanticReading {
    associatedtype Node
    func same(_ first: Node, _ second: Node) -> Bool
    func read(_ node: Node, _ attribute: String, limit: Int) -> InteractionSemanticProbe.Value<Node>
    /// Values `from..<from + limit` of a list attribute, for reading a long collection in batches.
    func read(_ node: Node, _ attribute: String, from: Int, limit: Int) -> InteractionSemanticProbe.Value<Node>
    /// How many values a list attribute holds; nil when the reader cannot tell.
    func count(_ node: Node, _ attribute: String) -> Int?
    /// Several attributes of one node in one message where the platform allows it.
    func values(_ node: Node, _ attributes: [String]) -> [InteractionSemanticProbe.Value<Node>]
    /// The process that owns a node; nil when the reader knows only one.
    func owner(_ node: Node) -> Int32?
}

extension InteractionSemanticReading {
    func read(_ node: Node, _ attribute: String, from: Int, limit: Int) -> InteractionSemanticProbe.Value<Node> {
        guard case .nodes(let nodes, let complete) = read(node, attribute, limit: from + limit) else {
            return read(node, attribute, limit: from + limit)
        }
        return .nodes(Array(nodes.dropFirst(from)), complete: complete)
    }

    func count(_ node: Node, _ attribute: String) -> Int? {
        guard case .nodes(let nodes, true) = read(node, attribute, limit: 1_000_000) else { return nil }
        return nodes.count
    }

    func values(_ node: Node, _ attributes: [String]) -> [InteractionSemanticProbe.Value<Node>] {
        attributes.map { read(node, $0, limit: 1) }
    }

    func owner(_ node: Node) -> Int32? { nil }
}

/// InteractionSemanticProbe prioritizes focus, its ancestors and selected collection members.
/// Caps: 128 elements, 1,024 messages, 100 ms; at the 0.06-0.09 ms a message a live log measured,
/// a full probe of a long list costs 70-95 ms, under a third of the quickest tenth of human input gaps (260 ms).
/// Before the capped walk it searches the in-scope windows for collections, reading only roles,
/// and reads their selected rows and children first, so selected objects are never lost to the cap.
/// The time box stops new messages; the native adapter caps the one outstanding message at 5 ms.
enum InteractionSemanticProbe {
    enum Value<Node> {
        case string(String), bool(Bool), integer(Int), node(Node), nodes([Node], complete: Bool)
        case unsupported, unread
    }

    /// ScanMemory carries the role-only collection search from one probe of a process to the next, so a
    /// slow application that never answers a whole search inside one time box still completes it over a
    /// few actions. Paths start at their window. It expires, and a new search starts, after `lifetime`.
    final class ScanMemory<Node> {
        struct Window {
            var frontier: [[Node]]
            var found: [[Node]] = []
            var broken = false
            var complete: Bool { frontier.isEmpty && !broken }
        }
        static var lifetime: Double { 120 }
        private(set) var processID: Int32
        private(set) var started: Double
        var windows: [Int: Window] = [:]

        init(processID: Int32, started: Double) { self.processID = processID; self.started = started }

        /// Starts a new search when the process changed or the remembered one expired.
        func renew(processID: Int32, at time: Double) {
            guard processID != self.processID || time - started >= Self.lifetime else { return }
            self.processID = processID
            started = time
            windows = [:]
        }
    }

    static func capture<R: InteractionSemanticReading>(
        reader: R, application: R.Node, processID: Int32, windows: Set<Int>,
        maximumElements: Int = 128, maximumReads: Int = 1024, seconds: Double = 0.1, maximumScanNodes: Int = 96,
        memory: ScanMemory<R.Node>? = nil,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        isReserved: (String) -> Bool
    ) -> InteractionSemanticSnapshot {
        typealias Snapshot = InteractionSemanticSnapshot
        let start = now()
        let deadline = start + seconds
        var result = Snapshot(processID: processID, interval: .init(start: start, end: start))
        var nodes: [R.Node] = []
        var visited = Set<Int>()
        var queue: [Int] = []
        var captions: [Int: Int] = [:]
        func read(_ node: R.Node, _ name: String, limit: Int? = nil) -> Value<R.Node> {
            guard now() < deadline, result.attributeReads < maximumReads else {
                result.truncated = true
                return .unread
            }
            result.attributeReads += 1
            return reader.read(node, name, limit: limit ?? min(32, maximumElements))
        }
        func intern(_ node: R.Node, parent: Int? = nil, window: Int? = nil) -> Int? {
            if let id = nodes.firstIndex(where: { reader.same($0, node) }) {
                if result.elements[id].parent == nil { result.elements[id].parent = parent }
                if result.elements[id].window == nil { result.elements[id].window = window }
                return id
            }
            guard nodes.count < maximumElements else { result.truncated = true; return nil }
            let id = nodes.count
            nodes.append(node)
            result.elements.append(.init(id: id, window: window, parent: parent))
            queue.append(id)
            return id
        }
        func string(_ node: R.Node, _ name: String) -> String? {
            if case .string(let text) = read(node, name) { return String(text.prefix(160)) }
            return nil
        }
        func flag(_ node: R.Node, _ name: String) -> Snapshot.Answer<Bool> {
            switch read(node, name) {
            case .bool(let value): return .value(value)
            case .unsupported: return .unsupported
            default: return .unread
            }
        }
        func integer(_ node: R.Node, _ name: String) -> Snapshot.Answer<Int> {
            switch read(node, name) {
            case .integer(let value): return .value(value)
            case .unsupported: return .unsupported
            default: return .unread
            }
        }
        func list(_ node: R.Node, _ name: String, parent: Int, window: Int?) -> (Snapshot.Answer<[Int]>, Bool) {
            switch read(node, name) {
            case .nodes(let members, let complete):
                let ids = members.prefix(32).compactMap { intern($0, parent: parent, window: window) }
                let whole = complete && ids.count == members.count
                if !whole { result.truncated = true }
                // A partial selected set cannot claim that it names all affected objects.
                return (whole ? .value(ids) : .unread, whole)
            case .unsupported: return (.unsupported, false)
            default:
                if name == "AXChildren" { result.truncated = true }
                return (.unread, false)
            }
        }
        switch read(application, "AXFocusedUIElement") {
        case .node(let node):
            if let id = intern(node) {
                result.focused = .value(id)
                var child = id
                for _ in 0..<8 {
                    guard case .node(let parent) = read(nodes[child], "AXParent"),
                          !reader.same(parent, application),
                          let parentID = intern(parent), parentID != child else { break }
                    result.elements[child].parent = parentID
                    child = parentID
                }
            }
        case .unsupported: result.focused = .unsupported
        default: break
        }
        var windowNodes: [(node: R.Node, number: Int)] = []
        var windowsComplete = false
        if case .nodes(let listed, let complete) = read(application, "AXWindows") {
            if !complete || listed.count > 8 { result.truncated = true }
            var found = Set<Int>()
            for node in listed.prefix(8) {
                if case .integer(let number) = read(node, "windowNumber"), windows.contains(number) {
                    found.insert(number)
                    _ = intern(node, window: number)
                    windowNodes.append((node, number))
                }
            }
            if !windows.isSubset(of: found) { result.truncated = true }
            windowsComplete = complete && listed.count <= 8 && windows.isSubset(of: found)
        } else { result.truncated = true }
        var listedChildren = Set<Int>()
        /// Classifies one interned node under the privacy policy. Returns whether its children may be read.
        let levelRoles = InteractionSemanticSnapshot.levelRoles
        func process(_ id: Int, members: Bool = true) -> Bool {
            let node = nodes[id]
            let role = string(node, "AXRole")
            let subrole = read(node, "AXSubrole")
            let classified: Bool
            let secure: Bool
            switch subrole {
            case .string(let value): classified = true; secure = value == "AXSecureTextField"
            case .unsupported: classified = true; secure = false
            default: classified = false; secure = false
            }
            var element = result.elements[id]
            if role == "AXSecureTextField" || secure {
                element.isProtected = true
            } else if role != nil && classified {
                let title = string(node, "AXTitle")
                let description = string(node, "AXDescription")
                if [title, description].compactMap({ $0 }).contains(where: isReserved) {
                    element.isProtected = true
                } else {
                    element.role = role
                    element.label = [title, description].compactMap { $0 }.first { !$0.isEmpty }
                    element.identifier = string(node, "AXIdentifier").flatMap { isReserved($0) ? nil : $0 }
                }
            }
            if element.isProtected {
                element.role = nil; element.label = nil; element.identifier = nil
                element.parent = nil; element.window = nil
                element.selected = .protected; element.expanded = .protected; element.index = .protected
                element.selectedRows = .protected; element.selectedChildren = .protected; element.members = .protected
                result.elements[id] = element
                if result.focused.value == id { result.focused = .protected }
                return false
            }
            guard classified, role != nil else {
                result.truncated = true
                result.elements[id] = element
                return false
            }
            if element.window == nil { element.window = integer(node, "windowNumber").value }
            // Out-of-scope focus remains unknown; its labels must not cross the intervention boundary.
            guard let window = element.window, windows.contains(window) else {
                result.elements[id] = .init(id: id)
                return false
            }
            element.selected = flag(node, "AXSelected")
            if levelRoles.contains(role ?? ""), case .string(let text) = read(node, "AXLevel"), Double(text) != nil {
                element.level = text
            }
            if ["AXRow", "AXOutline", "AXDisclosureTriangle"].contains(role ?? "") {
                element.expanded = flag(node, "AXExpanded")
                element.index = integer(node, "AXIndex")
            }
            if ["AXTable", "AXOutline", "AXList", "AXGrid", "AXBrowser", "AXGroup"].contains(role ?? "") {
                element.selectedRows = list(node, "AXSelectedRows", parent: id, window: window).0
                element.selectedChildren = list(node, "AXSelectedChildren", parent: id, window: window).0
                element.selectionIncomplete = element.selectedRows == .unread || element.selectedChildren == .unread
                if members, ["AXTable", "AXOutline", "AXList", "AXGrid"].contains(role ?? "") {
                    (element.members, element.membershipComplete) = list(node, "AXRows", parent: id, window: window)
                }
            }
            if role == "AXWindow", let label = element.label { result.windowTitles[window] = label }
            if element.label == nil, role == "AXStaticText" {
                element.label = string(node, "AXValue").flatMap { isReserved($0) ? nil : $0 }
            }
            if element.label == nil, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role ?? ""),
               case .node(let titleNode) = read(node, "AXTitleUIElement"), !reader.same(titleNode, node) {
                if let titleID = intern(titleNode, window: window) {
                    // Resolve after all nodes have passed the same privacy policy.
                    captions[id] = titleID
                }
            }
            result.elements[id] = element
            return true
        }
        func listChildren(_ id: Int) {
            guard listedChildren.insert(id).inserted, let window = result.elements[id].window else { return }
            _ = list(nodes[id], "AXChildren", parent: id, window: window)
        }
        /// Names each selected row by the file name its subtree carries, whatever column comes first, else by the
        /// longest text outside editable fields, values first. Every node read passes the privacy classification.
        func nameRows(_ rows: [Int]) {
            let readable: Set<String> = ["AXStaticText", "AXCell", "AXButton"]
            for row in rows where result.elements[row].label == nil && !result.elements[row].isProtected {
                var values: [String] = [], labels: [String] = [], files: [String] = []
                if let file = string(nodes[row], "AXFilename"), !isReserved(file) { files.append(file) }
                var frontier = [(row, 0)]
                var seen = 0
                while !frontier.isEmpty, seen < 16, now() < deadline {
                    let (id, depth) = frontier.removeFirst()
                    seen += 1
                    if id != row {
                        if visited.insert(id).inserted { guard process(id) else { continue } }
                        let element = result.elements[id]
                        guard !element.isProtected, let role = element.role else { continue }
                        if let label = element.label { labels.append(label) }
                        if files.isEmpty, role == "AXCell" || role == "AXImage",
                           let file = string(nodes[id], "AXFilename"), !isReserved(file) { files.append(file) }
                        if readable.contains(role), case .string(let text) = read(nodes[id], "AXValue"),
                           !isReserved(text) { values.append(String(text.prefix(160))) }
                    }
                    guard depth < 3 else { continue }
                    listChildren(id)
                    frontier += result.elements.indices.filter { result.elements[$0].parent == id }.map { ($0, depth + 1) }
                }
                let generic: Set<String> = ["cell", "button", "row", ""]
                func best(_ texts: [String]) -> String? {
                    texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !generic.contains($0.lowercased()) }.max { $0.count < $1.count }
                }
                result.elements[row].label = files.first ?? best(values) ?? best(labels)
            }
        }
        // Selection first: a role-only search finds the collections in each in-scope window, then
        // their ancestry, selection and selected members are classified before anything else.
        let scan = memory ?? ScanMemory<R.Node>(processID: processID, started: start)
        scan.renew(processID: processID, at: start)
        for (node, number) in windowNodes where scan.windows[number] == nil {
            scan.windows[number] = .init(frontier: [[node]])
        }
        let containers: Set<String> = ["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea",
                                        "AXTabGroup", "AXSheet", "AXDrawer"]
        let collections: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid", "AXBrowser"]
        var scanned = 0
        // Known collections are read before the search spends any of this probe's time.
        var chains: [(path: [R.Node], number: Int)] = []
        for number in windows.sorted() { for path in scan.windows[number]?.found ?? [] { chains.append((path, number)) } }
        searching: for number in windows.sorted() {
            guard var state = scan.windows[number] else { continue }
            defer { scan.windows[number] = state }
            while !state.frontier.isEmpty {
                guard scanned < maximumScanNodes, now() < deadline, result.attributeReads < maximumReads else { break searching }
                let path = state.frontier.removeFirst()
                scanned += 1
                let role = read(path[path.count - 1], "AXRole")
                if case .unread = role, now() >= deadline {
                    state.frontier.insert(path, at: 0)
                    break searching
                }
                guard case .string(let role) = role else {
                    if path.count > 1 { state.broken = true }
                    continue
                }
                if collections.contains(role) {
                    // A document window can hold more than eight lists (a DAW's edit window has nine).
                    if state.found.count >= 16 { state.broken = true } else {
                        state.found.append(path)
                        chains.append((path, number))
                    }
                    continue
                }
                guard containers.contains(role) else { continue }
                guard path.count < 8 else { state.broken = true; continue }
                // The search interns nothing, so it may list a wider slice than the walk.
                switch read(path[path.count - 1], "AXChildren", limit: maximumScanNodes) {
                case .nodes(let children, let complete):
                    if !complete { state.broken = true }
                    state.frontier += children.map { path + [$0] }
                case .unsupported: break
                default:
                    if now() >= deadline { state.frontier.insert(path, at: 0); break searching }
                    state.broken = true
                }
            }
        }
        var stale: [(path: [R.Node], number: Int)] = []
        for (chain, number) in chains {
            var parent: Int?
            var ids: [Int] = []
            for node in chain {
                guard let id = intern(node, parent: parent, window: number) else { break }
                ids.append(id)
                parent = id
            }
            guard ids.count == chain.count else { continue }
            var readable = true
            for id in ids where readable && visited.insert(id).inserted { readable = process(id, members: false) }
            guard readable, let collection = ids.last else { continue }
            guard let role = result.elements[collection].role, collections.contains(role) else {
                // A remembered path that no longer ends in a collection is forgotten.
                if result.elements[collection].role != nil { stale.append((chain, number)) }
                continue
            }
            let element = result.elements[collection]
            let selected = (element.selectedRows.value ?? []) + (element.selectedChildren.value ?? [])
            for row in selected where visited.insert(row).inserted {
                if process(row) { listChildren(row) }
            }
            // Rows carry their name in a descendant; classify a bounded subtree before the general walk.
            nameRows(selected)
            // Full membership comes last: its rows must not take the places of selected ones.
            if let window = result.elements[collection].window,
               ["AXTable", "AXOutline", "AXList", "AXGrid"].contains(role) {
                (result.elements[collection].members, result.elements[collection].membershipComplete)
                    = list(chain[chain.count - 1], "AXRows", parent: collection, window: window)
            }
        }
        for (chain, number) in stale {
            scan.windows[number]?.found.removeAll { $0.count == chain.count && zip($0, chain).allSatisfy(reader.same) }
            scan.windows[number]?.broken = true
        }
        let searched = windows.filter { scan.windows[$0]?.complete == true }
        result.scannedWindows = searched.sorted()
        let scanComplete = windowsComplete && searched == windows
        result.selectionScan = scanComplete
        var cursor = 0
        while cursor < queue.count, now() < deadline, result.attributeReads < maximumReads {
            let id = queue[cursor]
            cursor += 1
            if visited.insert(id).inserted {
                if process(id) { listChildren(id) }
            } else if result.elements[id].role != nil, !result.elements[id].isProtected,
                      result.elements[id].window.map(windows.contains) == true {
                listChildren(id)
            }
        }
        if cursor < queue.count || now() >= deadline || result.attributeReads >= maximumReads { result.truncated = true }
        for (field, caption) in captions {
            let label = result.elements[caption]
            if label.isProtected {
                result.elements[field].isProtected = true
                result.elements[field].label = nil
                result.elements[field].selected = .protected
                if result.focused.value == field { result.focused = .protected }
            } else { result.elements[field].label = label.label }
        }
        // Rows may export their name through a static child, never through an editable field's value.
        for id in result.elements.indices where result.elements[id].role == "AXRow" && result.elements[id].label == nil {
            let names = result.elements.filter { $0.parent == id && $0.role == "AXStaticText" && !$0.isProtected }
                .compactMap(\.label)
            if names.count == 1 { result.elements[id].label = names[0] }
        }
        // A child can be processed before its protected ancestor. Close the ancestry boundary
        // after the walk as well, before any labels or selection can leave this probe.
        let protected = Set(result.elements.filter(\.isProtected).map(\.id))
        let unclassified = Set(result.elements.filter { $0.role == nil && !$0.isProtected }.map(\.id))
        let parents = result.elements.map(\.parent)
        var focusWithheld = false
        for id in result.elements.indices {
            var ancestor: Int? = id
            var seen = Set<Int>()
            var inheritsProtection = false
            var unreadAncestor = false
            while let current = ancestor, result.elements.indices.contains(current), seen.insert(current).inserted {
                if protected.contains(current) { inheritsProtection = true; break }
                if unclassified.contains(current) { unreadAncestor = true }
                ancestor = parents[current]
            }
            if inheritsProtection {
                var withheld = Snapshot.Element(id: id)
                withheld.isProtected = true
                withheld.selected = .protected; withheld.expanded = .protected; withheld.index = .protected
                withheld.selectedRows = .protected; withheld.selectedChildren = .protected; withheld.members = .protected
                result.elements[id] = withheld
                if result.focused.value == id { result.focused = .protected }
            } else if unreadAncestor {
                result.elements[id] = .init(id: id)
                if result.focused.value == id {
                    result.focused = .unread
                    focusWithheld = true
                }
            }
        }
        if result.focused == .protected || focusWithheld {
            result.windowTitles.removeAll()
            for id in result.elements.indices where result.elements[id].role == "AXWindow" {
                result.elements[id].label = nil
                result.elements[id].identifier = nil
            }
        }
        for id in result.elements.indices where result.elements[id].membershipComplete {
            result.elements[id].membershipComplete = (result.elements[id].members.value ?? []).allSatisfy {
                visited.contains($0) && result.elements[$0].role != nil && !result.elements[$0].isProtected
            }
        }
        result.interval = .init(start: start, end: now())
        return result
    }
}
