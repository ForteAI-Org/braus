import CoreGraphics
import Foundation

/// MacTreeLimits bounds one read of a window, so a dense app answers in time with a partial tree
/// instead of not at all. Measured on 14 Oct with one request per attribute: Mail 104 s, Notes 28 s.
public struct MacTreeLimits: Sendable, Equatable {

    /// Elements read before the walk stops (`elementLimit`).
    public var elementLimit: Int
    /// Depth from the window before a branch is not followed (`depthLimit`).
    public var depthLimit: Int
    /// Time for the whole read, in seconds (`deadline`), on the monotonic clock and counted from before the
    /// application and its windows are looked up: a change of the civil clock neither shortens nor extends it. It is
    /// checked before each element's visit, which may then make up to three requests, each bounded by the element's
    /// messaging timeout: the read can run past it by that visit's requests.
    public var deadline: TimeInterval
    /// Accessibility messaging timeout for the application element, in seconds.
    public var applicationTimeout: Float
    /// Accessibility messaging timeout for every other element, in seconds.
    public var elementTimeout: Float
    /// Whether only what the window shows is read (visible rows and children, clipped to scroll
    /// areas). False reads every child, for a lookup by name and for `setSelected`, whose paths are
    /// paths of such a read.
    public var visibleOnly: Bool

    public init(
        elementLimit      : Int          = 600,
        depthLimit        : Int          = 40,
        deadline          : TimeInterval = 3,
        applicationTimeout: Float        = 1,
        elementTimeout    : Float        = 0.25,
        visibleOnly       : Bool         = true
    ) {
        self.elementLimit       = elementLimit
        self.depthLimit         = depthLimit
        self.deadline           = deadline
        self.applicationTimeout = applicationTimeout
        self.elementTimeout     = elementTimeout
        self.visibleOnly        = visibleOnly
    }

    public static let standard = MacTreeLimits()
}

/// MacTreeRead is one window read: the tree, why the walk stopped if it did, and what it cost.
public struct MacTreeRead: Sendable, Equatable {

    public enum Stop: String, Sendable, Equatable, Codable {
        case elementLimit = "element_limit"
        case depthLimit   = "depth_limit"
        case deadline
    }

    public var window: MacTreeNode
    /// Nil when the walk visited every element it was allowed to see.
    public var stoppedBy: Stop?
    /// Elements read, the window included.
    public var nodesVisited: Int
    /// Children not followed because their frame lay outside the window (off-screen rows, hidden
    /// panes): the visible-rows rule.
    public var nodesSkippedOffscreen: Int
    public var duration: TimeInterval
    /// The window this tree was read from, as the element the walk started at; nil for a reader that cannot say,
    /// whose addresses then act as before, by index alone.
    public var windowIdentity: MacWindowIdentity?

    public init(
        window               : MacTreeNode,
        stoppedBy            : Stop? = nil,
        nodesVisited         : Int,
        nodesSkippedOffscreen: Int = 0,
        duration             : TimeInterval = 0,
        windowIdentity       : MacWindowIdentity? = nil
    ) {
        self.window                = window
        self.stoppedBy             = stoppedBy
        self.nodesVisited          = nodesVisited
        self.nodesSkippedOffscreen = nodesSkippedOffscreen
        self.duration              = duration
        self.windowIdentity        = windowIdentity
    }

    /// What of the window did not answer, counted from the tree's own marks.
    public var unread: Unread { Unread(of: window) }

    /// Unread counts the nodes of a read that did not answer, each count apart: a node whose children and
    /// attributes both failed is one node, one branch and one with attributes. `nodes` is the distinct
    /// nodes marked, never a sum of the others. How many elements lay below a branch nobody listed is not
    /// known, and no count claims it.
    public struct Unread: Sendable, Equatable {
        /// Distinct nodes with any mark.
        public var nodes: Int
        /// Elements that answered nothing, kept as placeholders at their place.
        public var elements: Int
        /// Nodes whose children could not be listed.
        public var branches: Int
        /// Nodes with an attribute or their action names unread.
        public var attributes: Int
        /// The first failure in the tree's order, depth first.
        public var cause: MacReadFailure?

        public var isEmpty: Bool { nodes == 0 }

        public init(nodes: Int = 0, elements: Int = 0, branches: Int = 0, attributes: Int = 0, cause: MacReadFailure? = nil) {
            self.nodes      = nodes
            self.elements   = elements
            self.branches   = branches
            self.attributes = attributes
            self.cause      = cause
        }

        public init(of tree: MacTreeNode) {
            let marks = tree.flattened.compactMap(\.unread)
            self.init(
                nodes     : marks.count,
                elements  : marks.filter(\.element).count,
                branches  : marks.filter(\.children).count,
                attributes: marks.filter { $0.actions || !$0.attributes.isEmpty }.count,
                cause     : marks.first?.cause
            )
        }
    }
}

/// MacWindowSummary is a window as the application lists it, without its tree.
public struct MacWindowSummary: Sendable, Equatable {

    /// Position in the app's `AXWindows`, front to back.
    public var index: Int
    public var role: String
    public var subrole: String?
    public var title: String?
    public var frame: CGRect?
    public var isMain: Bool
    public var isFocused: Bool
    public var isMinimized: Bool
    /// The file or folder the window shows (`AXDocument`), as a file URL string.
    public var document: String?

    public init(
        index      : Int,
        role       : String,
        subrole    : String? = nil,
        title      : String? = nil,
        frame      : CGRect? = nil,
        isMain     : Bool = false,
        isFocused  : Bool = false,
        isMinimized: Bool = false,
        document   : String? = nil
    ) {
        self.index       = index
        self.role        = role
        self.subrole     = subrole
        self.title       = title
        self.frame       = frame
        self.isMain      = isMain
        self.isFocused   = isFocused
        self.isMinimized = isMinimized
        self.document    = document
    }

    /// Whether the window shows this file or folder, compared with symbolic links resolved (`/tmp`).
    public func shows(_ url: URL) -> Bool {
        guard let document, let shown = URL(string: document), shown.isFileURL else { return false }
        return shown.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
    }
}
