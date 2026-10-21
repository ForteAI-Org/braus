import CoreGraphics
import Foundation

/// MacElementSource is where the walk reads elements from: the live accessibility API (`LiveMacElements`),
/// or a test's plain values. Each element is read in one request.
protocol MacElementSource {

    associatedtype Element

    /// One element's attributes in one request, under the messaging `timeout`; the failure when the
    /// request itself answered nothing usable.
    func read(_ element: Element, timeout: Float) -> Result<MacElementRead<Element>, MacReadFailure>

    /// The element's action names; empty when it has none.
    func actions(_ element: Element) -> Result<[String], MacReadFailure>

    /// A table's or an outline's header; nil when it has none.
    func header(_ element: Element) -> Result<Element?, MacReadFailure>
}

/// MacElementRead is one element's answer to the walk's request, decoded: the node's own attributes (no
/// path, children or actions yet), its three child lists, and the attributes that did not answer.
struct MacElementRead<Element> {

    var node: MacTreeNode
    /// Every child; the failure when the list did not answer.
    var children: Result<[Element], MacReadFailure>
    /// The visible children and rows; empty when absent or unread, where every child is followed instead.
    var visibleChildren: [Element]
    var visibleRows: [Element]
    /// The node's own attributes that did not answer, by name, and why.
    var unread: [String: MacReadFailure]

    init(node: MacTreeNode, children: Result<[Element], MacReadFailure> = .success([]), visibleChildren: [Element] = [],
         visibleRows: [Element] = [], unread: [String: MacReadFailure] = [:]) {
        self.node            = node
        self.children        = children
        self.visibleChildren = visibleChildren
        self.visibleRows     = visibleRows
        self.unread          = unread
    }
}

/// MacChild is one place in the list of children a walk follows: an element, or one that could not be
/// read and still holds its place, so that every sibling keeps its path.
enum MacChild<Element> {
    case element(Element)
    case unread(MacReadFailure)
}

/// MacChildList is the rule that decides which children a walk follows, shared by the read and by the
/// resolution of an address, so a path means the same element to both.
enum MacChildList {

    /// A table's or an outline's header and visible rows when it reports rows; else the visible children
    /// when it reports some; else every child. Only the header besides the rows: asking every child its role
    /// would cost one request per row of the model, thousands in Mail. A header that did not answer holds its
    /// place, so the rows keep their paths. `unlisted` is why the children were not listed, when they were not.
    static func followed<Element>(
        visibleOnly    : Bool,
        children       : Result<[Element], MacReadFailure>,
        visibleChildren: [Element],
        visibleRows    : [Element],
        header         : () -> Result<Element?, MacReadFailure>
    ) -> (children: [MacChild<Element>], unlisted: MacReadFailure?) {
        if visibleOnly, !visibleRows.isEmpty {
            let rows = visibleRows.map(MacChild.element)
            switch header() {
                case .success(let header) : return ((header.map { [.element($0)] } ?? []) + rows, nil)
                case .failure(let failure): return ([.unread(failure)] + rows, nil)
            }
        }
        if visibleOnly, !visibleChildren.isEmpty { return (visibleChildren.map(MacChild.element), nil) }
        switch children {
            case .success(let all)    : return (all.map(MacChild.element), nil)
            case .failure(let failure): return ([], failure)
        }
    }
}

/// MacTreeWalk is one read of a window: breadth first so a cut tree still holds every section's top,
/// records in visit order with their parent, the queue of elements still to read, and the window frame
/// that decides what is visible (`LiveMacTreeReader`'s rules).
struct MacTreeWalk<Source: MacElementSource> {

    struct Pending {
        let element: Source.Element
        let depth  : Int
        let parent : Int
        /// The element's position in its parent's child list, skipped siblings included: the path step that
        /// resolves it again.
        let slot   : Int
        /// The visible part of the window this element can show in: the window, narrowed by every scroll area
        /// above it.
        let clip   : CGRect?
    }

    struct Record {
        var node    : MacTreeNode
        let parent  : Int?
        let slot    : Int
        var children: [Int] = []
    }

    let source : Source
    let limits : MacTreeLimits
    /// When the read began on the monotonic clock: before the application and the window were looked up, so their
    /// cost counts against the budget too.
    let started: ContinuousClock.Instant
    /// The monotonic clock's reading now. The budget and the duration both come from it, never from the civil clock,
    /// which a person or the system may set at any time; a test gives a deterministic one.
    let now    : () -> ContinuousClock.Instant
    var records: [Record] = []
    var pending: [Pending] = []
    var stoppedBy: MacTreeRead.Stop?
    var skippedOffscreen = 0

    /// Reads `window`, listed at `index`, within `limits`. What did not answer is marked on its node
    /// (`MacUnread`); an element that answered nothing holds its place as an `AXUnknown` placeholder, so
    /// every sibling keeps its path. `nodesVisited` counts the elements that answered.
    ///
    /// The budget (`limits.deadline`) runs from `started` on `now`, the monotonic clock: it is checked before each
    /// element, so a walk that runs out stops between two nodes with the paths read so far and `stoppedBy` deadline.
    /// The check comes before an element's visit only: the visit then makes up to three requests (its attributes,
    /// its action names, a table's or an outline's header), each bounded by the element's messaging timeout, so the
    /// read can run past the budget by that visit's requests. A budget already spent before the window itself is read
    /// leaves nothing read: `windowUnreadable` with `timedOut`, never `windowNotFound`, which stays for a window that
    /// is gone and for an element limit that let nothing be read.
    static func read(window: Source.Element, index: Int, source: Source, limits: MacTreeLimits,
                     started: ContinuousClock.Instant = .now,
                     now: @escaping () -> ContinuousClock.Instant = { .now }) throws -> MacTreeRead {
        var walk = MacTreeWalk(source: source, limits: limits, started: started, now: now)
        walk.visit(window, depth: 0, parent: nil, slot: 0, clip: nil)
        // The window itself, or the list of its children, not answering leaves nothing read: an error, never
        // an empty window read in full.
        if let root = walk.records.first?.node.unread, root.element || root.children {
            throw MacTreeFailure.windowUnreadable(index: index, cause: root.cause)
        }
        var cursor = 0
        while cursor < walk.pending.count, walk.stoppedBy == nil {
            let item = walk.pending[cursor]
            cursor += 1
            walk.visit(item.element, depth: item.depth, parent: item.parent, slot: item.slot, clip: item.clip)
        }
        guard let tree = walk.tree() else {
            // Nothing recorded: the root's visit stopped before reading it, for time or for the element limit.
            if walk.stoppedBy == .deadline { throw MacTreeFailure.windowUnreadable(index: index, cause: .timedOut) }
            throw MacTreeFailure.windowNotFound(index: index)
        }
        return MacTreeRead(
            window               : tree,
            stoppedBy            : walk.stoppedBy,
            nodesVisited         : walk.records.count { $0.node.unread?.element != true },
            nodesSkippedOffscreen: walk.skippedOffscreen,
            duration             : seconds(now() - started)
        )
    }

    private init(source: Source, limits: MacTreeLimits, started: ContinuousClock.Instant,
                 now: @escaping () -> ContinuousClock.Instant) {
        self.source  = source
        self.limits  = limits
        self.started = started
        self.now     = now
    }

    /// `duration` in seconds, as `MacTreeRead.duration` keeps it.
    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private mutating func visit(_ element: Source.Element, depth: Int, parent: Int?, slot: Int, clip: CGRect?) {
        if records.count >= limits.elementLimit {
            stoppedBy = .elementLimit
            return
        }
        if now() - started >= .seconds(limits.deadline) {
            stoppedBy = .deadline
            return
        }
        let timeout = parent == nil ? limits.applicationTimeout : limits.elementTimeout
        let read: MacElementRead<Source.Element>
        switch source.read(element, timeout: timeout) {
            case .success(let answered):
                read = answered
            case .failure(let failure):
                _ = record(Self.placeholder(failure), parent: parent, slot: slot)
                return
        }
        let role = read.node.role
        let frame = read.node.frame
        if limits.visibleOnly, let frame, let clip, frame.width > 0, frame.height > 0, !frame.intersects(clip) {
            skippedOffscreen += 1
            return
        }
        var childClip = clip ?? frame
        if role == "AXScrollArea", let frame { childClip = childClip?.intersection(frame) ?? frame }
        var node = read.node
        // Attributes in the request's order, so the mark reads the same on every read.
        let unreadNames = LiveMacTreeReader.nodeAttributes.filter { read.unread[$0] != nil }
            + read.unread.keys.filter { !LiveMacTreeReader.nodeAttributes.contains($0) }.sorted()
        var mark = unreadNames.first.flatMap { read.unread[$0] }.map { MacUnread(cause: $0, attributes: unreadNames) }
        if !LiveMacTreeReader.passiveRoles.contains(role) {
            switch source.actions(element) {
                case .success(let actions): node.actions = actions
                case .failure(let failure):
                    mark = mark ?? MacUnread(cause: failure)
                    mark?.actions = true
            }
        }

        let listed: (children: [MacChild<Source.Element>], unlisted: MacReadFailure?)
        if depth < limits.depthLimit {
            listed = limits.visibleOnly
                ? MacChildList.followed(visibleOnly: true, children: read.children, visibleChildren: read.visibleChildren,
                                        visibleRows: read.visibleRows, header: { source.header(element) })
                : MacChildList.followed(visibleOnly: false, children: read.children, visibleChildren: [], visibleRows: [],
                                        header: { .success(nil) })
        } else {
            switch read.children {
                case .success(let all):
                    if !all.isEmpty { stoppedBy = stoppedBy ?? .depthLimit }
                    listed = ([], nil)
                case .failure(let failure):
                    listed = ([], failure)
            }
        }
        if let unlisted = listed.unlisted {
            mark = mark ?? MacUnread(cause: unlisted)
            mark?.children = true
        }
        node.unread = mark
        let index = record(node, parent: parent, slot: slot)
        for (slot, child) in listed.children.enumerated() {
            switch child {
                case .element(let child):
                    pending.append(Pending(element: child, depth: depth + 1, parent: index, slot: slot, clip: childClip))
                case .unread(let failure):
                    _ = record(Self.placeholder(failure), parent: index, slot: slot)
            }
        }
    }

    /// An element that answered nothing: unknown role, no frame, no children, at its place.
    private static func placeholder(_ failure: MacReadFailure) -> MacTreeNode {
        MacTreeNode(role: "AXUnknown", unread: MacUnread(cause: failure, element: true))
    }

    private mutating func record(_ node: MacTreeNode, parent: Int?, slot: Int) -> Int {
        let index = records.count
        records.append(Record(node: node, parent: parent, slot: slot))
        if let parent { records[parent].children.append(index) }
        return index
    }

    /// The records assembled into a tree. Paths are positions in each parent's child list as read, skipped
    /// siblings included, so a path resolves again to the same element (15 Oct: paths that counted only
    /// recorded children selected a row two below the one asked).
    private func tree() -> MacTreeNode? {
        guard !records.isEmpty else { return nil }
        func build(_ index: Int, _ path: [Int]) -> MacTreeNode {
            var node = records[index].node
            node.path = path
            // In slot order: a placeholder is recorded when its parent lists it, before the elements queued.
            node.children = records[index].children.sorted { records[$0].slot < records[$1].slot }
                .map { build($0, path + [records[$0].slot]) }
            return node
        }
        return build(0, [])
    }
}
