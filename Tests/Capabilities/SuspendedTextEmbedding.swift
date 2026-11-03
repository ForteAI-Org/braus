import Capabilities

actor SuspendedTextEmbedding: Capabilities.TextEmbedding {
    nonisolated let modelID = "fake"
    private(set) var calls = 0
    private var pending: CheckedContinuation<[[Float]], Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func vectors(for texts: [String]) async throws -> [[Float]] {
        calls += 1
        return await withCheckedContinuation { continuation in
            pending = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func waitForCall() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        pending?.resume(returning: [[1, 0]])
        pending = nil
    }
}

struct FailingTextEmbedding: Capabilities.TextEmbedding {
    let modelID = "fake"
    struct Failure: Error {}
    func vectors(for texts: [String]) async throws -> [[Float]] { throw Failure() }
}
