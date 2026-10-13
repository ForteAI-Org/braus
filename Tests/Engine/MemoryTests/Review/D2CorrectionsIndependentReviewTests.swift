import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

private actor UnreadableProjection: BrainReading {
    struct Failure: Error {}
    func brain(of bundleID: String) async throws -> UIBrain? { throw Failure() }
    func projection(of bundleID: String, for detections: [BrainDetection]) async throws -> UIBrain? { throw Failure() }
}

@Suite("Independent D2 corrections: honest degradation and prefix bindings")
struct D2CorrectionsIndependentReviewTests {
    @Test("a failed projection read must not claim that learned relations are absent while still displaying them")
    func projectionFailureDoesNotDeliverContradictoryStatus() async throws {
        let element = SceneElement(id: "export", kind: .control, label: "Export", bounds: Fixtures.rect(0.1, 0.1, 0.1, 0.1),
                                   role: "AXButton", labelOrigin: .title)
        let capture = try #require(CaptureElement(element))
        let elementKey = try #require(SceneElementKey.key(of: capture))
        let key = BrainRelationKey(bundleID: "com.example.Review", contextID: nil, fromSceneID: "S", elementKey: elementKey,
                                   verb: .click, argumentsKey: "", toSceneID: "S", outcome: .effect, effectKind: "menuOpened")
        let relations = RelationsDouble(state: "S")
        await relations.set([BrainRelation(relationID: key.relationID, key: key, firstSeenMS: 0, lastSeenMS: 1,
                                           supports: 2, contradictions: 0)])
        let store = InMemoryBrainStore()
        let memory = BrainMemory(brains: UnreadableProjection(), applications: store, relations: relations, clock: { Fixtures.t0 })
        let scene = SceneSnapshot(bundleID: "com.example.Review", appName: "Review", windowTitle: "Document",
                                  viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: [element])
        let enriched = await memory.enrich(scene, state: "S")
        #expect(enriched.knowledge?.status == .unavailable)
        #expect(enriched.token == scene.token)
        #expect(enriched.elements.first?.does == nil,
                "unavailable says learned knowledge is not shown, but the element still carries \(enriched.elements.first?.does ?? "nil")")
    }

    private func parameter(_ id: String) -> RouteParameter {
        RouteParameter(parameterID: id, name: id, direction: .input, valueType: .text, isRequired: true)
    }

    private func step(_ position: Int, parameter id: String) -> ProcedureStep {
        ProcedureStep(stepID: "step-\(position)", position: position, goalText: "Enter text", bundleID: "com.example.Review",
                      operations: [StepOperation(operationID: "op-\(position)", position: 0, tool: .typeText,
                         arguments: [OperationArgument(name: "target", position: 0, value: .literal(.text(position == 0 ? "Name" : "Destination"))),
                                     OperationArgument(name: "text", position: 0, value: .parameter(id)),
                                     OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true)))])])
    }

    @Test("a prefix sharing one parameter across two steps is not proven equivalent to two independently supplied parameters")
    func prefixPreservesParameterCorrelations() throws {
        let original = RouteDefinition(routeID: "original", name: "Enter the same file twice", createdAtMS: 1,
                                       parameters: [parameter("file")], steps: [step(0, parameter: "file"), step(1, parameter: "file")])
        let variant = RouteDefinition(routeID: "variant", name: "Enter two files", createdAtMS: 2,
                                      parameters: [parameter("input"), parameter("output")],
                                      steps: [step(0, parameter: "input"), step(1, parameter: "output")])
        let check = try VariantPrefix.check(variant: variant, of: original, divergence: 2)
        #expect(check.status != .verified, "same scalar type alone loses the shared binding across the prefix")
    }
}
