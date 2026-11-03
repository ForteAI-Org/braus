import EngineCore
import Foundation
import PerceptionCore
import Testing

struct ReplayCase: Decodable, Sendable, CustomTestStringConvertible {
    let schemaVersion: Int
    let id: String
    let tool: String
    let answer: String
    let before: SceneSnapshot?
    let after: SceneSnapshot?
    let savedSceneCharacters: Int?
    let deliveries: [SceneDelivery]?
    let input: ReplayInput?

    var testDescription: String { id }
    var hasSceneMeasurements: Bool { savedSceneCharacters != nil && deliveries != nil }

    func validate() throws {
        guard schemaVersion == 1 else { throw ReplayFailure("\(id): unsupported schema \(schemaVersion)") }
        if let savedSceneCharacters, savedSceneCharacters < 0 {
            throw ReplayFailure("\(id): negative saved total")
        }
        if let deliveries {
            _ = try SceneBudget.depths(deliveries)
            if let savedSceneCharacters,
               savedSceneCharacters != deliveries.reduce(0, { $0 + $1.savedText.count }) {
                throw ReplayFailure("\(id): saved character total differs")
            }
        }
        if let input {
            let outcomes = input.prefix + [input.outcome]
            for outcome in outcomes { _ = try outcome.converted() }
            if let deliveries {
                let scenes = outcomes.filter { $0.scene != nil }
                guard scenes.count == deliveries.count else { throw ReplayFailure("\(id): delivery count differs") }
                var windows: [String: String] = [:]
                var keys: [String: String] = [:]
                for (outcome, delivery) in zip(scenes, deliveries) {
                    guard delivery.session == input.session, delivery.scene == outcome.scene else {
                        throw ReplayFailure("\(id): delivery scene or session differs")
                    }
                    let number = outcome.windowNumber.map(String.init) ?? "nil"
                    if let key = windows[number], key != delivery.windowKey {
                        throw ReplayFailure("\(id): window has multiple keys")
                    }
                    if let previous = keys[delivery.windowKey], previous != number {
                        throw ReplayFailure("\(id): key has multiple windows")
                    }
                    windows[number] = delivery.windowKey
                    keys[delivery.windowKey] = number
                }
                if scenes.contains(where: { $0.windowNumber == nil }), keys.count > 1 {
                    throw ReplayFailure("\(id): unknown window requires one key")
                }
            }
        }
    }
}

struct ReplayInput: Decodable, Sendable {
    let kind: ActOutcomeKind
    let message: String
    let scene: SceneSnapshot?
    let check: ReplayCheck?
    let session: UUID?
    let windowNumber: Int?
    let prefix: [ReplayOutcome]

    var outcome: ReplayOutcome {
        ReplayOutcome(kind: kind, message: message, scene: scene, check: check, windowNumber: windowNumber)
    }
}

struct ReplayOutcome: Decodable, Sendable {
    let kind: ActOutcomeKind
    let message: String
    let scene: SceneSnapshot?
    let check: ReplayCheck?
    let windowNumber: Int?

    func converted() throws -> ActOutcome {
        ActOutcome(kind, message, scene: scene, check: try check?.converted())
    }
}

struct ReplayCheck: Decodable, Sendable {
    let condition: String
    let method: String
    let methodVersion: String
    let verdict: String
    let expected: String?
    let observed: String?
    let limits: [String]
    let performed: String
    let substitute: String?
    let target: ReplayTarget?

    func converted() throws -> OperationCheck {
        func value<T: RawRepresentable>(_ text: String, as type: T.Type) throws -> T where T.RawValue == String {
            guard let value = T(rawValue: text) else { throw ReplayFailure("Unknown \(type): \(text)") }
            return value
        }
        return try OperationCheck(
            condition: value(condition, as: OperationCheck.Condition.self),
            method: value(method, as: OperationCheck.Method.self),
            methodVersion: methodVersion,
            verdict: value(verdict, as: OperationCheck.Verdict.self),
            expected: expected,
            observed: observed,
            limits: limits.map { try value($0, as: OperationCheck.Limit.self) },
            performed: value(performed, as: OperationCheck.Performed.self),
            substitute: substitute,
            target: target.map { .init(elementID: $0.elementID, role: $0.role, label: $0.label, section: $0.section) }
        )
    }
}

struct ReplayTarget: Decodable, Sendable {
    let elementID: String
    let role: String?
    let label: String
    let section: String?
}

struct SceneDelivery: Decodable, Sendable {
    let revision: Int
    let session: UUID?
    let windowKey: String
    let since: Int?
    let scene: SceneSnapshot
    let savedText: String
}

struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum ReplayCorpus {
    static var fixtures: URL { Bundle.module.resourceURL!.appending(path: "Fixtures") }

    static func load() throws -> [ReplayCase] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: fixtures.appending(path: "cases"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { throw ReplayFailure("Empty corpus") }
        var ids: Set<String> = []
        return try urls.map { url in
            do {
                let item = try JSONDecoder().decode(ReplayCase.self, from: Data(contentsOf: url))
                guard item.id == url.deletingPathExtension().lastPathComponent, ids.insert(item.id).inserted else {
                    throw ReplayFailure("Invalid or duplicate case id: \(item.id)")
                }
                try item.validate()
                return item
            } catch { throw ReplayFailure("\(url.lastPathComponent): \(error)") }
        }
    }
}
