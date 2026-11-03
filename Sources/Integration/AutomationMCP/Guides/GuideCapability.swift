import Capabilities
import AutomationRuntime
import LocalMCP

/// GuideCapability delivers a compatible guide without opening an application or acquiring a session.
/// The facade supplies current todo and its platform resolver when the requested arm is composed.
public nonisolated struct GuideCapability: CapabilityProviding {
    public enum Failure: Error, Sendable, Equatable { case invalidArguments, unavailable, unknownSection }
    public let family = "guides"
    private let guides: AppGuides
    private let resolve: @MainActor @Sendable (String) -> OpenedApp
    private let todo: @MainActor @Sendable () -> [String]

    public init(guides: AppGuides, resolve: @escaping @MainActor @Sendable (String) -> OpenedApp,
                todo: @escaping @MainActor @Sendable () -> [String]) {
        self.guides = guides
        self.resolve = resolve
        self.todo = todo
    }

    public var contracts: [CapabilityContract] {
        [CapabilityContract(id: .init(rawValue: "read_guide"), group: ModelText.groupName(.guides),
            description: ModelText.text(.init(rawValue: "guide.description")),
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string")]),
                    "sections": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                        "minItems": .number(0), "maxItems": .number(3), "uniqueItems": .bool(true)])]),
                "required": .array([.string("app")]), "additionalProperties": .bool(false)]),
            effect: .read, interruption: .readOnly, verification: .none(reason: "read only"),
            channel: .braus, origin: .core, memory: .notRecorded(reason: "guide delivery"),
            takesSession: false, parallelSafe: false)]
    }

    public func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
        do {
            return try await requested(id, arguments: arguments)
        } catch Failure.invalidArguments {
            throw AutomationFailure(ModelText.text(.init(rawValue: "guide.invalidArguments")), cause: "invalid_arguments")
        }
    }

    private func requested(_ id: CapabilityID, arguments: JSONValue) async throws -> JSONValue {
        guard id.rawValue == "read_guide", let object = arguments.object,
              Set(object.keys).isSubset(of: ["app", "sections"]),
              let app = object["app"]?.string, !app.isEmpty else { throw Failure.invalidArguments }
        let titles: [String]?
        if let value = object["sections"] {
            guard let array = value.array, array.count <= 3,
                  array.allSatisfy({ $0.string != nil }) else { throw Failure.invalidArguments }
            let strings = array.compactMap(\.string)
            guard Set(strings).count == strings.count else { throw Failure.invalidArguments }
            titles = strings
        } else { titles = nil }
        let opened = await resolve(app)
        do {
            guard opened.bundleID == app else { throw Failure.unavailable }
            let head = try await guides.requested(for: opened, titles: titles, todo: todo())
            return .string(await ResultFormatter.guideText(head: head, index: nil, surface: ToolCatalogue.currentSurface))
        } catch Failure.unknownSection {
            return .string(ModelText.text(.init(rawValue: "guide.unknownSection"))
                + "\n" + (await guides.availableSections(for: opened)))
        } catch Failure.unavailable {
            return .string(ModelText.text(.init(rawValue: "guide.unavailable")))
        }
    }
}

extension AppGuides {
    public func capability(resolve: @escaping @MainActor @Sendable (String) -> OpenedApp,
                           todo: @escaping @MainActor @Sendable () -> [String]) -> GuideCapability? {
        guard arm == .requested else { return nil }
        return GuideCapability(guides: self, resolve: resolve, todo: todo)
    }
}
