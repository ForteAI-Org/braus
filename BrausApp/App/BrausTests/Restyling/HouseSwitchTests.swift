//
//  HouseSwitchTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseSwitch", .serialized)
@MainActor
struct HouseSwitchTests {

    @Test("Under Reduce Motion every pose keeps its place and size, so a change of worker only fades")
    func reduceMotionOnlyFades() {
        for stage in [HouseSwitch.Stage.arriving, .present, .leaving] {
            let pose = HouseSwitch.pose(
                stage,
                reducesMotion: true
            )
            #expect(pose.drop == 0 && pose.scale == 1)
            #expect(pose.opacity == (stage == .present ? 1 : 0))
        }
        let arriving = HouseSwitch.pose(
            .arriving,
            reducesMotion: false
        )
        let leaving  = HouseSwitch.pose(
            .leaving,
            reducesMotion: false
        )
        #expect(arriving.drop > 0 && arriving.scale < 1)
        #expect(leaving.drop > 0 && leaving.scale < 1)
        #expect(HouseSwitch.entryDelay == RestylingTiming.roomExit)
        #expect(HouseSwitch.capsuleAnimation(
            to           : .present,
            reducesMotion: false
        ) != nil)
        #expect(HouseSwitch.capsuleAnimation(
            to           : .leaving,
            reducesMotion: true
        ) != nil)
    }

    @Test("The hero's worker rises in after the entry delay and steps down when it leaves")
    func portraitArrivesAndLeaves() throws {
        let view  = try shownPortrait(stage: .present)
        let layer = try #require(view.layer)
        let fade  = try #require(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity))
        let rise  = try #require(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform))
        #expect(rise is CASpringAnimation)
        #expect(fade.beginTime > 0 && fade.beginTime == rise.beginTime)

        view.show(
            portrait(stage: .leaving),
            animated: true
        )
        #expect(layer.opacity == 0)
        #expect(!CATransform3DIsIdentity(layer.transform))
        let out = try #require(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) as? CABasicAnimation)
        #expect(out.duration == HouseSwitch.exit)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) != nil)
    }

    @Test("Under Reduce Motion the hero's worker only fades in and out")
    func portraitOnlyFadesUnderReduceMotion() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let view  = try shownPortrait(stage: .present)
        let layer = try #require(view.layer)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) != nil)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) == nil)
        view.show(
            portrait(stage: .leaving),
            animated: true
        )
        #expect(layer.opacity == 0)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) != nil)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) == nil)
    }

    @Test("A portrait outside the hero does not come in or leave")
    func otherPortraitsStayStill() throws {
        let view = try shownPortrait(stage: nil)
        #expect(view.layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) == nil)
        #expect(view.layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) == nil)
    }

    @Test("Every shape stands in the hero's one portrait height")
    func heroHeightFitsEveryShape() {
        let side = HouseWorkerPortrait.sceneSide(for: HouseHero.workerSize)
        let heights = WorkerShape.allCases.map {
            HouseWorkerPortrait.silhouette(
                of  : $0,
                side: side
            ).boundingRect.height
        }
        #expect(heights.allSatisfy { $0 <= HouseHero.portraitHeight })
        #expect(heights.contains(HouseHero.portraitHeight))
    }

    @Test("Switching workers steps the old one down while the composer, the transcript and the toolbar stay put")
    func switchKeepsTheFrames() async throws {
        let workers = Array(MockHouse.sample.workers.prefix(4))
        let choice  = Choice()
        choice.worker = workers[0]
        let window = try await Self.window(for: choice)
        defer { window.close() }
        let host = try #require(window.contentView)

        let composer = try #require(Self.composers(in: host).first).frame
        let toolbar  = toolbarFrames(in: window)
        let columns  = scrollFrames(in: host)
        try #require(!toolbar.isEmpty && !columns.isEmpty)

        for worker in workers.dropFirst() {
            choice.worker = worker
            host.layoutSubtreeIfNeeded()
            var sawBoth  = false
            var sawLeave = false
            let end = ContinuousClock.now + .milliseconds(Int(HouseSwitch.crossFade * 1000) + 300)
            while ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(25))
                host.layoutSubtreeIfNeeded()
                let fields = Self.composers(in: host)
                sawBoth = sawBoth || fields.count == 2
                for field in fields {
                    #expect(field.frame == composer, "\(worker.name): composer at \(field.frame)")
                }
                #expect(toolbarFrames(in: window) == toolbar, "\(worker.name): toolbar moved")
                for frame in scrollFrames(in: host) {
                    #expect(columns.contains(frame), "\(worker.name): transcript at \(frame)")
                }
                let leaving = Self.all(HouseWorkerPortrait.HostView.self, in: host).filter { $0.layer?.opacity == 0 }
                sawLeave = sawLeave || leaving.contains {
                    $0.layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) != nil
                }
            }
            #expect(sawBoth, "\(worker.name): the leaving conversation did not stay")
            #expect(sawLeave, "\(worker.name): the leaving worker did not step down")
            #expect(Self.composers(in: host).count == 1)
            #expect(Self.composers(in: host).first?.field.placeholderString == "Message \(worker.name)")
        }
    }

    // MARK: Hosting

    /// Choice is the worker a test's detail column shows.
    @Observable
    final class Choice {
        var worker: MockWorker?
    }

    /// DetailHost is the house window's split with its detail column and a toolbar item there.
    private struct DetailHost: View {
        let choice: Choice

        @FocusState private var isFocused: Bool

        var body: some View {
            NavigationSplitView {
                Color.clear
            } detail: {
                HouseDetail(
                    worker           : choice.worker,
                    isComposerFocused: $isFocused
                )
                .toolbar {
                    ToolbarItem {
                        Button(
                            "Inspector",
                            systemImage: "info.circle"
                        ) {}
                    }
                }
            }
        }
    }

    private static func window(for choice: Choice) async throws -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 900,
                height: 600
            ),
            styleMask  : [.titled, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DetailHost(choice: choice))
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        let deadline = ContinuousClock.now + .seconds(2)
        while (window.toolbar?.items.count ?? 0) == 0 || Self.composers(in: host).isEmpty {
            try #require(ContinuousClock.now < deadline, "no toolbar or composer appeared")
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        // Past the first conversation's own arrival.
        try await Task.sleep(for: .milliseconds(Int(HouseSwitch.crossFade * 1000) + 100))
        host.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: Helpers

    private func portrait(stage: HouseSwitch.Stage?) -> HouseWorkerPortrait {
        HouseWorkerPortrait(
            shape      : .circle,
            status     : .busy,
            size       : HouseHero.workerSize,
            switchStage: stage
        )
    }

    /// A portrait host shown with `stage` and laid out, which starts its arrival.
    private func shownPortrait(stage: HouseSwitch.Stage?) throws -> HouseWorkerPortrait.HostView {
        let view = HouseWorkerPortrait.HostView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 60,
            height: 70
        ))
        view.show(
            portrait(stage: stage),
            animated: false
        )
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The composer fields in `view`, each with its frame in the window.
    private static func composers(in view: NSView) -> [(field: NSTextField, frame: CGRect)] {
        all(NSTextField.self, in: view)
            .filter { $0.placeholderString?.hasPrefix("Message") == true }
            .map { field in
                (
                    field: field,
                    frame: field.convert(
                        field.bounds,
                        to: nil
                    )
                )
            }
    }

    /// The window-space frames of the transcripts' scroll views.
    private func scrollFrames(in view: NSView) -> [CGRect] {
        Self.all(NSScrollView.self, in: view).filter { $0.bounds.height > 100 }.map {
            $0.convert(
                $0.bounds,
                to: nil
            )
        }
    }

    /// The window-space frames of the toolbar's items.
    private func toolbarFrames(in window: NSWindow) -> [CGRect] {
        guard let frame = window.contentView?.superview else { return [] }
        return Self.all(NSView.self, in: frame)
            .filter { String(describing: type(of: $0)).contains("ToolbarItemViewer") }
            .map {
                $0.convert(
                    $0.bounds,
                    to: nil
                )
            }
    }

    private static func all<V: NSView>(
        _ type: V.Type,
        in view: NSView
    ) -> [V] {
        ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
