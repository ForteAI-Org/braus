/// MCPFailureContext marks a rejection whose dispatch boundary is known by the producer.
public nonisolated protocol MCPFailureContext: Error {
    /// True only when argument validation rejected the call before its handler ran.
    var isBeforeDispatch: Bool { get }
}
