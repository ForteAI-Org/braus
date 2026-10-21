//
//  HouseInspectorFoldTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI
import Testing
@testable import Braus

@Suite("HouseInspectorFold")
@MainActor
struct HouseInspectorFoldTests {

    @Test("Screen is the inspector's first section when it shows, and the order holds otherwise")
    func screenFirst() {
        #expect(HouseInspector.parts(
            showsScreen: true,
            isBusy     : true
        ) == [.screen, .worker, .now, .model, .web, .turn])
        #expect(HouseInspector.parts(
            showsScreen: true,
            isBusy     : false
        ) == [.worker, .now, .model, .web, .turn])
        #expect(HouseInspector.parts(
            showsScreen: false,
            isBusy     : true
        ) == [.worker, .now, .model, .web, .turn])
    }

    @Test("A press on the header folds the section and opens it again")
    func headerFolds() {
        var isExpanded = true
        let binding    = Binding(
            get: { isExpanded },
            set: { isExpanded = $0 }
        )
        HouseFoldableSection<EmptyView>.fold(binding)
        #expect(!isExpanded)
        HouseFoldableSection<EmptyView>.fold(binding)
        #expect(isExpanded)
        #expect(String(reflecting: HouseFoldableSection<EmptyView>.Body.self).contains("Fold"))
        #expect(!String(reflecting: HouseInspector.Body.self).contains("Form<"))
    }

    @Test("A fold shrinks the box into its title and an unfold grows it back, with no step and no overshoot")
    func foldAnimates() throws {
        RestylingMotion.overrideReducesMotion = false
        defer { RestylingMotion.overrideReducesMotion = nil }
        let probe          = FoldProbe()
        let (window, view) = Self.host(probe)
        defer { window.close() }
        let open = try #require(probe.section)

        let folding = Self.samples(of: probe)
        let folded = try #require(folding.last)
        #expect(folded.height == HouseInspectorMetrics.headerHeight)
        // Each sample is at most as tall as the one before, and some fall between the two ends.
        #expect(zip(folding, folding.dropFirst()).allSatisfy { $1.height <= $0.height + 0.01 })
        #expect(folding.filter { $0.height > folded.height + 1 && $0.height < open.height - 1 }.count >= 3)
        Self.expectSteady(folding, from: open)

        let unfolding = Self.samples(of: probe)
        #expect(unfolding.last?.height == open.height)
        #expect(zip(unfolding, unfolding.dropFirst()).allSatisfy { $1.height >= $0.height - 0.01 })
        #expect(unfolding.filter { $0.height > folded.height + 1 && $0.height < open.height - 1 }.count >= 3)
        Self.expectSteady(unfolding, from: open)
        _ = view
    }

    @Test("Under Reduce Motion a fold is a cut")
    func foldCutsUnderReduceMotion() throws {
        RestylingMotion.overrideReducesMotion = true
        defer { RestylingMotion.overrideReducesMotion = nil }
        let probe          = FoldProbe()
        let (window, view) = Self.host(probe)
        defer { window.close() }
        let open = try #require(probe.section)

        for expected in [HouseInspectorMetrics.headerHeight, open.height] {
            let samples = Self.samples(of: probe)
            #expect(samples.allSatisfy { $0.height == expected })
            Self.expectSteady(samples, from: open)
        }
        _ = view
    }

    // MARK: Fold probe

    /// Frame is where the folding section stood in one sample, and the top of the section below it.
    struct Frame: Equatable {
        var top     : CGFloat
        var height  : CGFloat
        var belowTop: CGFloat
    }

    /// FoldProbe holds the folding section's state and the last frame its host laid out.
    @Observable
    final class FoldProbe {
        var isExpanded = true
        var top       : CGFloat?
        var height    : CGFloat?
        var belowTop  : CGFloat?

        var section: Frame? {
            guard let top, let height, let belowTop else { return nil }

            return Frame(
                top     : top,
                height  : height,
                belowTop: belowTop
            )
        }
    }

    /// FoldHost is a section above, the folding one, and one below, spaced as the inspector spaces them.
    private struct FoldHost: View {
        @Bindable var probe: FoldProbe

        var body: some View {
            VStack(
                alignment: .leading,
                spacing  : HouseInspectorMetrics.sectionSpacing
            ) {
                HouseFoldableSection(
                    title     : "Above",
                    isExpanded: .constant(true)
                ) {
                    LabeledContent(
                        "Kept",
                        value: "Open"
                    )
                }
                HouseFoldableSection(
                    title     : "Folding",
                    isExpanded: $probe.isExpanded
                ) {
                    LabeledContent(
                        "First",
                        value: "One"
                    )
                    LabeledContent(
                        "Second",
                        value: "Two"
                    )
                    LabeledContent(
                        "Third",
                        value: "Three"
                    )
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("host")) } action: { frame in
                    probe.top    = frame.minY
                    probe.height = frame.height
                }
                Color.clear
                    .frame(height: 10)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("host")).minY } action: { top in
                        probe.belowTop = top
                    }
            }
            .padding(HouseInspectorMetrics.edgeInset)
            .frame(
                width    : 360,
                height   : 600,
                alignment: .top
            )
            .coordinateSpace(.named("host"))
        }
    }

    private static func host(_ probe: FoldProbe) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: CGRect(
                x     : -6000,
                y     : -6000,
                width : 360,
                height: 600
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: FoldHost(probe: probe))
        view.frame         = CGRect(
            x     : 0,
            y     : 0,
            width : 360,
            height: 600
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (window, view)
    }

    /// Toggles the folding section as its header does, then samples its frame every few
    /// milliseconds until the fold has ended.
    private static func samples(of probe: FoldProbe) -> [Frame] {
        HouseFoldableSection<EmptyView>.fold(Binding(
            get: { probe.isExpanded },
            set: { probe.isExpanded = $0 }
        ))
        var frames: [Frame] = []
        let end = Date().addingTimeInterval(HouseChevronView.duration + 0.25)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            if let frame = probe.section { frames.append(frame) }
        }
        return frames
    }

    /// The title stays where it stood, and the section below follows the box's bottom edge at
    /// the inspector's spacing in every sample, so nothing around the fold jumps.
    private static func expectSteady(
        _ frames: [Frame],
        from open: Frame
    ) {
        #expect(!frames.isEmpty)
        for frame in frames {
            #expect(abs(frame.top - open.top) < 0.01)
            #expect(abs(frame.belowTop - (frame.top + frame.height + HouseInspectorMetrics.sectionSpacing)) < 0.01)
        }
    }

    @Test("The chevron turns a quarter turn in Core Animation, and not at all under Reduce Motion")
    func chevronTurns() throws {
        let view = HouseChevronView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 12,
            height: 12
        ))
        view.setOpen(
            true,
            animated: true
        )
        let turn = try #require(view.glyph.animation(forKey: HouseChevronView.turnKey) as? CABasicAnimation)
        #expect(turn.keyPath == "transform.rotation.z")
        #expect(turn.toValue as? CGFloat == -.pi / 2)
        #expect(turn.duration == 0.25)
        #expect(view.isOpen)

        view.setOpen(
            false,
            animated: false
        )
        #expect(view.glyph.animation(forKey: HouseChevronView.turnKey) == nil)
        #expect(!view.isOpen)

        // Hosted in SwiftUI, a change of `isOpen` turns it, unless the person reduces motion.
        for reduces in [false, true] {
            RestylingMotion.overrideReducesMotion = reduces
            defer { RestylingMotion.overrideReducesMotion = nil }
            let hosted = NSHostingView(rootView: HouseChevron(
                isOpen      : false,
                isEmphasized: false
            ))
            hosted.frame = CGRect(
                x     : 0,
                y     : 0,
                width : 12,
                height: 12
            )
            hosted.layoutSubtreeIfNeeded()
            let chevron = try #require(Self.chevron(in: hosted))
            hosted.rootView = HouseChevron(
                isOpen      : true,
                isEmphasized: false
            )
            hosted.layoutSubtreeIfNeeded()
            #expect(chevron.isOpen)
            #expect((chevron.glyph.animation(forKey: HouseChevronView.turnKey) != nil) == !reduces)
        }
    }

    private static func chevron(in view: NSView) -> HouseChevronView? {
        if let chevron = view as? HouseChevronView { return chevron }

        return view.subviews.lazy.compactMap { chevron(in: $0) }.first
    }

    @Test("The folded sections stay as they were left, for each worker")
    func foldsPerWorker() {
        var disclosure = InspectorDisclosure()
        let first      = UUID()
        let second     = UUID()
        disclosure.setExpanded(
            false,
            .web,
            for: first
        )
        #expect(!disclosure.isExpanded(
            .web,
            for: first
        ))
        #expect(disclosure.isExpanded(
            .web,
            for: second
        ))
    }
}
