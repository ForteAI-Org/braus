import Foundation

/// ScriptQueue is the one serial executor every adapter's AppleScript runs on: off the main actor, so an app that
/// answers slowly never stalls the interface, and one script at a time, since NSAppleScript is not thread-safe.
///
/// A script holds the queue until it returns, so each fixed script bounds its Apple events with `with timeout`: a hung
/// app answers a timeout instead of holding every other adapter's script behind it.
actor ScriptQueue {

    static let shared = ScriptQueue()

    private let queue = DispatchSerialQueue(label: "dev.forte.Braus.AppleScript")

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Runs `body` on the queue, alone: no other body starts before it returns. It must not wait for the main actor,
    /// which may be waiting for it.
    func run<Value: Sendable>(_ body: @Sendable () throws -> Value) throws -> Value {
        try body()
    }
}
