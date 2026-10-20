//
//  AdapterDispatch.swift
//  Braus
//

/// AdapterDispatch is the adapter verb a call invoked (M05): the adapter and the verb as the adapters resolved them,
/// never as the call named them, noted right before the adapter runs, once its arguments, the destructive policy and
/// its availability let it. It attests that the adapter was invoked, not that the verb succeeded or what it changed in
/// the app: a call whose adapter threw keeps it, as a failed call. A call refused before the adapter ran has none.
public struct AdapterDispatch: Sendable, Equatable {

    public let adapter: String
    public let verb   : String

    public init(adapter: String, verb: String) {
        self.adapter = adapter
        self.verb    = verb
    }
}
