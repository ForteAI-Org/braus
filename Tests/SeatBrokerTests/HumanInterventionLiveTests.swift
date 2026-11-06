//
//  HumanInterventionLiveTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

#if DEBUG
import AppKit
@testable import AutomationMCP
import AutomationRuntime
import ApplicationServices
import Engine
import Foundation
import ImageIO
import InteractionListener
import InteractionObservation
import LocalMCP
import Perception
import PerceptionCore
import SeatCore
import SeatInput
import WindowPlacement
import Testing
@testable import SeatBroker

/// The whole report path on real applications of this Mac, with no person: the events a person's input would
/// raise are handed to the recorder as the listener hands them, the changes they stand for are made through
/// accessibility or on disk at the same moment, and the reads after each action, the ledger and the report are
/// the app's own. Scratch data only. Off unless BRAUS_LIVE_REPORT names the scenarios (finder,calculator,textedit,canvas).
@Suite(.serialized)
@MainActor
struct HumanInterventionLiveTests {
    nonisolated private static var scenarios: Set<String> {
        Set((ProcessInfo.processInfo.environment["BRAUS_LIVE_REPORT"] ?? "").split(separator: ",").map(String.init))
    }

    /// The listener's stand-in: events go in as `send` yields them.
    private final class Source: HumanInteractionSource {
        let buttons = InteractionButtonState()
        let events: AsyncThrowingStream<InteractionEvent, any Error>
        let continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation
        init() { (events, continuation) = AsyncThrowingStream.makeStream() }
        func stop() async { continuation.finish() }
    }

    /// One lent window, its recorder and the events handed to it.
    @MainActor
    private final class Episode {
        let window: InteractionWindow
        let source = Source()
        let recorder: HumanInterventionRecorder
        private var sequence: UInt64 = 0

        init(
            window     : InteractionWindow,
            sceneReader: any HumanSceneReading = NativeHumanSceneReader()
        ) throws {
            self.window = window
            recorder = try HumanInterventionRecorder(
                window: LentWindow(
                    windowNumber: window.number,
                    processID   : window.processID,
                    frame       : window.frame
                ),
                source     : source,
                reader     : NativeHumanInteractionReader(),
                sceneReader: sceneReader,
                onFailure  : { Issue.record("recorder failed: \($0)") }
            )
        }

        /// An event of `kind` at `point`, in window-server space, as the listener reports it.
        func send(
            _ kind   : InteractionEvent.Kind,
            at point : CGPoint? = nil,
            keyCode  : UInt16? = nil,
            modifiers: InteractionEvent.Modifiers? = nil,
            endPoint : CGPoint? = nil
        ) {
            sequence += 1
            let now = ProcessInfo.processInfo.systemUptime
            source.continuation.yield(InteractionEvent(
                kind             : kind,
                timestamp        : Date(),
                startedAt        : now,
                endedAt          : now + 0.05,
                precedingRevision: sequence - 1,
                revision         : sequence,
                point            : point ?? CGPoint(
                    x: window.frame.midX,
                    y: window.frame.midY
                ),
                window           : window,
                processID        : window.processID,
                sequence         : sequence,
                keyCode          : keyCode,
                modifiers        : modifiers,
                endPoint         : endPoint,
                clickCount       : kind == .click ? 1 : nil
            ))
        }

        /// Stops the recording and answers the report the worker would receive.
        func report() async throws -> HumanInterventionSummary.Digest {
            await recorder.stop()
            let review = try #require(recorder.review)
            for finding in review.findings + [review.finalState] {
                let scenes = (try? finding.sceneEvidence().scenes) ?? [:]
                let structure = finding.provenance?.surfaces.compactMap(\.structure).flatMap(\.windows) ?? []
                for window in structure { for list in window.collections { print("LIVE   list \(list.name ?? "unnamed") \(list.role) \(list.coverage): \(list.members.prefix(8).map(\.name))") } }
                print("LIVE finding #\(finding.sequence) \(finding.kind) reason \(String(describing: finding.reason)) read \(finding.readMilliseconds ?? -1) ms; scenes \(scenes.mapValues(\.elements.count)); structure \(structure.map { "\($0.number): \($0.elements) el, \($0.fields.count) fields, \($0.collections.count) lists" })")
            }
            let evidence = HumanInterventionEvidence(findings: review.findings, finalState: review.finalState)
            for (change, disposition) in zip(evidence.ledger.netChanges, evidence.ledger.dispositions) {
                print("LIVE net \(change.kind.rawValue) \"\(change.name)\" \(change.before ?? "∅") → \(change.after ?? "∅") -> \(disposition)")
            }
            return HumanInterventionSummary.digest(evidence)
        }
    }

    /// CanvasReader observes native idle capture completion so the live scenario does not race its baseline, and
    /// steps the fixture's two-level meter before each idle capture, so every one sees the meter's other extreme.
    private actor CanvasReader: HumanSceneReading {
        private let native = NativeHumanSceneReader()
        private(set) var idleFrames = 0

        func read(
            window: InteractionWindow,
            mode  : ProductionPerception.Mode,
            timing: NativeHumanSceneReader.Timing
        ) async throws -> (scene: SceneSnapshot, frame: HumanInterventionCanvases.Frame?) {
            do {
                return try await native.read(
                    window: window,
                    mode  : mode,
                    timing: timing
                )
            } catch {
                print("LIVE canvas read \(mode) failed: \(error)")
                throw error
            }
        }

        func scene(
            window: InteractionWindow,
            mode  : ProductionPerception.Mode,
            timing: NativeHumanSceneReader.Timing
        ) async throws -> SceneSnapshot {
            try await read(
                window: window,
                mode  : mode,
                timing: timing
            ).scene
        }

        func canvasRead(window: InteractionWindow) async throws -> (scene: SceneSnapshot, frame: HumanInterventionCanvases.Frame)? {
            try await native.canvasRead(window: window)
        }

        func frame(of window: InteractionWindow) async throws -> HumanInterventionCanvases.Frame? {
            await CanvasFixtureMeter.step()
            let result = try await native.frame(of: window)
            if result != nil { idleFrames += 1 }
            return result
        }

        func windows(processID: Int32) async throws -> [InteractionWindow] {
            try await native.windows(processID: processID)
        }

        func finalWindows(processID: Int32) async throws -> [InteractionWindow] {
            try await native.finalWindows(processID: processID)
        }

        func structure(
            processID: Int32,
            seconds  : Double
        ) async -> InteractionStructuralRead {
            await native.structure(
                processID: processID,
                seconds  : seconds
            )
        }
    }

    /// Waits for the consumer's four native idle captures, bounded even when the host is busy.
    private static func canvasReady(_ reader: CanvasReader) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await reader.idleFrames < HumanInterventionConsumer.idleFrames {
            try #require(ContinuousClock.now < deadline, "canvas baseline did not finish")
            try await Task.sleep(for: .milliseconds(20))
        }
        await Self.pause(50)
        let count = await reader.idleFrames
        print("LIVE canvas ready after \(count) idle frames")
    }

    // MARK: Accessibility and windows

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// The first element under `root`, breadth first, that `matches`.
    private static func find(in root: AXUIElement, limit: Int = 4000, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < limit {
            let element = queue.removeFirst()
            seen += 1
            if matches(element) { return element }
            queue += children(element)
        }
        return nil
    }

    private static func text(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute(element, $0) as? String }
    }

    /// The element's centre in window-server space, where a click on it lands.
    private static func centre(_ element: AXUIElement) -> CGPoint? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
    }

    /// The front on-screen window of `processID` whose title contains `title` (any when nil).
    /// The application's first normal window, waited for up to 30 seconds: a second launch of an app on a busy Mac
    /// can take well over ten.
    private static func window(of processID: Int32, titled title: String? = nil) async throws -> InteractionWindow {
        for _ in 0..<120 {
            let found = InteractionWindowReader.windows(excluding: -1).first {
                $0.processID == processID && $0.layer == 0 && $0.frame.width > 200
                    && (title == nil || ($0.title ?? "").contains(title!))
            }
            if let found { return found }
            try await Task.sleep(for: .milliseconds(250))
        }
        let shown = InteractionWindowReader.windows(excluding: -1).filter { $0.processID == processID }
        print("LIVE no window of PID \(processID) after 30 s; its windows: \(shown.map { "\($0.layer) \($0.frame)" })")
        throw CancellationError()
    }

    private static func application(_ bundleID: String) async throws -> NSRunningApplication {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { return running }
        let url = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
        return try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private static func pause(_ milliseconds: Int = 900) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    /// Waits until `shown` holds, up to five seconds: a change made on disk reaches the window when the application
    /// draws it, which a person sees before acting again.
    private static func until(_ shown: () -> Bool) async {
        for _ in 0..<50 where !shown() { try? await Task.sleep(for: .milliseconds(100)) }
    }

    // MARK: Scenarios

    /// Finder on a scratch folder: a file renamed, a folder made, a file deleted.
    @Test(.enabled(if: scenarios.contains("finder"))) func finder() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BrausLive-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["alpha.txt", "beta.pdf", "gamma.md"] {
            try Data("scratch\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let finder = try await Self.application("com.apple.finder")
        NSWorkspace.shared.open(folder)
        await Self.pause(1500)
        let window = try await Self.window(of: finder.processIdentifier, titled: folder.lastPathComponent)
        let episode = try Episode(window: window)
        await Self.pause(1500)
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        // Searched in the folder's own window: the whole application holds the desktop's icons too.
        let folderWindow = (Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
            (Self.attribute($0, kAXTitleAttribute) as? String) == folder.lastPathComponent
        } ?? app
        func file(_ name: String) -> CGPoint? {
            Self.find(in: folderWindow, limit: 400) { Self.text($0).contains(name) }.flatMap(Self.centre)
        }
        // Select alpha.txt, rename it as the in-place editor would.
        episode.send(.click, at: file("alpha.txt"))
        await Self.pause()
        episode.send(.shortcut, keyCode: 36)
        episode.send(.typing, at: file("alpha.txt"))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("alpha.txt"),
                                         to: folder.appendingPathComponent("alpha-renamed.txt"))
        episode.send(.shortcut, keyCode: 36)
        await Self.until { file("alpha-renamed.txt") != nil }
        await Self.pause(1500)
        // A new folder (⌘⇧N).
        episode.send(.shortcut, keyCode: 45, modifiers: [.command, .shift])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("untitled folder"), withIntermediateDirectories: false)
        await Self.until { file("untitled folder") != nil }
        await Self.pause(1500)
        // gamma.md to the bin (⌘⌫), removed here instead of the person's Trash.
        episode.send(.click, at: file("gamma.md"))
        await Self.pause()
        episode.send(.shortcut, keyCode: 51, modifiers: .command)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("gamma.md"))
        await Self.until { file("gamma.md") == nil }
        await Self.pause(2000)
        let digest = try await episode.report()
        print("LIVE finder\n\(digest.text)\nLIVE stated: \(digest.stated)")
        #expect(digest.stated.contains { $0.contains("alpha-renamed.txt") })
        #expect(digest.stated.contains { $0.contains("untitled folder") })
        #expect(digest.stated.contains { $0.contains("gamma.md") })
        if let window = (Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
            (Self.attribute($0, kAXTitleAttribute) as? String) == folder.lastPathComponent
        }), let close = Self.attribute(window, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Calculator: 1 + 2 =, every key pressed through accessibility.
    @Test(.enabled(if: scenarios.contains("calculator"))) func calculator() async throws {
        let calculator = try await Self.application("com.apple.calculator")
        calculator.activate()
        await Self.pause(1200)
        let window = try await Self.window(of: calculator.processIdentifier)
        let app = AXUIElementCreateApplication(calculator.processIdentifier)
        func key(_ names: [String]) -> AXUIElement? {
            Self.find(in: app) { element in
                (Self.attribute(element, kAXRoleAttribute) as? String) == "AXButton"
                    && !Set(Self.text(element)).isDisjoint(with: names)
            }
        }
        if let clear = key(["All Clear", "Clear", "AC", "C"]) { AXUIElementPerformAction(clear, kAXPressAction as CFString) }
        await Self.pause()
        let episode = try Episode(window: window)
        await Self.pause(1500)
        for names in [["1", "One"], ["Add", "+"], ["2", "Two"], ["Equals", "="]] {
            let button = try #require(key(names), "no key \(names)")
            episode.send(.click, at: Self.centre(button))
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            await Self.pause()
        }
        await Self.pause(1500)
        let digest = try await episode.report()
        print("LIVE calculator\n\(digest.text)\nLIVE stated: \(digest.stated)")
        // The display is static text, not a value: "1 + 2" and "3" read as controls shown and hidden, which are noise.
        withKnownIssue("a result shown as static text is not reported") { #expect(digest.text.contains("3")) }
    }

    /// The fixture's idle meter produces no picture; a real, process-directed drag then moves lane 2's clip.
    /// The listener is a stand-in, while window input, captures, report construction and lazy PNG details are native.
    @Test(.enabled(if: scenarios.contains("canvas"))) func canvas() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BRAUS_CANVAS_FIXTURE"])
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--meter-two-levels"]
        var fixture = try await NSWorkspace.shared.openApplication(
            at           : URL(fileURLWithPath: path),
            configuration: configuration
        )
        defer { fixture.terminate() }
        await Self.pause(1500)
        let window = try await Self.window(of: fixture.processIdentifier)
        let app = AXUIElementCreateApplication(fixture.processIdentifier)
        let play = try #require(Self.find(in: app) { Self.text($0).contains("Play") }.flatMap(Self.centre))
        let idleReader = CanvasReader()
        let idle = try Episode(
            window     : window,
            sceneReader: idleReader
        )
        try await Self.canvasReady(idleReader)
        // The meter moves during the episode too, so only its learned noise keeps it out of the report.
        await CanvasFixtureMeter.step()
        idle.send(
            .click,
            at: play
        )
        await Self.pause(1500)
        let idleDigest = try await idle.report()
        let idleReview = try #require(idle.recorder.review)
        for canvas in idleReview.findings.flatMap({ $0.canvases ?? [] }) {
            print("LIVE unexpected idle canvas: \(canvas.caption)")
        }
        #expect(!idleDigest.text.contains("Canvas changed"))
        #expect(idleReview.findings.allSatisfy { $0.canvases == nil })
        print("LIVE canvas meter only\n\(idleDigest.text)")

        fixture.terminate()
        await Self.until { fixture.isTerminated }
        try #require(fixture.isTerminated)
        // A separate still episode isolates the clip's pixels from the independently tested animation.
        configuration.arguments = ["--still"]
        fixture = try await NSWorkspace.shared.openApplication(
            at           : URL(fileURLWithPath: path),
            configuration: configuration
        )
        let dragWindow = try await Self.window(of: fixture.processIdentifier)
        print("LIVE canvas fixture PID \(fixture.processIdentifier), test PID \(ProcessInfo.processInfo.processIdentifier)")
        let dragReader = CanvasReader()
        let episode = try Episode(
            window     : dragWindow,
            sceneReader: dragReader
        )
        try await Self.canvasReady(dragReader)
        let start = CGPoint(
            x: dragWindow.frame.minX + 300,
            y: dragWindow.frame.minY + 294
        )
        let end = CGPoint(
            x: start.x + 120,
            y: start.y
        )
        let reference = try #require(WindowServerProbe.geometry(
            of                   : dragWindow.number,
            allowUnvalidatedBuild: true
        ))
        let geometry = try #require(RemoteWindowProbe.recipientGeometry(
            of                   : reference,
            allowUnvalidatedBuild: true
        ))
        try #require(geometry.window.processID == fixture.processIdentifier)
        try #require(geometry.window.frame == dragWindow.frame)
        let from = try #require(InputLocation(
            screenPoint: start,
            observedIn : geometry
        ))
        let to = try #require(InputLocation(
            screenPoint: end,
            observedIn : geometry
        ))
        let driver = try InputDriver(allowUnvalidatedBuild: true)
        let receipt = try await driver.send(
            .drag(
                from: from,
                to  : to
            ),
            to           : geometry.window,
            correlationID: 0x5b,
            platform     : AppKitPlatform()
        )
        #expect(receipt.eventCount == InputCommand.dragStepCount + 3)
        #expect(!receipt.hasUnrestoredPreparation)
        print("LIVE canvas driver: \(receipt.eventCount) events, route \(receipt.route)")
        episode.send(
            .drag,
            at      : start,
            endPoint: end
        )
        await Self.pause(1500)
        let digest = try await episode.report()
        let review = try #require(episode.recorder.review)
        let lines = digest.text.split(separator: "\n").filter { $0.hasPrefix("Canvas changed: ") }
        print("LIVE canvas drag\n\(digest.text)")
        try #require(lines.count == 1)
        let stepText = try #require(lines.first?.components(separatedBy: "recorded handoff step ").last)
        let step = try #require(Int(stepText.prefix { $0.isNumber }))
        let details = HumanInterventionDetails(
            review      : review,
            digest      : digest,
            intervention: episode.recorder.intervention,
            withholding : { $0 }
        )
        let request = try HumanStepTool.request(.object(["picture": .number(Double(step))]))
        let picture = details.result(request)
        #expect(!picture.isError)
        #expect(picture.images.map(\.mimeType) == ["image/png", "image/png"])
        let blocks = try #require(HumanStepTool.result(
            picture,
            withholding: { $0 }
        )["content"].array)
        #expect(blocks.count == 3)
        #expect(blocks.dropFirst().map { $0["type"].string } == ["image", "image"])
        #expect(blocks.dropFirst().map { $0["mimeType"].string } == ["image/png", "image/png"])
        let canvases = review.findings.flatMap { $0.canvases ?? [] }
        #expect(canvases.count == 1)
        let canvas = try #require(canvases.first)
        #expect(lines == ["Canvas changed: \(canvas.name) (recorded handoff step \(step))."])
        #expect(picture.text.contains(canvas.caption))
        #expect(blocks.first?["text"].string?.contains(canvas.caption) == true)
        #expect(blocks.dropFirst().compactMap { block in
            block["data"].string.flatMap { Data(base64Encoded: $0) }
        } == picture.images.map(\.data))
        print("LIVE canvas picture \(step)\n\(picture.text)")
        let coordinates = try #require(canvas.caption.components(separatedBy: "of window points ").last)
        let rectangle = try #require(coordinates.components(separatedBy: ", ").first)
        let numbers = rectangle.split { !$0.isNumber }.compactMap { Double($0) }
        try #require(numbers.count == 4)
        let crop = CGRect(
            x     : numbers[0],
            y     : numbers[1],
            width : numbers[2],
            height: numbers[3]
        )
        let timeline = CGRect(
            x     : 160,
            y     : dragWindow.frame.height - 700 + 140,
            width : 900,
            height: 320
        )
        #expect(timeline.contains(crop))
        // The clip's lane, not the timeline: the meter and caret that moved too are another region.
        #expect(crop.width < timeline.width / 2 && crop.height < timeline.height / 2)
        for (index, image) in picture.images.enumerated() {
            let source = try #require(CGImageSourceCreateWithData(
                image.data as CFData,
                nil
            ))
            let png = try #require(CGImageSourceCreateImageAtIndex(
                source,
                0,
                nil
            ))
            #expect(canvas.caption.contains("crop \(png.width)x\(png.height) px"))
            let scale = CGFloat(png.width) / crop.width
            #expect(CGFloat(png.height) == crop.height * scale)
            // Two points on opposite ends distinguish a moved clip from meter noise or a caption-only change.
            for (x, expected) in [(270.0, index == 0), (500.0, index == 1)] {
                let point = CGPoint(
                    x: x,
                    y: dragWindow.frame.height - 700 + 280
                )
                try #require(crop.contains(point))
                let bitmap = NSBitmapImageRep(cgImage: png)
                let colour = try #require(bitmap.colorAt(
                    x: Int((point.x - crop.minX) * scale),
                    y: Int((point.y - crop.minY) * scale)
                )?.usingColorSpace(.deviceRGB))
                let orange = colour.redComponent > 0.6 && colour.greenComponent > 0.2 && colour.blueComponent < 0.4
                #expect(orange == expected)
            }
            if let path = ProcessInfo.processInfo.environment["BRAUS_CANVAS_EVIDENCE_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at                          : directory,
                    withIntermediateDirectories: true
                )
                try image.data.write(to: directory.appendingPathComponent("canvas-\(index).png"))
            }
        }
        #expect(picture.images.first?.data != picture.images.last?.data)
        await details.finish()
    }

    /// TextEdit on a scratch document: text typed into it.
    @Test(.enabled(if: scenarios.contains("textedit"))) func textEdit() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BrausLive-\(Int(Date().timeIntervalSince1970)).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let textEdit = try await Self.application("com.apple.TextEdit")
        NSWorkspace.shared.open(file)
        await Self.pause(1500)
        let window = try await Self.window(of: textEdit.processIdentifier, titled: file.deletingPathExtension().lastPathComponent)
        let app = AXUIElementCreateApplication(textEdit.processIdentifier)
        let area = try #require(Self.find(in: app) { (Self.attribute($0, kAXRoleAttribute) as? String) == "AXTextArea" })
        let episode = try Episode(window: window)
        await Self.pause(1500)
        episode.send(.click, at: Self.centre(area))
        await Self.pause()
        episode.send(.typing, at: Self.centre(area))
        AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, "Shopping list" as CFString)
        await Self.pause(2000)
        let digest = try await episode.report()
        print("LIVE textedit\n\(digest.text)\nLIVE stated: \(digest.stated)")
        #expect(digest.text.contains("Shopping list") || digest.stated.contains { $0.contains("text") })
        // Leave the scratch document closed without a save prompt.
        if let close = Self.find(in: app, { (Self.attribute($0, kAXSubroleAttribute) as? String) == "AXCloseButton" }) {
            AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, "" as CFString)
            AXUIElementPerformAction(close, kAXPressAction as CFString)
        }
    }
}

/// CanvasFixtureMeter moves the fixture's `--meter-two-levels` meter to its other extreme and waits for it to draw.
private enum CanvasFixtureMeter {

    static func step() async {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.forte.CanvasFixture.step"),
            object            : nil,
            userInfo          : nil,
            deliverImmediately: true
        )
        try? await Task.sleep(for: .milliseconds(80))
    }
}
#endif
