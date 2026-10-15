//
//  SceneStructureMatcherTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Memory
import PerceptionCore
import Testing

/// Structure-v4 on synthetic skeletons: the three comparisons and the four decisions, and the
/// skeleton's own exclusions. The fixtures through the producer live with the SQLite suite.
@Suite("The structure-v4 matcher")
struct SceneStructureMatcherTests {

    private typealias Caption = SceneSkeleton.Caption

    private func skeleton(
        _ surface  : CaptureSurface = .window,
        roles      : [String: Set<String>] = ["": ["AXButton"]],
        captions   : [String: Set<Caption>] = ["": [Caption(role: "AXButton", label: "OK")]],
        collections: Set<String> = []
    ) -> SceneSkeleton {
        SceneSkeleton(surface: surface, rolesByPath: roles, captionsByPath: captions, collections: collections)
    }

    @Test("same needs a complete capture, known equal surfaces and equal paths, roles, captions and collections")
    func same() {
        let known = skeleton()
        #expect(SceneStructureMatcher.compare(observed: skeleton(), isComplete: true, known: known) == .same)
        #expect(SceneStructureMatcher.compare(observed: skeleton(), isComplete: false, known: known) == .uncertain(.incompleteCapture))
        #expect(SceneStructureMatcher.compare(observed: skeleton(.unknown), isComplete: true, known: known) == .uncertain(.surfaceUnknown))
    }

    @Test("different needs proof: a role missing on either side, two known surfaces that differ, or a complete capture's other paths, captions or collections")
    func different() {
        let known = skeleton()
        #expect(SceneStructureMatcher.compare(observed: skeleton(roles: ["": ["AXButton", "AXTextField"]]), isComplete: true, known: known) == .different(.roles))
        #expect(SceneStructureMatcher.compare(observed: skeleton(roles: ["": ["AXTextField"]], captions: [:]), isComplete: true, known: known) == .different(.roles))
        #expect(SceneStructureMatcher.compare(observed: skeleton(.dialog), isComplete: true, known: known) == .different(.surface))
        #expect(SceneStructureMatcher.compare(observed: skeleton(.unknown, roles: ["": ["AXSlider"]], captions: [:]), isComplete: true, known: known) == .different(.roles),
                "a role difference is proof even when the surface is unknown")
        #expect(SceneStructureMatcher.compare(observed: skeleton(roles: ["": ["AXButton", "AXTextField"]]), isComplete: false, known: known) == .uncertain(.incompleteCapture),
                "an incomplete capture proves nothing, in either direction")
    }

    @Test("a complete capture's own structure is proof: other captions, other paths, other collections are another state (v3 called them uncertain)")
    func structureIsProof() {
        let known = skeleton()
        #expect(SceneStructureMatcher.compare(observed: skeleton(captions: ["": [Caption(role: "AXButton", label: "Cancel")]]), isComplete: true, known: known) == .different(.captions))
        #expect(SceneStructureMatcher.compare(observed: skeleton(roles: ["Panel": ["AXButton"]], captions: ["Panel": [Caption(role: "AXButton", label: "OK")]]), isComplete: true, known: known) == .different(.paths))
        #expect(SceneStructureMatcher.compare(observed: skeleton(collections: ["People"]), isComplete: true, known: known) == .different(.collections))
        #expect(SceneStructureMatcher.compare(observed: skeleton(captions: ["": [Caption(role: "AXButton", label: "Cancel")]]), isComplete: false, known: known) == .uncertain(.incompleteCapture),
                "an incomplete capture still proves nothing")
    }

    @Test("a display ordinal is no caption: the same dialog with the twin label on the other unit is the same scene (v5)")
    func ordinalsAreNotStructure() {
        let known = skeleton(roles: ["": ["AXRadioButton"]], captions: ["": [
            Caption(role: "AXRadioButton", label: "Centimetri"), Caption(role: "AXRadioButton", label: "Pollici #2"),
            Caption(role: "AXRadioButton", label: "Pollici")]])
        let other = skeleton(roles: ["": ["AXRadioButton"]], captions: ["": [
            Caption(role: "AXRadioButton", label: "Centimetri #2"), Caption(role: "AXRadioButton", label: "Centimetri"),
            Caption(role: "AXRadioButton", label: "Pollici")]])
        #expect(SceneStructureMatcher.compare(observed: other, isComplete: true, known: known) == .same)
        #expect(Caption(role: "AXButton", label: "Version #12").label == Caption(role: "AXButton", label: "Version").label)
        #expect(Caption(role: "AXButton", label: "Track #A").label != Caption(role: "AXButton", label: "Track").label,
                "only digits after the mark are an ordinal")
    }

    @Test("the decision confirms only one same and no uncertain, lists candidates otherwise, and creates a scene only when every known scene is different and the capture allows it")
    func decisions() {
        let a = (id: "a", skeleton: skeleton())
        let b = (id: "b", skeleton: skeleton(captions: ["": [Caption(role: "AXButton", label: "Cancel")]]))
        let c = (id: "c", skeleton: skeleton(.dialog, roles: ["": ["AXSlider"]], captions: [:]))
        func decide(_ observed: SceneSkeleton, complete: Bool = true, phase: CapturePhase = .current, among: [(id: String, skeleton: SceneSkeleton)]) -> SceneStructureMatcher.Decision {
            SceneStructureMatcher.decide(observed: observed, isComplete: complete, phase: phase, among: among)
        }
        #expect(decide(skeleton(), among: [a, c]) == .confirmed(sceneID: "a"))
        #expect(decide(skeleton(), among: [a, b]) == .confirmed(sceneID: "a"), "a scene of other captions is another state, no twin")
        #expect(decide(skeleton(.unknown), among: [a, b]) == .candidates(["a", "b"]), "an unknown surface is uncertain against both")
        #expect(decide(skeleton(captions: ["": [Caption(role: "AXButton", label: "Save")]]), among: [a, b]) == .newScene,
                "a dialog drawn in the window adds its own captions: a new state")
        #expect(decide(skeleton(), among: [a, a]) == .candidates(["a", "a"]), "two same are not one confirmation")
        #expect(decide(skeleton(), complete: false, among: [a, c]) == .candidates(["a", "c"]), "a partial capture is uncertain against everything")
        #expect(decide(skeleton(), among: [c]) == .newScene)
        #expect(decide(skeleton(), among: []) == .newScene)
        #expect(decide(skeleton(), complete: false, among: []) == .none(.incompleteCapture))
        #expect(decide(skeleton(.unknown), among: []) == .none(.surfaceUnknown))
        #expect(decide(skeleton(.popupUnion), among: [a]) == .none(.popupUnion))
        #expect(decide(skeleton(), phase: .menu, among: [a]) == .none(.menuPhase))
        #expect(decide(skeleton(roles: [:], captions: [:]), among: []) == .none(.emptySkeleton))
        #expect(decide(skeleton(.sheet, roles: ["": ["AXButton"]], captions: [:]), among: []) == .newScene, "one control on a known surface is enough")
    }

    @Test("a skeleton excludes rows, cells, static text, images and everything inside a collection, and takes captions only from titles and descriptions")
    func skeletonRules() {
        func element(_ role: String, _ label: String, origin: LabelOrigin?, path: String = "", collection: Bool = false) -> CaptureElement {
            CaptureElement(kind: .control, role: role, label: label, labelOrigin: origin, containerPath: path,
                           isUnderCollection: collection, state: nil, bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))
        }
        let skeleton = SceneSkeleton(surface: .window, elements: [
            element("AXRow", "Alice", origin: .rowContent, path: "People", collection: true),
            element("AXButton", "Reply", origin: .title, path: "People", collection: true),
            element("AXStaticText", "Hello", origin: .value),
            element("AXButton", "Compose", origin: .title),
            element("AXButton", "7", origin: .value),
            element("AXCheckBox", "Track", origin: .description, path: "Options"),
            element("AXTextField", "Mario", origin: .value, path: "Options"),
            element("AXImage", "avatar", origin: .description),
        ])
        #expect(skeleton.collections == ["People"])
        #expect(skeleton.rolesByPath == ["": ["AXButton"], "Options": ["AXCheckBox", "AXTextField"]])
        #expect(skeleton.captionsByPath == ["": [Caption(role: "AXButton", label: "compose")], "Options": [Caption(role: "AXCheckBox", label: "track")]])
        #expect(skeleton.roles == ["AXButton", "AXCheckBox", "AXTextField"])
        #expect(!skeleton.isEmpty)
        #expect(SceneSkeleton(surface: .window, elements: []).isEmpty)
        let reordered = SceneSkeleton(surface: .window, elements: [
            element("AXTextField", "Luigi", origin: .value, path: "Options"),
            element("AXCheckBox", "TRACK", origin: .title, path: "Options"),
            element("AXButton", "Compose", origin: .description),
            element("AXButton", "Carla", origin: .rowContent, path: "People", collection: true),
        ])
        #expect(reordered == skeleton, "order, case, content and origin within the caption origins do not change the skeleton")
        #expect(reordered.structuralKey == skeleton.structuralKey)
        #expect(SceneSkeleton(surface: .dialog, elements: []).structuralKey != SceneSkeleton(surface: .window, elements: []).structuralKey)
    }

    @Test("a caption that names a file is content: a document's tab is the same control whatever the document")
    func fileNamesAreContent() {
        for label in ["foto_3.png @ 100% (RGB/8)*", "Report.pdf", "Aperto: foto_4.png", "archive.tar.gz"] {
            #expect(SceneSkeleton.isContentCaption(label), "\(label)")
        }
        for label in ["Apri…     ⌘O", "Nuovo documento…", "v1.2", "Livelli #2", "100%", "Save", "Mr. Smith", ".png"] {
            #expect(!SceneSkeleton.isContentCaption(label), "\(label)")
        }
        func tab(_ label: String) -> CaptureElement {
            CaptureElement(kind: .control, role: "AXCheckBox", label: label, labelOrigin: .title, containerPath: "content",
                           isUnderCollection: false, state: nil, bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))
        }
        let close = CaptureElement(kind: .control, role: "AXButton", label: "Chiudi", labelOrigin: .title, containerPath: "content",
                                   isUnderCollection: false, state: nil, bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))
        let one = SceneSkeleton(surface: .window, elements: [close, tab("foto_3.png @ 100% (RGB/8)")])
        let other = SceneSkeleton(surface: .window, elements: [close, tab("foto_4.png @ 100% (Gray/8)*")])
        #expect(one == other)
        #expect(one.captions == [Caption(role: "AXButton", label: "Chiudi")])
        #expect(one.rolesByPath == ["content": ["AXButton", "AXCheckBox"]], "the control stays in the structure; only its label is content")
        #expect(SceneStructureMatcher.compare(observed: other, isComplete: true, known: one) == .same)
        #expect(SceneElementKey.caption(of: tab("foto_3.png @ 100% (RGB/8)")) == "")
    }
}
