import Dispatch

/// SQLiteConnectionExecutor gives a connection's actor a dedicated serial queue at a fixed QoS.
/// The queue, not this type, is the actor's `SerialExecutor`: that conformance lives in libdispatch,
/// in the system, so the app refers to nothing the runtime of an older macOS lacks. A conformance
/// written here would carry the protocol's whole witness table, and the swift.org toolchain that
/// builds the release links its macOS 26 requirements strongly, which stopped the app at launch on
/// macOS 15.
final class SQLiteConnectionExecutor: Sendable {
    private static let roleKey = DispatchSpecificKey<ConnectionRole>()
    private let queue: DispatchSerialQueue

    init(role: ConnectionRole) {
        queue = DispatchSerialQueue(label: "dev.forte.Braus.sqlite.\(role)", qos: role.qos)
        queue.setSpecific(key: Self.roleKey, value: role)
    }

    static var currentRole: ConnectionRole? { DispatchQueue.getSpecific(key: roleKey) }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
}
