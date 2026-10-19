import ApplicationServices
import EngineCore
import PerceptionCore
import Testing
@testable import AccessibilityActions

@MainActor
@Suite("Native dropdown opening action")
struct DropdownOpeningTests {

    @Test("the primary dropdown action wins over its contextual menu action", arguments: [false, true])
    func primaryAction(reverse: Bool) {
        let actions = reverse ? [kAXShowMenuAction, kAXPressAction] : [kAXPressAction, kAXShowMenuAction]
        #expect(DropdownOpening.openingAction(in: actions) == kAXPressAction)
    }

    @Test("a dropdown exposing only its primary action can open")
    func primaryOnly() {
        #expect(DropdownOpening.openingAction(in: [kAXPressAction]) == kAXPressAction)
    }

    @Test("Show Menu remains available when it is the dropdown's only opening action")
    func showMenuOnly() {
        #expect(DropdownOpening.openingAction(in: [kAXShowMenuAction]) == kAXShowMenuAction)
        #expect(DropdownOpening.openingAction(in: []) == nil)
        #expect(DropdownOpening.openingAction(in: [kAXCancelAction]) == nil)
    }

    @Test("a contextual menu opens by Show Menu alone, never by the popup's primary Press")
    func contextMenuAction() {
        #expect(DropdownOpening.contextMenuAction(in: [kAXPressAction, kAXShowMenuAction]) == kAXShowMenuAction)
        #expect(DropdownOpening.contextMenuAction(in: [kAXShowMenuAction]) == kAXShowMenuAction)
        #expect(DropdownOpening.contextMenuAction(in: [kAXPressAction]) == nil)
        #expect(DropdownOpening.contextMenuAction(in: []) == nil)
    }

    private let popup = CGRect(x: 200, y: 300, width: 160, height: 90)

    @Test("CEF's native popup item at depth twelve remains reachable")
    func nestedNativeItem() {
        let native = row("Beta")
        var nested = MenuNode("AXMenu", children: [native])
        for _ in 0..<10 { nested = MenuNode("AXGroup", children: [nested]) }
        let root = MenuNode("AXApplication", children: [nested])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) === native)
    }

    @Test("native item traversal remains bounded on excessively deep trees")
    func deeplyNestedItemRefuses() {
        var nested = MenuNode("AXMenu", children: [row("Beta")])
        for _ in 0..<15 { nested = MenuNode("AXGroup", children: [nested]) }
        let root = MenuNode("AXApplication", children: [nested])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) == nil)
    }

    @Test("a web option mirror does not make the real native menu item ambiguous")
    func webMirrorAndNativeMenu() {
        let mirror = row("Beta")
        let native = row("Beta")
        let root = MenuNode("AXApplication", children: [
            MenuNode("AXWebArea", children: [MenuNode("AXPopUpButton", children: [
                MenuNode("AXMenu", children: [mirror])
            ])]),
            MenuNode("AXMenu", children: [native])
        ])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) === native)
    }

    @Test("a web option without a real native menu is not a native action recipient")
    func webOnlyRefuses() {
        let root = MenuNode("AXApplication", children: [
            MenuNode("AXWebArea", children: [MenuNode("AXMenu", children: [row("Beta")])])
        ])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) == nil)
    }

    @Test("one native item exposed through two tree paths remains one recipient")
    func sameItemThroughTwoPaths() {
        let leaf = row("TUNE (Mono)")
        let child = MenuNode("AXWindow", children: [leaf])
        let parent = MenuNode("AXMenuItem", title: "bus", children: [child])
        let root = MenuNode("AXApplication", children: [child, MenuNode("AXWindow", children: [parent])])
        #expect(DropdownOpening.nativeMenuItem(named: "TUNE (Mono)", in: popup, under: root,
                                             reader: MenuReader()) === leaf)
    }

    @Test("two real native items remain ambiguous, including a disabled duplicate")
    func nativeDuplicatesRefuse() {
        for enabled in [false, true] {
            let root = MenuNode("AXApplication", children: [
                MenuNode("AXMenu", children: [row("Beta"), row("Beta", enabled: enabled)])
            ])
            #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                                 reader: MenuReader()) == nil)
        }
    }

    @Test("unpainted or disabled items are not native action recipients")
    func unusableItemsRefuse() {
        let items = [
            row("Beta", enabled: false),
            MenuNode("AXMenuItem", title: "Beta"),
            MenuNode("AXMenuItem", title: "Beta", frame: CGRect(x: 204, y: 900, width: 150, height: 20)),
            MenuNode("AXMenuItem", title: "Beta", frame: CGRect(x: 204, y: 310, width: 0, height: 20))
        ]
        for item in items {
            let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [item])])
            #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                                 reader: MenuReader()) == nil)
        }
    }

    @Test("one painted enabled native item is resolved with the existing case matching")
    func oneNativeItem() {
        let native = row("Beta")
        let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [native])])
        #expect(DropdownOpening.nativeMenuItem(named: "beta", in: popup, under: root,
                                             reader: MenuReader()) === native)
        #expect(DropdownOpening.nativeMenuItem(named: "Gamma", in: popup, under: root,
                                             reader: MenuReader()) == nil)
    }

    @Test("a menu item matches its title read with straight quotes, an ellipsis as dots, or bidi isolates",
          arguments: [("Compress \u{201C}carla_video_bn\u{201D}", "Compress \"carla_video_bn\""),
                      ("Save As\u{2026}", "Save As..."), ("Save As\u{2026}", "save as"),
                      ("\u{2068}Desktop\u{2069} \u{2014} iCloud", "Desktop \u{2014} iCloud")])
    func menuTitlesCompareAsRead(title: String, typed: String) {
        let native = row(title)
        let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [native, row("Open")])])
        #expect(DropdownOpening.nativeMenuItem(named: typed, in: popup, under: root, reader: MenuReader()) === native)
    }

    @Test("a menu item named by the start of its title is the unique one that begins with it")
    func menuItemNamedByItsStart() {
        let compress = row("Compress \u{201C}carla_video_bianco_nero.mov\u{201D}")
        let open     = row("Open")
        let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [
            open, row("Open With"), compress
        ])])
        #expect(DropdownOpening.nativeMenuItem(named: "Compress", in: popup, under: root, reader: MenuReader()) === compress)
        #expect(DropdownOpening.nativeMenuItem(named: "Open", in: popup, under: root, reader: MenuReader()) === open)
        let twoLonger = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [
            row("Open With"), row("Open in New Tab")
        ])])
        #expect(DropdownOpening.nativeMenuItem(named: "Open", in: popup, under: twoLonger, reader: MenuReader()) == nil)
    }

    /// Finder's contextual menu as measured from another process: the application's children are
    /// its window, its menu bar and the desktop's scroll area, none holding the menu, which is
    /// reached only by the hit test at the menu window's centre (`WindowReader.contextMenu`).
    @Test("a contextual menu no child of the application holds is read where its window is drawn")
    func finderContextualMenuIsReadWhereItIsDrawn() {
        let compress = row("Compress \u{201C}carla_video_bw\u{201D}")
        let menu = MenuNode("AXMenu", children: [row("Open"), row("Open With"), compress, row("Quick Look")])
        let closed = MenuNode("AXMenuBarItem", children: [
            MenuNode("AXMenu", children: [MenuNode("AXMenuItem", title: "Compress", frame: .zero)])
        ])
        let root = MenuNode("AXApplication", children: [
            MenuNode("AXWindow", children: [MenuNode("AXOutline", children: [MenuNode("AXRow")])]),
            MenuNode("AXMenuBar", children: [closed]),
            MenuNode("AXScrollArea"),
        ])
        #expect(DropdownOpening.nativeMenuItem(named: "Compress \"carla_video_bw\"", in: popup, under: root,
                                             reader: MenuReader()) == nil, "the application's tree misses it")
        #expect(DropdownOpening.nativeMenuItem(named: "Compress \"carla_video_bw\"", in: popup, under: root,
                                             drawnMenu: { menu }, reader: MenuReader()) === compress)

        // A menu the application's tree holds is read there, and the hit test is never asked.
        let native = row("Beta")
        let held = MenuNode("AXApplication", children: [MenuNode("AXWindow", children: [
            MenuNode("AXMenu", children: [native])
        ])])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: held, drawnMenu: {
            Issue.record("the drawn menu is read only when the tree paints no item")
            return nil
        }, reader: MenuReader()) === native)
    }

    @Test("an unreadable label in a readable native menu is distinct from no native menu")
    func unknownNativeItem() {
        let root = MenuNode("AXApplication", children: [MenuNode("AXWindow", children: [row("bus")])])
        #expect(DropdownOpening.navigation(named: "snq", in: popup, under: root, reader: MenuReader()) != nil)
        #expect(DropdownOpening.navigation(named: "bus", in: popup, under: MenuNode("AXApplication"),
                                          reader: MenuReader()) == nil)
    }

    @Test("submenu parents include menu-bearing windows but not ordinary child windows")
    func submenuOwnership() {
        let reader = MenuReader()
        let native = MenuNode("AXMenuItem", children: [MenuNode("AXMenu")])
        let window = MenuNode("AXMenuItem", children: [MenuNode("AXWindow", children: [row("Destination")])])
        let ordinary = MenuNode("AXMenuItem", children: [MenuNode("AXWindow", children: [MenuNode("AXButton")])])
        #expect(DropdownOpening.submenu(native, reader: reader) != nil)
        #expect(DropdownOpening.submenu(window, reader: reader) != nil)
        #expect(DropdownOpening.submenu(ordinary, reader: reader) == nil)
        #expect(DropdownOpening.submenu(row("no send"), reader: reader) == nil)
    }

    @Test("submenu keyboard rows skip separators and disabled items without using hidden descendants")
    func submenuRow() {
        func item(_ title: String, _ y: CGFloat, enabled: Bool = true, children: [MenuNode] = []) -> MenuNode {
            MenuNode("AXMenuItem", title: title, frame: CGRect(x: 200, y: y, width: 160, height: 10),
                     enabled: enabled, children: children)
        }
        let hidden = MenuNode("AXWindow", frame: .zero, children: [item("Destination", 0)])
        let root = MenuNode("AXApplication", children: [MenuNode("AXWindow", children: [
            item("no send", 300), item("", 310), item("Disabled", 320, enabled: false),
            item("output", 330), item("bus", 340, children: [hidden])
        ])])
        let navigation = DropdownOpening.navigation(named: "bus", in: popup, under: root, reader: MenuReader())
        #expect(navigation?.hasSubmenu == true)
        #expect(navigation?.row == 2)
        #expect(DropdownOpening.navigation(named: "no send", in: popup, under: root,
                                           reader: MenuReader())?.hasSubmenu == false)
        let overlapping = MenuNode("AXApplication", children: [MenuNode("AXWindow", children: [
            item("output", 340), item("bus", 340, children: [hidden])
        ])])
        let uncertain = DropdownOpening.navigation(named: "bus", in: popup, under: overlapping, reader: MenuReader())
        #expect(uncertain?.hasSubmenu == true)
        #expect(uncertain?.row == nil)
    }

    @Test("audio routing context requires native no-send, output and bus rows")
    func audioSendMenuContext() {
        func branch(_ title: String) -> MenuNode {
            MenuNode("AXMenuItem", title: title, frame: CGRect(x: 204, y: 340, width: 150, height: 20),
                     children: [MenuNode("AXWindow", children: [row("Destination")])])
        }
        let clear = row("no send")
        let output = branch("output"), bus = branch("bus")
        for (items, expected) in [
            ([clear, output, bus], true),
            ([clear, bus], false),
            ([clear, output, row("bus")], false),
            ([clear, output, bus, branch("bus")], false),
            ([row("no send", enabled: false), output, bus], false),
            ([clear, row("no send"), output, bus], false)
        ] {
            let root = MenuNode("AXApplication", children: [MenuNode("AXWindow", children: items)])
            let navigation = DropdownOpening.navigation(named: "no send", in: popup, under: root, reader: MenuReader())
            #expect(navigation?.isAudioSendMenu == expected)
        }
    }

    private func row(_ title: String, enabled: Bool = true) -> MenuNode {
        MenuNode("AXMenuItem", title: title,
                 frame: CGRect(x: 204, y: 310, width: 150, height: 20), enabled: enabled)
    }
}

private final class MenuNode {
    let role: String
    let title: String?
    let frame: CGRect?
    let enabled: Bool
    let children: [MenuNode]

    init(_ role: String, title: String? = nil, frame: CGRect? = nil,
         enabled: Bool = true, children: [MenuNode] = []) {
        self.role = role
        self.title = title
        self.frame = frame
        self.enabled = enabled
        self.children = children
    }
}

private struct MenuReader: AccessibilityTreeReading {
    func isSameNode(_ first: MenuNode, _ second: MenuNode) -> Bool { first === second }
    func role(_ node: MenuNode) -> String? { node.role }
    func subrole(_ node: MenuNode) -> String? { nil }
    func title(_ node: MenuNode) -> String? { node.title }
    func descriptionText(_ node: MenuNode) -> String? { nil }
    func identifier(_ node: MenuNode) -> String? { nil }
    func value(_ node: MenuNode) -> String? { nil }
    func numericValue(_ node: MenuNode) -> Int? { nil }
    func isEnabled(_ node: MenuNode) -> Bool? { node.enabled }
    func actions(_ node: MenuNode) -> [String] { [kAXPressAction] }
    func frame(_ node: MenuNode) -> CGRect? { node.frame }
    func children(_ node: MenuNode) -> [MenuNode] { node.children }
}
