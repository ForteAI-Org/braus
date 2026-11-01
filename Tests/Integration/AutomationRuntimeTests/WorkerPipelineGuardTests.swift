import Foundation
import Testing

/// Static source checks complement the reader and harvest tests; they do not run native perception.
struct WorkerPipelineGuardTests {
    private static let sites: [(String, String, String)] = [
        ("Integration/AutomationRuntime/EngineRuntime.swift", "public init(knowledgeDirectory:",
         "ProductionPerception.workerPipeline(timingHook:"),
        ("Integration/AutomationRuntime/EngineRuntime.swift", "public init(knowledgeDirectory:",
         "ProductionPerception.foregroundScenes(valueGuard:ProductionPerception.workerValueGuard)"),
        ("SeatBroker/Runtime/BrokeredAutomationSession.swift", "private func deliver(_ input:",
         "SeatContextMenuSelector(target:seat,pipeline:ProductionPerception.workerPipeline())"),
        ("SeatBroker/Runtime/BrokeredAutomationSession.swift", "package func select(",
         "SeatDropdownSelector(target:target,pipeline:ProductionPerception.workerPipeline(),windows:runtime.windows)"),
        ("SeatBroker/Public/SeatBroker.swift", "private let perception = ScenePipeline(",
         "valueGuard:ProductionPerception.workerValueGuard"),
        ("Integration/AutomationRuntime/ProductionPerception.swift", "static func workerPipeline(",
         "pipeline(mode:mode,valueGuard:workerValueGuard,timingHook:timingHook)"),
        ("Integration/AutomationRuntime/ProductionPerception.swift", "static func foregroundScenes(",
         "pipeline: pipeline(valueGuard:valueGuard)"),
        ("Integration/AutomationRuntime/ProductionPerception.swift", "static func pipeline(",
         "valueGuard:valueGuard"),
        ("Perception/AccessibilityFacts/AccessibilityAugmenter.swift", "private func read(",
         "valueGuard:valueGuard")
    ]

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + path), encoding: .utf8)
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/|//[^\n]*"#, with: "", options: .regularExpression)
    }

    private func body(_ source: String, anchor: String) throws -> String {
        let start = try #require(source.range(of: anchor))
        // These methods have closure defaults; the body starts after the declaration's final line.
        let tail = source[start.upperBound...]
        let opening: String.Index
        if anchor == "package func select(" {
            opening = try #require(tail.range(of: "receipt: PopupMenuReceipt?) {")).upperBound
        } else if anchor == "private let perception = ScenePipeline(" {
            return String(tail.prefix(while: { $0 != ";" }).components(separatedBy: "private let recorder")[0])
        } else {
            opening = source.index(after: try #require(tail.firstIndex(of: "{")))
        }
        var depth = 1
        var end = opening
        while end < source.endIndex && depth > 0 {
            if source[end] == "{" { depth += 1 }
            if source[end] == "}" { depth -= 1 }
            if depth > 0 { end = source.index(after: end) }
        }
        return String(source[opening..<end])
    }

    @Test(arguments: Array(Self.sites.indices))
    func everyWorkerEntryForwardsTheGuard(index: Int) throws {
        let (path, anchor, expected) = Self.sites[index]
        let scope = try body(source(path), anchor: anchor).filter { !$0.isWhitespace }
        let required = expected.filter { !$0.isWhitespace }
        #expect(scope.contains(required), "Missing guarded connection in \(path): \(anchor)")
        if required.contains("workerPipeline(") {
            let mutation = scope.replacingOccurrences(of: "workerPipeline(", with: "pipeline(")
            #expect(!mutation.contains(required))
        } else {
            for replacement in ["", "valueGuard:nil"] {
                let mutation = scope.replacingOccurrences(
                    of: #"valueGuard:(?:ProductionPerception\.)?(?:workerValueGuard|valueGuard)"#,
                    with: replacement,
                    options: .regularExpression
                )
                #expect(!mutation.contains(required))
            }
        }
    }
}
