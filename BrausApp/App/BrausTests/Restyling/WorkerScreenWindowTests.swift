import AppKit
import Testing
@testable import Braus

@Suite("WorkerScreenWindow", .serialized)
@MainActor
struct WorkerScreenWindowTests {

    private var busyWorker: HouseWorker {
        get throws {
            try #require(MockHouse.sample.workers.first { $0.status == .busy })
        }
    }

    @Test("The window is an ordinary titled window named after the worker, with its task below")
    func titleAndSubtitle() throws {
        let worker     = try busyWorker
        let controller = WorkerScreenWindowController(worker: worker)
        let window     = try #require(controller.window)
        #expect(window.title == worker.name)
        #expect(window.subtitle == worker.activity)
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(window.level == .normal)
        #expect(window.appearance?.name == .darkAqua)

        let content = try #require(window.contentView).frame.size
        #expect(abs(content.width - WorkerScreenWindowController.contentWidth) < 1)
        #expect(abs(content.width / content.height - 1.6) < 0.01)

        let items = try #require(window.toolbar).items
        let first = try #require(items.first)
        #expect(first.isNavigational, "the worker leads, before the title")
        #expect(first.view != nil)
        let open = try #require(items.last)
        #expect(open.toolTip == "Open in Braus")
        #expect(open.image != nil)
    }

    @Test("Stop works; Take Control and Say Something wait for later")
    func controls() {
        let controls = ScreenHoverControls.Control.allCases
        #expect(controls.map(\.title) == ["Stop", "Take Control", "Say Something"])
        #expect(controls.map(\.isEnabled) == [true, false, false])
        #expect(ScreenHoverControls.Control.takeControl.help == "Coming later")
        #expect(ScreenHoverControls.Control.saySomething.help == "Coming later")
    }

    @Test("The inspector's screen card opens one window per worker")
    func openedFromInspector() throws {
        let worker = try busyWorker
        var presented: [WorkerScreenWindowController] = []
        let present = WorkerScreenWindowController.present
        WorkerScreenWindowController.present = { presented.append($0) }
        defer {
            WorkerScreenWindowController.present = present
            for controller in presented { controller.close() }
        }

        HouseScreenSection.openScreen(of: worker)
        HouseScreenSection.openScreen(of: worker)

        #expect(presented.count == 2)
        #expect(presented.first === presented.last, "a second open brings the same window forward")
        #expect(presented.first?.window?.title == worker.name)
        #expect(WorkerScreenWindowController.openWindows[worker.id] === presented.first)

        presented.first?.close()
        #expect(WorkerScreenWindowController.openWindows[worker.id] == nil)
    }
}
