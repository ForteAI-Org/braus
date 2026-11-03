import Capabilities
import EngineCore
import Foundation
import LocalMCP
import Memory
import SQLiteMemory

/// CapabilityCallRecorder confirms capability starts before effects and suspends memory on failed ends.
/// One immutable frame identifies each concurrent call; the recorder retains only its shared memory service.
public actor CapabilityCallRecorder: CapabilityRecording {
    public struct CallFrame: Sendable {
        public let context: ActionContext
        public let attribution: TaskCallAttribution?
        public let contract: CapabilityContract
        public let minimization: ValueMinimization

        public init(context: ActionContext, attribution: TaskCallAttribution?, contract: CapabilityContract,
                    minimization: ValueMinimization = .init()) {
            self.context = context
            self.attribution = attribution
            self.contract = contract
            self.minimization = minimization
        }
    }

    public enum Failure: Error, Sendable { case missingFrame }
    @TaskLocal public static var frame: CallFrame?
    private let memory: MemoryService

    public init(memory: MemoryService) { self.memory = memory }

    public func began(_ id: CapabilityID, arguments: JSONValue) async throws {
        guard let frame = Self.frame, frame.contract.id == id else { throw Failure.missingFrame }
        let opening = try Self.opening(frame, arguments: arguments, atMS: memory.clock.calendarMS())
        try await memory.confirm("capability \(id.rawValue) start", beforeEffect: frame.contract.effect != .read) {
            try await SQLiteCapabilityCallRows(store: $0.store).began(opening)
        }
    }

    public func ended(_ id: CapabilityID, result: JSONValue?, failure: String?, verified: Bool?) async throws {
        guard let frame = Self.frame, frame.contract.id == id else { throw Failure.missingFrame }
        let opening = try Self.opening(frame, arguments: .object([:]), atMS: memory.clock.calendarMS())
        let keptFailure = failure.map { frame.minimization.minimize(text: $0).0 }
        let method: String = switch frame.contract.verification {
        case .readBack: "readBack"
        case .engineVerdict: "engineVerdict"
        case .resultCheck: "resultCheck"
        case .none: "none"
        }
        let atMS = memory.clock.calendarMS()
        try await memory.confirm("capability \(id.rawValue) end", afterEffect: true) {
            let fields = try Self.fields(result ?? .null, minimization: frame.minimization)
            try await SQLiteCapabilityCallRows(store: $0.store).ended(opening, atMS: atMS, results: fields,
                failure: keptFailure, verification: method, verified: verified)
        }
    }

    private static func opening(_ frame: CallFrame, arguments: JSONValue, atMS: Int64) throws -> SQLiteCapabilityCallRows.Opening {
        let origin: String
        let name: String?
        switch frame.contract.origin {
        case .core: origin = "core"; name = nil
        case .adapter(let value): origin = "adapter"; name = value
        case .registered(let value): origin = "registered"; name = value
        }
        return SQLiteCapabilityCallRows.Opening(
            event: frame.context.event(app: nil, occurredAtMS: atMS, monotonicNS: nil),
            capabilityID: frame.contract.id.rawValue, effect: frame.contract.effect.rawValue,
            channel: frame.contract.channel.rawValue, origin: origin, originName: name,
            arguments: try fields(arguments, minimization: frame.minimization), attribution: frame.attribution)
    }

    private static func fields(_ value: JSONValue, minimization: ValueMinimization) throws -> [StructuredField] {
        var result: [StructuredField] = []
        func visit(_ value: JSONValue, path: String) throws {
            guard result.count < StructuredField.maximumLeaves else { return }
            switch value {
            case .object(let object):
                for key in object.keys.sorted() {
                    if let value = object[key] {
                        let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                        try visit(value, path: path + "/" + escaped)
                    }
                }
            case .array(let array):
                for (index, value) in array.enumerated() { try visit(value, path: path + "/" + String(index)) }
            default:
                let kind: StructuredField.ValueKind
                let text: String?
                switch value {
                case .string(let string): kind = .text; text = string
                case .number(let number): kind = .number; text = String(number)
                case .bool(let flag): kind = .boolean; text = flag ? "true" : "false"
                default: kind = .null; text = nil
                }
                let reason = text.flatMap { minimization.minimize(text: $0).1 }
                result.append(try StructuredField(path: path.isEmpty ? "/result" : path, kind: kind,
                    text: reason == nil ? text : nil, withheld: reason))
            }
        }
        try visit(value, path: "")
        return result
    }
}
