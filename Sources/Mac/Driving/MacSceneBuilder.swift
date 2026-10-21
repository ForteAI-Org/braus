import CoreGraphics
import EngineCore
import Foundation
import MacDriver
import PerceptionCore

/// MacScene is one window as the MacDriver perceived it: the engine's scene, the coverage that says
/// whether the MacDriver should drive it, and what the read cost.
public struct MacScene: Sendable, Equatable {

    public var perceived: PerceivedWindow
    public var coverage: MacCoverage
    public var nodesVisited: Int
    public var nodesSkippedOffscreen: Int
    public var readDuration: TimeInterval
    /// What of the window did not answer, and the first cause: for the diagnostics of this read only. The
    /// capture's quality says partial; it keeps no count.
    public var unread: MacTreeRead.Unread

    public init(
        perceived            : PerceivedWindow,
        coverage             : MacCoverage,
        nodesVisited         : Int,
        nodesSkippedOffscreen: Int,
        readDuration         : TimeInterval,
        unread               : MacTreeRead.Unread = MacTreeRead.Unread()
    ) {
        self.perceived             = perceived
        self.coverage              = coverage
        self.nodesVisited          = nodesVisited
        self.nodesSkippedOffscreen = nodesSkippedOffscreen
        self.readDuration          = readDuration
        self.unread                = unread
    }
}

/// MacSceneBuilder turns a window's accessibility tree into the engine's scene. Pure: the same tree
/// gives the same scene, so it is tested on recorded trees.
///
/// - Roles pass through; the meaningful subroles (`AXSwitch`, `AXToggle`, `AXSearchField`,
///   `AXSecureTextField`) replace the role they refine.
/// - Names come from the title, the description, the help, the placeholder, and for a field with
///   none of them, the static text just before it in its container (Mail's "A:", "Oggetto:").
/// - A row is one element named by its texts; the texts are not repeated as elements of their own.
/// - State comes from a check box's or radio button's value, a row's selection, a disclosure's
///   expansion; availability from `AXEnabled`. A secure field never has a value.
/// - A static text is its own label and its own value: the value is what the scene token hashes, so
///   a display that now reads another text (Calculator's "42") is a changed scene.
/// - Sections: window controls, toolbar, sidebar (the narrow first pane of a split group), content,
///   sheet, popover, dialog.
/// - Ids are `m` and the element's path from the window (`m0.3.1`): the address the live driver
///   resolves again before it acts.
public enum MacSceneBuilder {

    public static func scene(
        from read       : MacTreeRead,
        bundleID        : String,
        appName         : String,
        isGrantAvailable: Bool = true
    ) -> MacScene {
        let window = read.window
        let frame = window.frame ?? .zero
        var context = Context(windowFrame: frame, isDialog: Self.dialogSubroles.contains(window.subrole ?? ""))
        for child in window.children { context.walk(child, section: nil, container: nil, siblings: window.children) }

        let snapshot = SceneSnapshot(
            bundleID         : bundleID,
            appName          : appName,
            windowTitle      : window.title ?? "",
            viewportPixelSize: ViewportPixelSize(width: Int(frame.width.rounded()), height: Int(frame.height.rounded())),
            elements         : context.elements,
            sections         : context.sections(),
            token            : nil
        )
        // A part that did not answer leaves the walk unfinished with no limit to name: partial, its cause kept
        // on the scene for this read only (`MacScene.unread`).
        let unread = read.unread
        let quality = CaptureQuality(
            walkCompleted   : read.stoppedBy == nil && unread.isEmpty,
            stoppedBy       : read.stoppedBy.map(Self.stop),
            windowFound     : true,
            isGrantAvailable: isGrantAvailable,
            windowRole      : window.role,
            windowSubrole   : window.subrole,
            nodesVisited    : read.nodesVisited,
            elementsEmitted : context.elements.count
        )
        return MacScene(
            perceived            : PerceivedWindow(
                scene  : snapshot,
                frame  : frame,
                capture: quality,
                surface: CaptureSurface.classified(role: window.role, subrole: window.subrole)
            ),
            coverage             : MacCoverage(window: window),
            nodesVisited         : read.nodesVisited,
            nodesSkippedOffscreen: read.nodesSkippedOffscreen,
            readDuration         : read.duration,
            unread               : unread
        )
    }

    static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]

    static let keptSubroles: Set<String> = ["AXSwitch", "AXToggle", "AXSearchField", "AXSecureTextField"]

    static let windowControlSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]

    /// The title bar's buttons carry no name; their subrole says what they do.
    static let windowControlNames: [String: String] = [
        "AXCloseButton": "close", "AXMinimizeButton": "minimize", "AXZoomButton": "zoom",
        "AXFullScreenButton": "full screen",
    ]

    /// Roles that become an element only when they are named and act.
    static let containerRoles: Set<String> = [
        "AXGroup", "AXUnknown", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXToolbar", "AXTabGroup",
        "AXSheet", "AXPopover", "AXColumn", "AXCell", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid",
        "AXWebArea", "AXRadioGroup", "AXSplitter",
    ]

    static let collectionRoles: Set<String> = ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid"]

    /// Roles whose value is what the person typed or chose, so it is the element's value.
    static let valueRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXSlider", "AXIncrementor",
        "AXValueIndicator", "AXDateField", "AXLevelIndicator", "AXProgressIndicator", "AXColorWell",
    ]

    /// Roles a preceding static text names when they have no name of their own.
    static let fieldRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXDateField", "AXCheckBox", "AXSlider",
    ]

    static let stateRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]

    private static func stop(_ stop: MacTreeRead.Stop) -> CaptureQuality.StopReason {
        switch stop {
            case .elementLimit: .elementLimit
            case .depthLimit  : .depthLimit
            case .deadline    : .deadline
        }
    }

    // MARK: The walk

    private struct Context {

        let windowFrame: CGRect
        let isDialog: Bool
        var elements: [SceneElement] = []
        var sectionFrames: [(name: String, frame: CGRect)] = []

        init(windowFrame: CGRect, isDialog: Bool) {
            self.windowFrame = windowFrame
            self.isDialog    = isDialog
        }

        mutating func walk(_ node: MacTreeNode, section inherited: String?, container: String?, siblings: [MacTreeNode]) {
            let section = sectionName(of: node, inherited: inherited, siblings: siblings)
            if let section, section != inherited, let frame = node.frame {
                sectionFrames.append((section, frame))
            }
            var container = container
            if MacSceneBuilder.collectionRoles.contains(node.role) {
                container = name(of: node)?.text ?? node.identifier ?? String(node.role.dropFirst(2))
            }

            if node.role == "AXRow" {
                emitRow(node, section: section, container: container)
                for child in node.children { walkInsideRow(child, section: section, container: container) }
                return
            }
            // A scroll bar's parts and a slider's thumb repeat what their owner already says.
            if node.role == "AXScrollBar" || node.role == "AXValueIndicator" { return }
            emit(node, section: section, container: container, siblings: siblings)
            for child in node.children { walk(child, section: section, container: container, siblings: node.children) }
        }

        /// Inside a row, only controls become elements; the texts already named the row.
        mutating func walkInsideRow(_ node: MacTreeNode, section: String?, container: String?) {
            if node.role != "AXStaticText", node.role != "AXImage" || hasRealAction(node) {
                emit(node, section: section, container: container, siblings: [])
            }
            for child in node.children { walkInsideRow(child, section: section, container: container) }
        }

        mutating func emitRow(_ row: MacTreeNode, section: String?, container: String?) {
            guard let bounds = bounds(of: row) else { return }
            let texts = row.flattened.filter { $0.role == "AXStaticText" || $0.role == "AXTextField" }
                .compactMap { $0.value ?? $0.title }
                .filter { !$0.isEmpty }
            let label = texts.prefix(3).joined(separator: " · ")
            elements.append(SceneElement(
                id         : identifier(row),
                kind       : .control,
                label      : label,
                bounds     : bounds,
                role       : row.role,
                state      : row.isSelected.map { $0 ? .on : .off },
                isEnabled  : row.isEnabled,
                container  : container,
                isUnlabeled: label.isEmpty,
                section    : section,
                labelOrigin: label.isEmpty ? nil : .rowContent
            ))
        }

        mutating func emit(_ node: MacTreeNode, section: String?, container: String?, siblings: [MacTreeNode]) {
            guard let bounds = bounds(of: node) else { return }
            let role = node.subrole.flatMap { MacSceneBuilder.keptSubroles.contains($0) ? $0 : nil } ?? node.role

            if node.role == "AXStaticText" {
                guard let text = node.value ?? node.title, !text.isEmpty else { return }
                elements.append(SceneElement(
                    id: identifier(node), kind: .text, label: text, bounds: bounds, role: role, value: text,
                    container: container, section: section, labelOrigin: .value
                ))
                return
            }
            let named = name(of: node) ?? precedingText(of: node, in: siblings).map { ($0, LabelOrigin.title) }
            if MacSceneBuilder.containerRoles.contains(node.role), named == nil || !hasRealAction(node) { return }

            let kind: ElementKind
            if node.role == "AXImage" {
                kind = hasRealAction(node) ? .icon : .image
            } else {
                kind = .control
            }
            let value = MacSceneBuilder.valueRoles.contains(node.role) && !node.isSecure ? node.value : nil
            elements.append(SceneElement(
                id         : identifier(node),
                kind       : kind,
                label      : named?.text ?? "",
                bounds     : bounds,
                role       : role,
                state      : state(of: node),
                value      : value,
                isEnabled  : node.isEnabled,
                container  : container,
                isUnlabeled: named == nil,
                section    : section,
                labelOrigin: named?.origin
            ))
        }

        // MARK: Names, state, geometry

        func name(of node: MacTreeNode) -> (text: String, origin: LabelOrigin)? {
            if let subrole = node.subrole, let control = MacSceneBuilder.windowControlNames[subrole] {
                return (control, .identifier)
            }
            if let title = node.title, !title.isEmpty { return (title, .title) }
            if let text = node.descriptionText, !text.isEmpty { return (text, .description) }
            if let help = node.help, !help.isEmpty { return (help, .description) }
            if let placeholder = node.placeholder, !placeholder.isEmpty { return (placeholder, .description) }
            if node.role == "AXButton" || node.role == "AXMenuButton", let value = node.value, !value.isEmpty {
                return (value, .value)
            }
            return nil
        }

        /// The static text right before a field among its siblings, with only groups between them.
        func precedingText(of node: MacTreeNode, in siblings: [MacTreeNode]) -> String? {
            guard MacSceneBuilder.fieldRoles.contains(node.role),
                  let index = siblings.firstIndex(where: { $0.path == node.path })
            else { return nil }
            for sibling in siblings[..<index].reversed() {
                if sibling.role == "AXStaticText" { return sibling.value ?? sibling.title }
                if sibling.role != "AXGroup" { return nil }
            }
            return nil
        }

        func state(of node: MacTreeNode) -> ControlState? {
            if MacSceneBuilder.stateRoles.contains(node.role) || node.subrole == "AXSwitch" || node.subrole == "AXToggle" {
                switch node.value {
                    case "1"     : return .on
                    case "0"     : return .off
                    case "2"     : return .mixed
                    default      : break
                }
                if let expanded = node.isExpanded { return expanded ? .on : .off }
                return .unknown
            }
            if node.role == "AXTab" || node.role == "AXMenuItem", let selected = node.isSelected {
                return selected ? .on : .off
            }
            return nil
        }

        func hasRealAction(_ node: MacTreeNode) -> Bool {
            node.actions.contains { !MacCoverage.incidentalActions.contains($0) }
        }

        func bounds(of node: MacTreeNode) -> NormalizedRect? {
            guard let frame = node.frame, frame.width > 0, frame.height > 0,
                  windowFrame.width > 0, windowFrame.height > 0
            else { return nil }
            let box = frame.intersection(windowFrame)
            guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
            return NormalizedRect(
                x     : (box.minX - windowFrame.minX) / windowFrame.width,
                y     : (box.minY - windowFrame.minY) / windowFrame.height,
                width : box.width / windowFrame.width,
                height: box.height / windowFrame.height
            )
        }

        func identifier(_ node: MacTreeNode) -> String {
            "m" + node.path.map(String.init).joined(separator: ".")
        }

        // MARK: Sections

        func sectionName(of node: MacTreeNode, inherited: String?, siblings: [MacTreeNode]) -> String? {
            switch node.role {
                case "AXSheet"  : return "sheet"
                case "AXPopover": return "popover"
                case "AXToolbar": return "toolbar"
                default         : break
            }
            if MacSceneBuilder.windowControlSubroles.contains(node.subrole ?? "") { return "window controls" }
            if let inherited, inherited != "content" { return inherited }
            if let pane = splitPaneName(of: node, siblings: siblings) { return pane }
            return inherited ?? (isDialog ? "dialog" : "content")
        }

        /// In a split group, the panes before the first splitter are the sidebar when each is narrower
        /// than 40% of the window (Settings puts its list and its search field there); the panes after
        /// it are content.
        func splitPaneName(of node: MacTreeNode, siblings: [MacTreeNode]) -> String? {
            guard let splitter = siblings.firstIndex(where: { $0.role == "AXSplitter" }), splitter > 0,
                  windowFrame.width > 0
            else { return nil }
            let leading = siblings[..<splitter]
            guard leading.allSatisfy({ ($0.frame?.width ?? 0) < windowFrame.width * 0.4 }) else { return nil }
            return leading.contains { $0.path == node.path } ? "sidebar" : "content"
        }

        func sections() -> [SceneSection] {
            var order: [String] = []
            var frames: [String: CGRect] = [:]
            for (name, frame) in sectionFrames {
                if frames[name] == nil { order.append(name) }
                frames[name] = frames[name].map { $0.union(frame) } ?? frame
            }
            return order.compactMap { name in
                guard let frame = frames[name], let bounds = bounds(of: MacTreeNode(role: "AXGroup", frame: frame)) else {
                    return nil
                }
                return SceneSection(name: name, bounds: bounds)
            }
        }
    }
}
