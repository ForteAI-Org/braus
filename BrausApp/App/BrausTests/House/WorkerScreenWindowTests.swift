import AppKit
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

@Suite("WorkerScreenWindow", .serialized)
@MainActor
struct WorkerScreenWindowTests {

    private var busyWorker: HouseWorker {
        get throws {
            try #require(HouseFixture.workers.first { $0.status == .busy })
        }
    }

    @Test("The window has no chrome of its own: borderless and clear, so the held window's own shape shows")
    func chrome() throws {
        let worker     = try busyWorker
        let directory  = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let controller = WorkerScreenWindowController(
            worker: worker,
            team  : TeamModel(
                store      : try WorkspaceStore.opening(in: directory),
                connections: ModelSettingsStore(),
                broker     : SeatBroker()
            )
        )
        let window     = try #require(controller.window)
        #expect(window.title == worker.name, "named in the Window menu and to VoiceOver")
        #expect(window.styleMask == [.borderless, .nonactivatingPanel], "its clicks never activate Braus")
        #expect(!window.hidesOnDeactivate)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(!window.hasShadow, "the content casts it, which the window server would cast from the neon too")
        #expect(window.canBecomeKey, "the bar's buttons take the keyboard")
        #expect(window.level == .normal)
        #expect(window.appearance?.name == .darkAqua)
        #expect(window.contentView is ScreenWindowFrame, "the neon is drawn by the window itself")
        #expect(controller.pictureView is NSHostingView<ScreenWindowContent>)

        window.contentView?.layoutSubtreeIfNeeded()
        let margin  = ScreenWindowFrame.margin
        let content = controller.pictureView.frame
        #expect(content.size == WorkerScreenWindowController.contentSize)
        #expect(content.origin == CGPoint(x: margin, y: margin), "the picture inset by the neon's margin")
        #expect(controller.pictureFrame == window.frame.insetBy(dx: margin, dy: margin))
        #expect(window.contentAspectRatio == .zero, "the window never takes the held window's shape")
    }

    @Test("The window follows the held window's size from its top-left corner, scaled down to fit the screen")
    func windowFitsHeldWindow() throws {
        let directory  = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let controller = WorkerScreenWindowController(
            worker: try busyWorker,
            team  : TeamModel(
                store      : try WorkspaceStore.opening(in: directory),
                connections: ModelSettingsStore(),
                broker     : SeatBroker()
            )
        )
        let window     = try #require(controller.window)
        let topLeft    = CGPoint(
            x: window.frame.minX,
            y: window.frame.maxY
        )
        controller.fit(to: CGSize(
            width : 640,
            height: 420
        ))
        var picture    = try #require(controller.pictureFrame)
        #expect(picture.size == CGSize(
            width : 640,
            height: 420
        ))
        #expect(window.frame.minX == topLeft.x && window.frame.maxY == topLeft.y)

        let visible = try #require(window.screen ?? NSScreen.main).visibleFrame.size
        controller.fit(to: CGSize(
            width : visible.width * 3,
            height: visible.height * 2
        ))
        picture = try #require(controller.pictureFrame)
        #expect(picture.width <= visible.width && picture.height <= visible.height)
        #expect(abs(picture.width / picture.height - 1.5 * visible.width / visible.height) < 0.01)
    }

    @Test("The held window keeps its real size while it fits, and is scaled down, never up, when it does not")
    func pictureAtRealSize() {
        let bounds = CGRect(
            origin: .zero,
            size  : WorkerScreenWindowController.contentSize
        )
        let small = ScreenStageView.pictureFrame(
            of: CGSize(
                width : 400,
                height: 300
            ),
            in: bounds
        )
        #expect(small == CGRect(x: 160, y: 90, width: 400, height: 300), "centred at its own size")

        let tall = ScreenStageView.pictureFrame(
            of: CGSize(
                width : 230,
                height: 408
            ),
            in: bounds
        )
        #expect(tall == CGRect(x: 245, y: 36, width: 230, height: 408), "centred at its own size")

        let large = ScreenStageView.pictureFrame(
            of: CGSize(
                width : 2560,
                height: 1440
            ),
            in: bounds
        )
        #expect(large == CGRect(x: 0, y: 38, width: 720, height: 405), "scaled down to fill the window's width")
        #expect(abs(large.width / large.height - 2560.0 / 1440) < 0.01)
    }

    @Test("The window follows the application's largest window, not a palette the seat watches, and never shrinks below its least size")
    func followsTheMainWindow() {
        func row(
            _ number: Int,
            _ frame : CGRect,
            owner   : pid_t = 7,
            layer   : Int = 0
        ) -> [String: Any] {
            [
                kCGWindowNumber as String   : number,
                kCGWindowOwnerPID as String : owner,
                kCGWindowLayer as String    : layer,
                kCGWindowBounds as String   : frame.dictionaryRepresentation,
            ]
        }
        let rows  = [
            row(1, CGRect(x: 0, y: 0, width: 1261, height: 827)),
            row(2, CGRect(x: 0, y: 0, width: 89, height: 533)),
            row(3, CGRect(x: 0, y: 0, width: 2000, height: 1200), owner: 9),
            row(4, CGRect(x: 0, y: 0, width: 1800, height: 1000), layer: 3),
        ]
        let strip = WorkerScreenWindowController.followed(
            size    : CGSize(width: 89, height: 533),
            observed: 2,
            rows    : rows
        )
        #expect(strip.size == CGSize(width: 1261, height: 827), "the document window, not the strip")

        let main  = WorkerScreenWindowController.followed(
            size    : CGSize(width: 1261, height: 827),
            observed: 1,
            rows    : rows
        )
        #expect(main.size == CGSize(width: 1261, height: 827))

        let alone = WorkerScreenWindowController.followed(
            size    : CGSize(width: 89, height: 533),
            observed: nil,
            rows    : rows
        )
        #expect(alone.size == CGSize(width: WorkerScreenWindowController.minimumSize.width, height: 533))
    }

    @Test("The stage reports a size as it changes, not again each time an update sets its listener")
    func stageReportsSizeOnce() async throws {
        let stage = ScreenStageView(
            picture : NSView(),
            backdrop: nil
        )
        stage.pictureSize = CGSize(
            width : 400,
            height: 300
        )
        var heard: [CGSize] = []
        stage.onPictureSize = { heard.append($0) }
        stage.onPictureSize = { heard.append($0) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(heard == [CGSize(width: 400, height: 300)], "an update would bring back a size older than the window's")

        stage.pictureSize = CGSize(
            width : 500,
            height: 320
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(heard.last == CGSize(width: 500, height: 320))
    }

    @Test("A held window changing shape moves only the picture; the stage and its backdrop stay")
    func stageKeepsItsSize() {
        let stage = ScreenStageView(
            picture : NSView(),
            backdrop: NSView()
        )
        stage.frame = CGRect(
            origin: .zero,
            size  : WorkerScreenWindowController.contentSize
        )
        stage.pictureSize = CGSize(
            width : 230,
            height: 408
        )
        stage.layoutSubtreeIfNeeded()
        #expect(stage.picture.frame == CGRect(x: 245, y: 36, width: 230, height: 408))

        stage.pictureSize = CGSize(
            width : 2560,
            height: 1440
        )
        stage.layoutSubtreeIfNeeded()
        #expect(stage.frame.size == WorkerScreenWindowController.contentSize)
        #expect(stage.picture.frame == CGRect(x: 0, y: 38, width: 720, height: 405))
        #expect(stage.backdrop?.frame == stage.bounds.insetBy(
            dx: -2 * ScreenStageView.blurRadius,
            dy: -2 * ScreenStageView.blurRadius
        ))
        #expect(stage.backdrop?.layer?.filters?.count == 1, "blurred by Core Animation")
    }

    @Test("The enlarged preview follows the captured display instead of the old window")
    func capturedShapeResizesTheEnlargedPreview() throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let team = TeamModel(store: try WorkspaceStore.opening(in: directory),
                             connections: ModelSettingsStore(), broker: SeatBroker())
        let host = ConversationEnlargedScreen.makeHost(team: team, workerID: UUID(), origin: .inspector,
                                                       reducesMotion: true, label: "Test")
        host.nativeSize = CGSize(width: 230, height: 408)
        let content = try #require(host.subviews.compactMap { $0 as? NSHostingView<LiveScreenView> }.first)
        content.rootView.onPictureSize?(CGSize(width: 2560, height: 1440))
        #expect(host.nativeSize == CGSize(width: 2560, height: 1440))
    }

    @Test("Stop and Take Control work; Say Something waits for later")
    func controls() {
        let controls = ScreenHoverControls.Control.allCases
        #expect(controls.map(\.title) == ["Stop", "Take Control", "Say Something"])
        #expect(controls.map(\.isEnabled) == [true, true, false])
        typealias Control = ScreenHoverControls.Control
        #expect(Control.takeControl.help(namingKey: true) == "Pause the worker and use the application yourself (⌃⌥Tab).")
        #expect(Control.takeControl.help(namingKey: false) == "Pause the worker and use the application yourself.")
        #expect(Control.endHelp(namingKey: true) == "Give the application back to the worker (⌃⌥Tab).")
        #expect(Control.endHelp(namingKey: false) == "Give the application back to the worker.")
        #expect(Control.saySomething.help(namingKey: true) == "Coming later")
        #expect(!ScreenHoverControls.isUnderway(nil), "Take Control until a lending starts")
    }

    @Test("The help names ⌃⌥Tab only where a press acts: never with VoiceOver, while blocked or ignored")
    func helpNamesTheKeyOnlyWhereItWorks() {
        typealias State = ControlToggle.State
        let holding = State(holdsApplication: true)
        let lent    = State(
            holdsApplication: true,
            isUnderway      : true,
            isLent          : true
        )
        #expect(ControlToggle.namesKey(holding, voiceOver: false), "Take Control")
        #expect(ControlToggle.namesKey(lent, voiceOver: false), "End Control, the landing taken as done")
        #expect(!ControlToggle.namesKey(holding, voiceOver: true), "VoiceOver unregisters the key")
        #expect(!ControlToggle.namesKey(lent, voiceOver: true))
        var blocked = lent
        blocked.isBlocked = true
        #expect(!ControlToggle.namesKey(blocked, voiceOver: false), "blocked control ignores the key")
        var finishing = lent
        finishing.isFinishing = true
        #expect(!ControlToggle.namesKey(finishing, voiceOver: false), "and so does the hand-back under way")
        var handingBack = holding
        handingBack.isHandingBack = true
        #expect(!ControlToggle.namesKey(handingBack, voiceOver: false))
        var onItsWay = lent
        onItsWay.isLent = false
        #expect(!ControlToggle.namesKey(onItsWay, voiceOver: false), "nor while the application is on its way")
    }

    @Test("The hand-back moves the window over the lent window as it leaves, not as read at Yes")
    func handBackFollowsTheLeavingFrame() throws {
        let worker     = try busyWorker
        let directory  = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let team       = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        let controller = WorkerScreenWindowController(
            worker: worker,
            team  : team
        )
        let window     = try #require(controller.window)
        let before     = window.frame
        let leaving    = CGRect(
            x     : 300,
            y     : 200,
            width : 900,
            height: 600
        )
        controller.handBack(leavingFrom: leaving)
        #expect(window.frame == before, "only during the hand-back")

        team.setHandingBack(
            worker.id,
            true
        )
        defer {
            team.setHandingBack(
                worker.id,
                false
            )
        }
        controller.handBack(leavingFrom: leaving)
        #expect(controller.pictureFrame == leaving)
    }

    @Test("A live window marks its worker windowed, so the small views pause, and unmarks it on close")
    func liveWindowPausesTheSmallViews() throws {
        let worker    = try busyWorker
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        let present = WorkerScreenWindowController.present
        var presented: [WorkerScreenWindowController] = []
        WorkerScreenWindowController.present = { controller, _ in presented.append(controller) }
        defer { WorkerScreenWindowController.present = present }

        let first  = WorkerScreenWindowController.open(
            worker: worker,
            team  : team
        )
        let second = WorkerScreenWindowController.open(
            worker: worker,
            team  : team
        )
        #expect(first === second, "one window per worker")
        #expect(team.windowedScreens == [worker.id])

        first.close()
        #expect(team.windowedScreens.isEmpty)
        #expect(WorkerScreenWindowController.openWindows[worker.id] == nil)
    }

    @Test("The screen shows in one place at a time: its window takes it from the others, and closing gives it back")
    func onePlaceAtATime() throws {
        let worker    = try busyWorker
        let other     = try #require(HouseFixture.workers.first { $0.id != worker.id })
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        let present = WorkerScreenWindowController.present
        WorkerScreenWindowController.present = { _, _ in }
        defer { WorkerScreenWindowController.present = present }
        team.selection = worker.id
        #expect(team.screenPlace(of: worker.id) == .inspector)
        team.showsScreenInConversation = true
        #expect(team.screenPlace(of: worker.id) == .conversation)
        team.enlargedScreen = ScreenEnlargement(
            workerID: worker.id,
            origin  : .conversation
        )

        let controller = WorkerScreenWindowController.open(
            worker: worker,
            team  : team
        )
        #expect(team.screenPlace(of: worker.id) == .window, "neither in the conversation nor in the inspector")
        #expect(team.enlargedScreen == nil, "the window takes the enlarged screen too")
        #expect(team.screenPlace(of: other.id) == .conversation, "another worker's screen stays where it was")
        controller.close()
        #expect(team.screenPlace(of: worker.id) == .conversation, "back where it was before the window")

        let reopened = WorkerScreenWindowController.open(
            worker: worker,
            team  : team
        )
        defer { reopened.close() }
        team.showsScreenInConversation = false
        #expect(team.screenPlace(of: worker.id) == .inspector, "the toggle brings it back from the window")
        #expect(team.windowedScreens.isEmpty)
    }

    @Test("The window and its worker sit at the normal level and go behind another Braus window brought forward")
    func ordersAsADocumentWindow() throws {
        let worker     = try busyWorker
        let directory  = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let controller = WorkerScreenWindowController(
            worker: worker,
            team  : TeamModel(
                store      : try WorkspaceStore.opening(in: directory),
                connections: ModelSettingsStore(),
                broker     : SeatBroker()
            )
        )
        let window     = try #require(controller.window)
        let braus      = NSWindow(
            contentRect: window.frame,
            styleMask  : [.titled],
            backing    : .buffered,
            defer      : false
        )
        braus.isReleasedWhenClosed = false
        // Nearly clear, so the test hardly shows over the person's work.
        for each in [window, braus, controller.presencePanel] { each.alphaValue = 0.02 }
        defer {
            controller.close()
            braus.close()
        }
        controller.showWindow(nil)
        let panel = controller.presencePanel
        #expect(window.level == .normal)
        #expect(panel.level == .normal)
        #expect(!panel.isFloatingPanel)
        #expect(panel.parent === window, "the worker rides on its own window only")

        braus.makeKeyAndOrderFront(nil)
        // Front to back among the app's windows, which leave panels out; the worker rides on its window.
        #expect(braus.orderedIndex < window.orderedIndex, "Braus's window in front of the screen window")
    }

    @Test("Nothing opens for a worker with no screen to watch")
    func noScreenNoWindow() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        let id = UUID()
        WorkerScreenWindowController.open(
            workerID: id,
            team    : team
        )
        #expect(WorkerScreenWindowController.openWindows[id] == nil)
        #expect(team.windowedScreens.isEmpty)
    }

    @Test("A seat starting to hold an application opens the window once per hold, not after it closed, not in tests")
    func opensOncePerHold() throws {
        let worker    = try busyWorker
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        let present = WorkerScreenWindowController.present
        var keys: [Bool] = []
        WorkerScreenWindowController.present = { _, makesKey in keys.append(makesKey) }
        defer { WorkerScreenWindowController.present = present }

        #expect(!team.opensHeldScreens, "a test or check run opens nothing over the person's work")
        #expect(!team.screenHeld(worker.id, true))
        #expect(!team.screenHeld(worker.id, false))

        team.opensHeldScreens = true
        #expect(team.screenHeld(worker.id, true), "the hold begins")
        let window = WorkerScreenWindowController.open(
            worker  : worker,
            team    : team,
            makesKey: false
        )
        #expect(keys == [false], "opened for a hold, it takes no keyboard")
        window.close()
        #expect(!team.screenHeld(worker.id, true), "closed by the person, it stays closed for this hold")
        #expect(!team.screenHeld(worker.id, false), "the hold ends")
        #expect(team.screenHeld(worker.id, true), "the next hold opens it again")
    }

    @Test("Shown for a hold, the window comes in front without the keyboard and without activating Braus")
    func showsWithoutFocus() throws {
        let worker     = try busyWorker
        let directory  = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let controller = WorkerScreenWindowController(
            worker: worker,
            team  : TeamModel(
                store      : try WorkspaceStore.opening(in: directory),
                connections: ModelSettingsStore(),
                broker     : SeatBroker()
            )
        )
        let window     = try #require(controller.window)
        // Nearly clear, so the test hardly shows over the person's work.
        for each in [window, controller.presencePanel] { each.alphaValue = 0.02 }
        defer { controller.close() }
        let wasActive = NSApp.isActive
        let key       = NSApp.keyWindow

        controller.show(makingKey: false)
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        #expect(NSApp.keyWindow === key, "the keyboard stays where it was")
        #expect(NSApp.isActive == wasActive, "Braus is not activated")
        #expect(controller.presencePanel.parent === window, "the worker rides on the window")
    }

    @Test("The worker's panel eases only a change of place its window's move does not explain")
    func panelJumps() {
        let window = CGRect(x: 400, y: 200, width: 720, height: 480)
        let panel  = CGRect(x: 900, y: 650, width: 339, height: 68)
        let moved  = window.offsetBy(dx: 10, dy: 0)
        #expect(!WorkerScreenWindowController.jumps(
            from: panel,
            to  : panel.offsetBy(dx: 10, dy: 0),
            as  : window,
            goes: moved
        ), "free, it follows the corner")
        #expect(!WorkerScreenWindowController.jumps(
            from: panel,
            to  : panel,
            as  : window,
            goes: window.offsetBy(dx: 10, dy: 5)
        ), "moved in, it stays")
        #expect(!WorkerScreenWindowController.jumps(
            from: panel,
            to  : panel.offsetBy(dx: 4, dy: 0),
            as  : window,
            goes: moved
        ), "crossing to where it is moved in, it lands between")
        #expect(WorkerScreenWindowController.jumps(
            from: panel,
            to  : panel.offsetBy(dx: -37, dy: 0),
            as  : window,
            goes: window
        ), "the window reaching another screen moves it alone")
        #expect(WorkerScreenWindowController.jumps(
            from: panel,
            to  : panel.offsetBy(dx: -5, dy: 0),
            as  : window,
            goes: moved
        ), "against the window's move")
    }

    @Test("Dragged up, the picture's top reaches the bottom of the menu bar, the neon's margin above it")
    func pictureReachesMenuBar() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let top     = WorkerScreenWindowController.windowTop(under: visible)
        let window  = CGRect(x: 100, y: 300, width: 720, height: 480).carried(
            from : CGPoint(x: 400, y: 770),
            to   : CGPoint(x: 400, y: 2000),
            under: top
        )
        #expect(WorkerScreenWindowController.picture(in: window).maxY == visible.maxY)
        #expect(window.maxY == visible.maxY + ScreenWindowFrame.margin, "the margin goes under the menu bar")
    }

    @Test("A dragged window is placed from the pointer, its picture held under the menu bar, and re-anchored on a frame it reports")
    func carriedByPointer() {
        let top   : CGFloat = 1000
        var carry = WorkerScreenWindowController.Carry(
            frame: CGRect(x: 100, y: 300, width: 720, height: 480),
            grab : CGPoint(x: 400, y: 770)
        )
        func frame(
            _ reported: CGRect,
            _ x       : CGFloat,
            _ y       : CGFloat
        ) -> CGRect {
            carry.frame(
                reported: reported,
                pointer : CGPoint(x: x, y: y),
                under   : top
            )
        }
        let pressed = CGRect(x: 100, y: 300, width: 720, height: 480)
        #expect(frame(pressed, 450, 740) == CGRect(x: 150, y: 270, width: 720, height: 480),
                "the window frame standing still, the pointer carries it")
        #expect(frame(pressed, 450, 1100) == CGRect(x: 150, y: 520, width: 720, height: 480),
                "its top stays under the menu bar")

        // A report 3 points off where the pointer put it is trusted and the grab taken from it.
        let reported = CGRect(x: 153, y: 300, width: 720, height: 480)
        #expect(frame(reported, 460, 770) == reported)
        #expect(frame(reported, 470, 760) == CGRect(x: 163, y: 290, width: 720, height: 480))

        // Reported held under the menu bar while the pointer is above it: the grab keeps its height,
        // so the window comes back down only with the pointer.
        let held = CGRect(x: 163, y: 520, width: 720, height: 480)
        #expect(frame(held, 470, 1100) == held)
        #expect(frame(held, 480, 1000) == CGRect(x: 173, y: 520, width: 720, height: 480))
        #expect(frame(held, 480, 980) == CGRect(x: 173, y: 510, width: 720, height: 480))
    }

    @Test("A press just outside the picture takes its edges, two near a corner, none on it or farther out")
    func resizeEdges() {
        let picture = CGRect(x: 52, y: 52, width: 800, height: 600)
        func edges(_ x: CGFloat, _ y: CGFloat) -> ScreenWindowFrame.Edges? {
            ScreenWindowFrame.edges(at: CGPoint(x: x, y: y), picture: picture, grip: 8)
        }
        #expect(edges(48, 300) == .left)
        #expect(edges(856, 300) == .right)
        #expect(edges(400, 655) == .top)
        #expect(edges(400, 46) == .bottom)
        #expect(edges(48, 655) == [.left, .top])
        #expect(edges(856, 55) == [.right, .bottom], "near the corner, along its edge")
        #expect(edges(400, 300) == nil, "the picture moves the window")
        #expect(edges(40, 300) == nil)
    }

    @Test("A resize moves the edges taken, keeps the sides across, and never goes under the least size")
    func resizedPicture() {
        let start = CGRect(x: 100, y: 100, width: 800, height: 600)
        let least = WorkerScreenWindowController.minimumSize
        #expect(ScreenWindowFrame.resized(start, edges: [.right, .bottom], by: CGVector(dx: 40, dy: -30), minimum: least)
            == CGRect(x: 100, y: 70, width: 840, height: 630))
        #expect(ScreenWindowFrame.resized(start, edges: [.left, .top], by: CGVector(dx: 40, dy: 25), minimum: least)
            == CGRect(x: 140, y: 100, width: 760, height: 625))
        let shrunk = ScreenWindowFrame.resized(start, edges: .left, by: CGVector(dx: 700, dy: 0), minimum: least)
        #expect(shrunk == CGRect(x: 900 - least.width, y: 100, width: least.width, height: 600),
                "the right side stays where the least size stops it")
    }

    @Test("A frame carried by the pointer moves with it and keeps its top under a limit")
    func carriedFrame() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let grab  = CGPoint(x: 400, y: 680)
        #expect(frame.carried(from: grab, to: CGPoint(x: 410, y: 670)) == CGRect(x: 110, y: 90, width: 800, height: 600))
        #expect(frame.carried(from: grab, to: CGPoint(x: 410, y: 900), under: 750)
            == CGRect(x: 110, y: 150, width: 800, height: 600))
    }
}
