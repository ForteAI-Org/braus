//
//  HouseLiveFlightsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import ChatCore
import ModelTransports
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

/// The house's flights over the app's own transcript and composer: the transcript's hold and
/// frame hooks, a send landing on the real bubble, Reduce Motion, the reply button, and the queue
/// and the quote driven through `TeamModel` as the composer drives them. Everything runs in
/// offscreen windows that are never ordered in; no event reaches the system.
@MainActor
@Suite("The house's flights over the real transcript", .serialized)
struct HouseLiveFlightsTests {

    // MARK: The transcript's hooks

    @Test("A sent message's row is laid out hidden, handed over where it rests, and drawn once released")
    func heldRowIsHandedOver() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let (controller, window) = try await Self.opened(fixture, messages: 6)
        defer { window.close() }
        var arrivals: [UUID] = []
        controller.onHeldArrival = { arrivals.append($0) }

        controller.holdNextSent()
        let sent = try await fixture.say("Make the stems too.", at: 4_000)
        controller.refresh()
        await controller.settle()

        #expect(arrivals == [sent.id])
        #expect(controller.heldMessages == [sent.id])
        #expect(controller.pendingHolds == 0)
        let cell = try #require(Self.cell(of: sent.id, in: controller))
        #expect(cell.view.alphaValue == 0, "held, the row is laid out but not drawn")
        #expect(cell.view.layer?.animation(forKey: "entrance") == nil, "and plays no entrance of its own")
        let bubble = try #require(controller.bubble(ofMessage: sent.id))
        #expect(bubble.surface == controller.frame(ofMessage: sent.id))
        #expect(bubble.frame.contains(bubble.surface))
        #expect(Self.alpha(of: bubble.image, atLeft: 6) > 0.9, "the picture is the bubble, drawn though the row is hidden")

        controller.release(message: sent.id)
        #expect(cell.view.alphaValue == 1)
        #expect(controller.heldMessages.isEmpty)
    }

    @Test("A message of the person's that nobody waits for comes in as it always did")
    func unheldRowEnters() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let (controller, window) = try await Self.opened(fixture, messages: 4)
        defer { window.close() }
        var arrivals: [UUID] = []
        controller.onHeldArrival = { arrivals.append($0) }

        let sent = try await fixture.say("Make the stems too.", at: 4_000)
        controller.refresh()
        await controller.settle()

        #expect(arrivals.isEmpty)
        #expect(controller.heldMessages.isEmpty)
        #expect(try #require(Self.cell(of: sent.id, in: controller)).view.alphaValue == 1)
    }

    @Test("A transcript scrolled up scrolls to its end before the held row is handed over, with no new-message pill")
    func scrolledUpScrollsFirst() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let (controller, window) = try await Self.opened(fixture, messages: 30)
        defer { window.close() }
        controller.setVisibleTop(0)
        #expect(!controller.isAtBottom)
        var arrivals: [UUID] = []
        controller.onHeldArrival = { arrivals.append($0) }

        controller.holdNextSent()
        let sent = try await fixture.say("Make the stems too.", at: 40_000)
        controller.refresh()
        await controller.settle()
        try await Self.wait { !arrivals.isEmpty }

        #expect(arrivals == [sent.id])
        #expect(controller.isAtBottom, "the transcript reached its end before the message was handed over")
        #expect(controller.newActivity == nil)
    }

    @Test("A message offers Reply beside its bubble on its outer side while hovered, once the flights ask for it")
    func replyButtonBesideTheBubble() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let (controller, window) = try await Self.opened(fixture, messages: 4)
        defer { window.close() }
        var replies: [MessageQuote] = []
        controller.onReply = { replies.append($0) }
        let worker = try #require(controller.rows.last { $0.item.authorWorkerID != nil }?.item.messageID)
        let person = try #require(controller.rows.last { $0.item.authorWorkerID == nil && $0.item.messageID != nil }?.item.messageID)

        let still = try #require(Self.cell(of: worker, in: controller)).rowView
        Self.hover(still, onBubbleOf: worker, in: controller)
        #expect(Self.replyButton(in: still) == nil, "no reply button until the flights ask for it")

        controller.showsReplyButtons = true
        for (id, isPerson) in [(worker, false), (person, true)] {
            let row     = try #require(Self.cell(of: id, in: controller)).rowView
            let surface = try #require(controller.frame(ofMessage: id))
            Self.hover(row, onBubbleOf: id, in: controller)
            let button  = try #require(Self.replyButton(in: row))
            #expect(!button.isHidden)
            let frame   = row.convert(button.frame, to: nil)
            #expect(isPerson ? frame.maxX < surface.minX : frame.minX > surface.maxX, "on the bubble's outer side")
            button.performClick(nil)
            #expect(replies.last?.messageID == id)
        }
    }

    // MARK: Flights

    @Test("A send flies from the field onto the real bubble, which shows as the flight lands")
    func sendLandsOnTheBubble() async throws {
        HouseMotion.overrideReducesMotion = false
        defer { HouseMotion.overrideReducesMotion = nil }
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let scene = try await Self.scene(fixture)
        defer { scene.window.close() }
        let (controller, flights, field) = (scene.controller, scene.flights, scene.field)
        let start = flights.stage.convert(field.convert(field.bounds, to: nil), from: nil)

        flights.depart(
            queued    : false,
            leadsQueue: true
        )
        let root = try #require(flights.stage.layer?.sublayers?.last)
        #expect(controller.pendingHolds == 1)
        #expect(root.position == CGPoint(
            x: start.minX - LiveFlight.boxPadding.width,
            y: start.minY + field.textView.textContainerInset.height - LiveFlight.boxPadding.height
        ), "the text leaves where the field drew it")
        #expect(field.textView.hidesPlaceholder, "no placeholder under the text as it leaves")

        let sent = try await fixture.say("Make the stems too.", at: 4_000)
        controller.refresh()
        await controller.settle()

        let bubble = try #require(controller.bubble(ofMessage: sent.id))
        let target = flights.stage.convert(bubble.surface, from: nil)
        #expect(root.position == target.origin, "the flight comes down on the bubble's own frame")
        #expect(root.animationKeys()?.contains("position") == true, "and travels there")
        #expect(try #require(Self.cell(of: sent.id, in: controller)).view.alphaValue == 0)

        try await Self.wait { controller.heldMessages.isEmpty }
        #expect(try #require(Self.cell(of: sent.id, in: controller)).view.alphaValue == 1, "the bubble shows as it lands")
        try await Self.wait { root.superlayer == nil }
        try await Self.wait { !field.textView.hidesPlaceholder }
    }

    @Test("Under Reduce Motion a send only fades: the text where it was typed, the flight in at the bubble")
    func reduceMotionSendFades() async throws {
        HouseMotion.overrideReducesMotion = true
        defer { HouseMotion.overrideReducesMotion = nil }
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let scene = try await Self.scene(fixture)
        defer { scene.window.close() }
        let (controller, flights) = (scene.controller, scene.flights)

        flights.depart(
            queued    : false,
            leadsQueue: true
        )
        let root = try #require(flights.stage.layer?.sublayers?.last)
        let sent = try await fixture.say("Make the stems too.", at: 4_000)
        controller.refresh()
        await controller.settle()

        let layers = try #require(flights.stage.layer?.sublayers)
        #expect(layers.count == 2, "the flight, and the text fading where it was")
        for layer in layers.flatMap(Self.tree) {
            #expect((layer.animationKeys() ?? []).allSatisfy { $0 == "opacity" }, "\(layer.animationKeys() ?? [])")
        }
        let bubble = try #require(controller.bubble(ofMessage: sent.id))
        #expect(root.position == flights.stage.convert(bubble.surface, from: nil).origin)
        try await Self.wait { controller.heldMessages.isEmpty }
    }

    @Test("A queue that grows takes the waiting flight; one the person empties sends nothing; one the team empties flies")
    func queueChangesDecideTheFlight() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let scene = try await Self.scene(fixture)
        defer { scene.window.close() }
        let (controller, flights) = (scene.controller, scene.flights)
        flights.queueLine = CGRect(x: 60, y: 420, width: 300, height: 15)
        let one = QueuedMessage(text: "one")
        let two = QueuedMessage(text: "two")

        flights.depart(
            queued    : true,
            leadsQueue: true
        )
        #expect(flights.hidesQueueLine, "the strip waits for the text that leads it")
        flights.queueChanged(from: [], to: [one], in: fixture.conversation)
        try await Self.wait { !flights.hidesQueueLine }
        #expect(controller.pendingHolds == 0, "a queued message is no send")

        flights.expectRemoval()
        flights.queueChanged(from: [one, two], to: [two], in: fixture.conversation)
        #expect(controller.pendingHolds == 0, "a removal or an edit flies nowhere")

        flights.queueChanged(from: [two], to: [], in: UUID())
        #expect(controller.pendingHolds == 0, "another conversation's queue is not this strip's")

        flights.queueChanged(from: [one, two], to: [two], in: fixture.conversation)
        #expect(controller.pendingHolds == 1, "the end of a turn sends the strip's message")
        #expect(flights.hidesQueueLine)
    }

    // MARK: Through the team

    @Test("Send, queue, the end of a turn and a quote, through the team as the composer drives them")
    func flowsThroughTheTeam() async throws {
        let harness = try await TeamHarness()
        do {
            try await Self.flows(through: harness)
        } catch {
            await harness.discard()
            throw error
        }
        await harness.discard()
    }

    private static func flows(through harness: TeamHarness) async throws {
        let team    = harness.team
        let worker  = try #require(team.selectedWorker)
        let hosting = NSHostingView(rootView: HouseLiveConversation(
            team  : team,
            worker: worker
        ))
        let window  = TranscriptFixture.offscreenWindow(for: hosting, size: CGSize(width: 900, height: 700))
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let field      = try await find(ComposerScrollView.self, in: hosting)
        let collection = try await find(TranscriptCollectionView.self, in: hosting)
        let controller = try #require(collection.dataSource as? TranscriptController)
        let stage      = try await find(BubbleFlight.Stage.self, in: hosting)
        // SwiftUI updates a window that is never shown only when it is laid out.
        let calls      = { (count: Int) in
            try await wait {
                hosting.layoutSubtreeIfNeeded()
                return harness.calls == count
            }
        }

        // A send lands in the transcript, and its row shows once the flight is there.
        try await submit("one", through: field, of: team, in: hosting)
        try await calls(1)
        try await wait {
            hosting.layoutSubtreeIfNeeded()
            return shownPersonRows(in: controller) == ["one"]
        }
        let one = try #require(controller.rows.last { $0.item.authorWorkerID == nil }?.item.messageID)
        #expect(team.isAnswering(worker.id))

        // During the turn it joins the queue instead, and the transcript holds nothing for it.
        try await submit("two", through: field, of: team, in: hosting)
        try await wait {
            hosting.layoutSubtreeIfNeeded()
            return team.queue.map(\.text) == ["two"]
        }
        #expect(controller.pendingHolds == 0)

        // The end of the turn sends it from the strip into the transcript, held until it lands.
        try harness.go(0)
        try await calls(2)
        try await wait {
            hosting.layoutSubtreeIfNeeded()
            return shownPersonRows(in: controller) == ["one", "two"]
        }
        #expect(team.queue.isEmpty)
        #expect(controller.pendingHolds == 0)
        try await wait { stage.layer?.sublayers?.isEmpty ?? true }

        // A reply flies a copy of the bubble into the reply strip; Escape takes it back.
        let row = try #require(cell(of: one, in: controller)).rowView
        row.onReply?()
        #expect(team.draftQuote?.messageID == one)
        try await wait {
            hosting.layoutSubtreeIfNeeded()
            return stage.layer?.sublayers?.isEmpty == false
        }
        try await wait { stage.layer?.sublayers?.isEmpty ?? true }
        try await wait {
            hosting.layoutSubtreeIfNeeded()
            return field.textView.onEscape != nil
        }
        field.textView.onEscape?()
        #expect(team.draftQuote == nil)
        try harness.go(1)
    }

    // MARK: Helpers

    /// `fixture`'s conversation with `messages` alternating between the person and the worker, opened
    /// in a controller hosted in an offscreen window.
    private static func opened(
        _ fixture: TranscriptFixture,
        messages : Int
    ) async throws -> (TranscriptController, NSWindow) {
        for index in 0..<messages {
            try await fixture.say(
                "Message \(index), with a little more text to give it a line or two.",
                at      : Double(index) * 60,
                byWorker: index % 2 == 1
            )
        }
        let controller = TranscriptController(source: fixture.store)
        let window     = TranscriptFixture.offscreenWindow(
            for : controller.view,
            size: CGSize(width: 600, height: 500)
        )
        controller.open(
            fixture.conversation,
            workerName    : "Atlas",
            appearance    : TranscriptFixture.appearance,
            readingAnchor : nil,
            readingOffset : 0
        )
        await controller.settle()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// A transcript, a composer field holding a draft under it, and the flights' stage over both, in
    /// an offscreen window, with the flights attached to the transcript.
    private static func scene(_ fixture: TranscriptFixture) async throws -> (
        controller: TranscriptController,
        flights   : HouseLiveFlights,
        field     : ComposerScrollView,
        window    : NSWindow
    ) {
        for index in 0..<4 {
            try await fixture.say("Message \(index)", at: Double(index) * 60, byWorker: index % 2 == 1)
        }
        let container  = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let controller = TranscriptController(source: fixture.store)
        let field      = ComposerScrollView()
        let flights    = HouseLiveFlights()
        controller.view.frame = NSRect(x: 0, y: 100, width: 600, height: 500)
        field.frame           = NSRect(x: 40, y: 30, width: 400, height: field.fittingHeight(forWidth: 400))
        flights.stage.frame   = container.bounds
        container.addSubview(controller.view)
        container.addSubview(field)
        container.addSubview(flights.stage)
        let window = TranscriptFixture.offscreenWindow(for: container, size: container.frame.size)
        window.appearance = NSAppearance(named: .darkAqua)
        controller.open(
            fixture.conversation,
            workerName    : "Atlas",
            appearance    : TranscriptFixture.appearance,
            readingAnchor : nil,
            readingOffset : 0
        )
        await controller.settle()
        flights.attach(
            controller,
            to: fixture.conversation
        )
        flights.field.view    = field
        field.textView.string = "Make the stems too."
        container.layoutSubtreeIfNeeded()
        return (controller, flights, field, window)
    }

    /// Types `text` as the draft and sends it as Return does, through the field's own submit.
    private static func submit(
        _ text  : String,
        through field: ComposerScrollView,
        of team : TeamModel,
        in view : NSView
    ) async throws {
        team.draft = text
        try await wait {
            view.layoutSubtreeIfNeeded()
            return field.textView.string == text && field.textView.onSubmit != nil
        }
        field.textView.onSubmit?()
    }

    /// The texts of the person's rows the transcript draws, held ones left out.
    private static func shownPersonRows(in controller: TranscriptController) -> [String] {
        controller.rows.compactMap { row in
            guard case .personMessage(let text, _, _) = row.item.kind, let id = row.item.messageID,
                  !controller.heldMessages.contains(id)
            else { return nil }
            return text
        }
    }

    private static func cell(
        of messageID : UUID,
        in controller: TranscriptController
    ) -> TranscriptCell? {
        guard let index = controller.rows.firstIndex(where: { $0.item.messageID == messageID }) else { return nil }

        return controller.collectionView.item(at: IndexPath(item: index, section: 0)) as? TranscriptCell
    }

    /// Moves the pointer onto the middle of `messageID`'s bubble, as the row's tracking area reports it.
    private static func hover(
        _ row          : TranscriptRowView,
        onBubbleOf messageID: UUID,
        in controller  : TranscriptController
    ) {
        guard let surface = controller.frame(ofMessage: messageID), let window = row.window,
              let event = NSEvent.mouseEvent(
                  with         : .mouseMoved,
                  location     : CGPoint(x: surface.midX, y: surface.midY),
                  modifierFlags: [],
                  timestamp    : 0,
                  windowNumber : window.windowNumber,
                  context      : nil,
                  eventNumber  : 0,
                  clickCount   : 0,
                  pressure     : 0
              )
        else { return }
        row.mouseMoved(with: event)
    }

    private static func replyButton(in row: TranscriptRowView) -> NSButton? {
        row.subviews.compactMap { $0 as? NSButton }.first
    }

    /// The alpha of `image` `x` pixels in from its left edge, halfway down.
    private static func alpha(
        of image: CGImage,
        atLeft x: Int
    ) -> CGFloat {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: image.height / 2)?.alphaComponent ?? 0
    }

    /// `layer` and every layer under it.
    private static func tree(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(tree)
    }

    /// The first view of `type` under `view`, waited for while SwiftUI builds it.
    private static func find<View: NSView>(
        _ type : View.Type,
        in view: NSView
    ) async throws -> View {
        var found: View?
        try await wait {
            view.layoutSubtreeIfNeeded()
            found = first(type, in: view)
            return found != nil
        }
        return try #require(found)
    }

    private static func first<View: NSView>(
        _ type : View.Type,
        in view: NSView
    ) -> View? {
        if let found = view as? View { return found }
        for subview in view.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }

    /// Waits until `condition` holds, five seconds at most.
    private static func wait(for condition: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try condition())
    }
}

/// TeamHarness is a team over a store of its own whose one worker, Atlas, answers through a stand-in
/// Claude Code: each call waits for a `go-N` file, N its place among the calls, then answers "ok".
/// So a test decides when each turn ends.
@MainActor
private final class TeamHarness {

    let root       : URL
    let team       : TeamModel
    let preferences: UserDefaults

    private let suite: String

    init() async throws {
        suite       = "braus-house-flights-\(UUID().uuidString)"
        preferences = try #require(UserDefaults(suiteName: suite))
        root        = URL.temporaryDirectory.appending(path: "braus-house-flights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at                         : root.appending(path: "log"),
            withIntermediateDirectories: true
        )
        let agent = root.appending(path: "claude")
        try Data(Self.standIn(root).utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )
        let store = try WorkspaceStore.opening(in: root.appending(path: "store"))
        let atlas = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        try await store.configure(
            worker   : atlas,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-sonnet-5",
                effort  : .low
            )
        )
        team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent,
            preferences     : preferences
        )
        await team.load()
        team.selection = atlas
        await team.openSelectedConversation()
    }

    private static func standIn(_ root: URL) -> String {
        """
        #!/usr/bin/python3
        import json, os, sys, time
        root = '\(root.path)'
        received = sys.stdin.read()
        log = os.path.join(root, 'log')
        call = len(os.listdir(log))
        record = os.path.join(root, 'record-%d' % os.getpid())
        with open(record, 'w') as file:
            json.dump({'received': received}, file)
        os.replace(record, os.path.join(log, '%03d.json' % call))
        def say(event):
            event['session_id'] = 's1'
            print(json.dumps(event), flush=True)
        window = {'claude-sonnet-5': {'contextWindow': 1000}}
        say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
        while not os.path.exists(os.path.join(root, 'go-%d' % call)):
            time.sleep(0.01)
        spent = {'input_tokens': 90, 'output_tokens': 10}
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'ok'}]}})
        say({'type': 'result', 'is_error': False, 'result': 'ok', 'usage': dict(spent, iterations=[spent]),
             'modelUsage': window})

        """
    }

    /// Lets the stand-in's call number `call` answer.
    func go(_ call: Int) throws {
        try Data().write(to: root.appending(path: "go-\(call)"))
    }

    /// How many times the stand-in has been called.
    var calls: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "log").path).count) ?? 0
    }

    func discard() async {
        // Every waiting call answers, so no stand-in outlives the test.
        for call in 0..<8 { try? go(call) }
        await team.closeAgentHosts()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
