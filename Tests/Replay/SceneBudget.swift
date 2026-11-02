import Foundation
import LocalMCP
import PerceptionCore

enum SceneBudget {
    static func depths(_ deliveries: [SceneDelivery]) throws -> [Int] {
        var seen: [Int: (SceneDelivery, Int)] = [:]
        var previous = 0
        return try deliveries.map { delivery in
            guard delivery.revision > previous else { throw ReplayFailure("Revisions must increase from one") }
            previous = delivery.revision
            let depth: Int
            if let since = delivery.since {
                guard let (reference, referenceDepth) = seen[since], delivery.session != nil,
                      reference.session == delivery.session, reference.windowKey == delivery.windowKey else {
                    throw ReplayFailure("Invalid reference at revision \(delivery.revision)")
                }
                depth = referenceDepth + 1
            } else { depth = 0 }
            seen[delivery.revision] = (delivery, depth)
            return depth
        }
    }

    static func exceeds(_ total: Int, saved: Int) -> Bool {
        // Division avoids overflow while retaining the exact integer threshold.
        guard total > saved else { return false }
        return total - saved > (saved / 100) * 3 + ((saved % 100) * 3) / 100
    }

    static func historical(_ item: ReplayCase) throws -> Set<String>? {
        guard let deliveries = item.deliveries, let saved = item.savedSceneCharacters else { return nil }
        var violations = try Set(depths(deliveries).filter { $0 > 2 }.map { _ in "depth" })
        let total = try rendered(deliveries).reduce(0) { $0 + $1.count }
        if exceeds(total, saved: saved) { violations.insert("sceneBudget") }
        return violations
    }

    static func rendered(_ deliveries: [SceneDelivery]) throws -> [String] {
        _ = try depths(deliveries)
        var scenes: [Int: SceneSnapshot] = [:]
        return try deliveries.map { delivery in
            defer { scenes[delivery.revision] = delivery.scene }
            if let since = delivery.since {
                guard let before = scenes[since] else { throw ReplayFailure("Missing scene reference") }
                return SceneChanges.text(from: before, to: delivery.scene, since: since)
            }
            return delivery.scene.text()
        }
    }

    static func regenerated(_ trace: [JSONValue], item: ReplayCase) throws -> Set<String>? {
        guard let saved = item.savedSceneCharacters, let historical = item.deliveries else { return nil }
        let observations = trace.compactMap { $0["observation"].object }
        guard observations.count == historical.count else { throw ReplayFailure("\(item.id): trace delivery count differs") }
        var deliveries: [SceneDelivery] = []
        for (observation, original) in zip(observations, historical) {
            func integer(_ key: String) throws -> Int? {
                guard let value = observation[key] else { return nil }
                guard case .number(let number) = value, number.isFinite, number >= 1, number < Double(Int.max),
                      number.rounded() == number else { throw ReplayFailure("Invalid \(key)") }
                return Int(number)
            }
            guard let revision = try integer("revision") else { throw ReplayFailure("Missing revision") }
            let full = observation["scene"]?.string
            let changes = observation["changes"]?.string
            let since = try integer("since")
            guard (full != nil) != (changes != nil), (since != nil) == (changes != nil),
                  let text = full ?? changes else { throw ReplayFailure("Invalid scene delivery") }
            deliveries.append(SceneDelivery(revision: revision, session: original.session,
                                            windowKey: original.windowKey, since: since,
                                            scene: original.scene, savedText: text))
        }
        var violations: Set<String> = []
        if try depths(deliveries).contains(where: { $0 > 2 }) { violations.insert("depth") }
        if exceeds(deliveries.reduce(0) { $0 + $1.savedText.count }, saved: saved) { violations.insert("sceneBudget") }
        return violations
    }
}
