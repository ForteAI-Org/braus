import Dispatch

/// SQLiteConnectionExecutor runs SQLite jobs on a dedicated serial queue at a fixed QoS.
/// Queue blocks enforce that QoS even when the submitting task has a different priority.
final class SQLiteConnectionExecutor: SerialExecutor {
    private static let roleKey = DispatchSpecificKey<ConnectionRole>()
    private let queue: DispatchSerialQueue

    init(role: ConnectionRole) {
        queue = DispatchSerialQueue(label: "dev.forte.Braus.sqlite.\(role)", qos: role.qos)
        queue.setSpecific(key: Self.roleKey, value: role)
    }

    static var currentRole: ConnectionRole? { DispatchQueue.getSpecific(key: roleKey) }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async(execute: DispatchWorkItem(qos: queue.qos, flags: .enforceQoS) {
            job.runSynchronously(on: executor)
        })
    }
}
