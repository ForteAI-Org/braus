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
        #expect(String(reflecting: HouseFoldableSection<EmptyView>.Body.self).contains("Section<"))
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
