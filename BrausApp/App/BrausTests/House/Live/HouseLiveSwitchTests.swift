//
//  HouseLiveSwitchTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

/// HouseLiveSwitchTests change the worker of the house window over the synthetic team
/// (`HouseShellView`, `HouseLiveConversation`), in a window that is never ordered in.
@Suite(
    "The house's change of worker over the team",
    .serialized
)
@MainActor
struct HouseLiveSwitchTests {

    @Test("A change of worker keeps the composer, the toolbar and the transcript in place, over a still of the leaving transcript")
    func switchKeepsTheFrames() async throws {
        let shown = try await Self.shownShell()
        defer { shown.close() }
        let team   = shown.team
        let window = shown.window
        let host   = try #require(window.contentView)

        let field    = try #require(Self.composer(in: host))
        let composer = Self.place(of: field)
        let toolbar  = Self.toolbarFrames(in: window)
        let column   = try #require(Self.transcriptFrame(in: host))
        try #require(!toolbar.isEmpty)

        for worker in Self.order(of: team) {
            team.selection = worker.id
            var sawStill  = false
            var sawLeave  = false
            let end = ContinuousClock.now + .milliseconds(Int(HouseSwitch.crossFade * 1000) + 400)
            while ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
                #expect(Self.composer(in: host) === field, "\(worker.name): the composer was made again")
                #expect(Self.place(of: field) == composer, "\(worker.name): composer at \(Self.frame(of: field))")
                #expect(Self.toolbarFrames(in: window) == toolbar, "\(worker.name): toolbar moved")
                #expect(Self.transcriptFrame(in: host) == column, "\(worker.name): transcript moved")
                sawStill = sawStill || Self.stills(in: host).contains { $0.image != nil }
                sawLeave = sawLeave || Self.leavingPortraits(in: host).contains {
                    $0.layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) != nil
                }
            }
            try await Self.settle(host)
            #expect(sawStill, "\(worker.name): no still of the leaving transcript")
            #expect(sawLeave, "\(worker.name): the leaving worker did not drop into the capsule")
            #expect(Self.stills(in: host).isEmpty, "\(worker.name): the still stayed")
            #expect(field.textView.placeholder.contains(worker.name))
            // Chosen with no key down, as with the pointer: the keyboard goes to the composer.
            #expect(window.firstResponder === field.textView, "\(worker.name): the composer lost the keyboard")
        }
    }

    @Test("The still is the leaving transcript as it was drawn, at the transcript's size")
    func stillIsTheTranscriptsImage() async throws {
        let shown = try await Self.shownShell()
        defer { shown.close() }
        let host       = try #require(shown.window.contentView)
        let transcript = try #require(Self.find(TranscriptCollectionView.self, in: host)?.enclosingScrollView?.superview)
        let image      = try #require(HouseTranscriptStill.image(of: transcript))
        #expect(image.size == transcript.bounds.size)
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        // Not blank: the transcript's bubbles are drawn in it.
        var colours = Set<UInt32>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colours.insert(UInt32(colour.redComponent * 255) << 16 | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255))
            }
        }
        #expect(colours.count > 4, "the still is blank")

        shown.team.selection = try #require(Self.order(of: shown.team).first?.id)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
        let still = try #require(Self.stills(in: host).first)
        #expect(still.image?.size == transcript.bounds.size)
        #expect(still.convert(still.bounds, to: nil) == transcript.convert(transcript.bounds, to: nil))
    }

    @Test("Under Reduce Motion a change of worker only fades: nothing travels, the worker does not hop")
    func reduceMotionOnlyFades() async throws {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = true
        let shown = try await Self.shownShell()
        defer { shown.close() }
        let team = shown.team
        let host = try #require(shown.window.contentView)
        let field    = try #require(Self.composer(in: host))
        let composer = Self.place(of: field)
        let column   = try #require(Self.transcriptFrame(in: host))

        for worker in Self.order(of: team) {
            team.selection = worker.id
            var sawStill = false
            var sawFade  = false
            let end = ContinuousClock.now + .milliseconds(Int(HouseSwitch.crossFade * 1000) + 400)
            while ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
                #expect(Self.place(of: field) == composer)
                #expect(Self.transcriptFrame(in: host) == column)
                for still in Self.stills(in: host) {
                    sawStill = true
                    #expect(still.convert(still.bounds, to: nil) == column, "the still moved")
                }
                for portrait in Self.all(HouseWorkerPortrait.HostView.self, in: host) {
                    let layer = portrait.layer
                    #expect(layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) == nil)
                    #expect(layer.map { CATransform3DIsIdentity($0.transform) } ?? true)
                    sawFade = sawFade || layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) != nil
                }
            }
            #expect(sawStill, "\(worker.name): no still to cross-fade")
            #expect(sawFade, "\(worker.name): the worker did not fade")
            try await Self.settle(host)
        }
    }

    @Test("Switching quickly through the team ends on the last worker chosen, its conversation shown")
    func rapidSwitchEndsOnTheLastWorker() async throws {
        let shown = try await Self.shownShell()
        defer { shown.close() }
        let team  = shown.team
        let host  = try #require(shown.window.contentView)
        let field = try #require(Self.composer(in: host))
        let team3 = Self.order(of: team)
        try #require(team3.count == 3)
        // Back to a worker whose hero is still leaving, then on through the team.
        let order = [team3[0], team3[2], team3[0], team3[1], team3[0], team3[1], team3[2]]
        let last  = team3[2]

        for worker in order {
            team.selection = worker.id
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Self.settle(host)

        #expect(team.selection == last.id)
        #expect(team.conversation?.participantIDs == [last.id])
        #expect(field.textView.placeholder.contains(last.name))
        #expect(Self.stills(in: host).isEmpty)
        let shownPortraits = Self.all(HouseWorkerPortrait.HostView.self, in: host).filter {
            $0.layer?.opacity != 0 && $0.window != nil
        }
        #expect(shownPortraits.count == 1, "one hero at the top, \(shownPortraits.count) shown")
        let transcript = try #require(Self.find(TranscriptCollectionView.self, in: host)?.enclosingScrollView?.superview)
        #expect(Self.opacity(of: transcript) == 1, "the transcript stayed hidden")
    }

    @Test("The first worker chosen in a new window, with no key down as with the pointer, gets the keyboard in the composer")
    func firstPickFocusesTheComposer() async throws {
        let folder = URL.temporaryDirectory.appending(
            path         : "HouseFirstPick-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let team  = try await WindowSnapshots.syntheticTeam(in: folder)
        let atlas = try #require(team.selection)
        // As in a window just opened: no worker chosen, no conversation open, so it opens after the pick.
        team.selection = nil
        await team.openSelectedConversation()
        let window = Self.window(hosting: ShellHost(team: team))
        defer { window.close() }
        let host = try #require(window.contentView)
        try await Self.settle(host)
        #expect(Self.composer(in: host) == nil)

        team.selection = atlas
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, !(window.firstResponder is ComposerTextView) {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        let field = try #require(Self.composer(in: host))
        #expect(
            window.firstResponder === field.textView,
            "the keyboard stayed with \(String(describing: window.firstResponder))"
        )
    }

    @Test("A hero chosen again while it leaves hops out of the capsule once more")
    func heroChosenAgainArrives() throws {
        let view = HouseWorkerPortrait.HostView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 60,
            height: 70
        ))
        for stage in [HouseSwitch.Stage.present, .leaving, .present] {
            view.show(
                HouseWorkerPortrait(
                    shape      : .circle,
                    status     : .free,
                    size       : HouseHero.workerSize,
                    switchStage: stage
                ),
                animated: true
            )
            view.layoutSubtreeIfNeeded()
        }
        let layer = try #require(view.layer)
        #expect(layer.opacity == 1)
        let fade = try #require(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) as? CABasicAnimation)
        #expect(fade.toValue as? Double == 1)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) is CAKeyframeAnimation)
    }

    // MARK: Hosting

    /// ShellHost is the house window over a team, with the inspector closed.
    private struct ShellHost: View {
        let team: TeamModel

        @State private var isInspectorRequested = false

        var body: some View {
            HouseShellView(
                team                : team,
                isInspectorRequested: $isInspectorRequested
            )
        }
    }

    /// Shown is a shell in its window, over a synthetic team in a folder of its own.
    struct Shown {
        let team  : TeamModel
        let window: NSWindow
        let folder: URL

        func close() {
            window.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The synthetic team's shell, laid out with its transcript shown and its first arrival past.
    private static func shownShell() async throws -> Shown {
        let folder = URL.temporaryDirectory.appending(
            path         : "HouseLiveSwitch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let team     = try await WindowSnapshots.syntheticTeam(in: folder)
        let window   = Self.window(hosting: ShellHost(team: team))
        let hosting  = try #require(window.contentView)
        let deadline = ContinuousClock.now + .seconds(5)
        while (window.toolbar?.items.count ?? 0) == 0
            || composer(in: hosting) == nil
            || (find(TranscriptCollectionView.self, in: hosting)?.numberOfSections ?? 0) == 0 {
            try #require(ContinuousClock.now < deadline, "no toolbar, composer or transcript appeared")
            try await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
        }
        try await settle(hosting)
        return Shown(
            team  : team,
            window: window,
            folder: folder
        )
    }

    /// A 1200 by 800 window, never ordered in, holding `root` with its toolbar.
    private static func window(hosting root: some View) -> NSWindow {
        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 1200,
                height: 800
            ),
            styleMask  : [.titled, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance           = NSAppearance(named: .darkAqua)
        window.contentView          = hosting
        return window
    }

    /// Waits past a switch: the hero's hop, the cross-fade and the still's removal.
    private static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(Int((HouseTiming.roomExit + HouseSwitch.crossFade * 2) * 1000) + 300))
        host.layoutSubtreeIfNeeded()
    }

    /// The team's workers in the order a test chooses them: every one but the selected, then it.
    private static func order(of team: TeamModel) -> [WorkerSnapshot] {
        let others = team.active.filter { $0.id != team.selection }
        return others + team.active.filter { $0.id == team.selection }
    }

    // MARK: Helpers

    private static func composer(in view: NSView) -> ComposerScrollView? {
        find(ComposerScrollView.self, in: view)
    }

    private static func frame(of view: NSView) -> CGRect {
        view.convert(
            view.bounds,
            to: nil
        )
    }

    /// Where the composer's field starts and how tall it is; its width gives way to the worker's model.
    private static func place(of field: NSView) -> [CGFloat] {
        let frame = frame(of: field)
        return [frame.minX, frame.minY, frame.height]
    }

    private static func stills(in view: NSView) -> [HouseTranscriptStill.StillView] {
        all(HouseTranscriptStill.StillView.self, in: view)
    }

    private static func leavingPortraits(in view: NSView) -> [HouseWorkerPortrait.HostView] {
        all(HouseWorkerPortrait.HostView.self, in: view).filter { $0.layer?.opacity == 0 }
    }

    /// The window-space frame of the transcript's view.
    private static func transcriptFrame(in view: NSView) -> CGRect? {
        find(TranscriptCollectionView.self, in: view)?.enclosingScrollView?.superview.map(frame(of:))
    }

    /// The opacity `view` is drawn with: its own and every ancestor's, layer and view.
    private static func opacity(of view: NSView) -> CGFloat {
        var opacity: CGFloat = 1
        var current: NSView? = view
        while let shown = current {
            opacity *= shown.alphaValue * CGFloat(shown.layer?.opacity ?? 1)
            current = shown.superview
        }
        return opacity
    }

    /// The window-space frames of the toolbar's items.
    private static func toolbarFrames(in window: NSWindow) -> [CGRect] {
        guard let chrome = window.contentView?.superview else { return [] }
        return all(NSView.self, in: chrome)
            .filter { String(describing: type(of: $0)).contains("ToolbarItemViewer") }
            .map(frame(of:))
    }

    private static func find<V: NSView>(
        _ type : V.Type,
        in view: NSView
    ) -> V? {
        if let found = view as? V { return found }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    private static func all<V: NSView>(
        _ type : V.Type,
        in view: NSView
    ) -> [V] {
        ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
