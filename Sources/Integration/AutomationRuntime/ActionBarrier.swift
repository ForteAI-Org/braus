import Foundation
import LocalMCP

/// ActionBarrier keeps one execution context (a worker's conversation, an external client's profile) from doing
/// another way what the person refused (R05). Once a tool call is refused by the person
/// (`ToolCallOutcome.refusedByPerson`), the context takes no new action on any route (the desktop, a web page, an
/// app adapter) until the person allows that same call: retried with the same name and arguments, it
/// is admitted to be decided again, and the barrier opens only when Braus's consent lets it go (the person approved
/// it, or their settings now allow it). Nothing else opens it: no new turn, task, refresh or tool
/// generation, and nothing the model says. Reading Braus's status, closing a session and
/// the memory's own bookkeeping stay admitted; what was sent before the refusal stays as it went.
///
/// One barrier per context, made by the context's stable owner and given to every turn it makes, so a new
/// generation or a reconnect does not reset it, and two contexts never share one. With a refusal file (P2-06) a
/// refusal outlives the process: the context's key, the tool and a salted digest of the arguments are written
/// (0600, replaced whole), never an argument or a credential, and a barrier made again for that key starts closed. A
/// file that cannot be read blocks actions until the store is readable; one that cannot be written leaves the
/// refusal in memory only and says so through `persistenceFailed`. The salt lives in the same file: a digest names a
/// repeat, it does not hide a short guessable value from someone who can read the file.
@MainActor
public final class ActionBarrier {

    /// The call the person refused, which alone may be decided again while the barrier is closed.
    public struct Refused: Sendable, Equatable {
        public let tool  : String
        public let digest: String
    }

    /// The tools admitted while the barrier is closed: none acts on an app, a page or a service.
    public static let admittedWhileClosed: Set<String> = ["status", "close_session",
                                                          "memory_task"]

    public private(set) var refused: Refused?
    private var persistenceUnavailable = false
    /// Whether the last refusal could not be written to the refusal file.
    public private(set) var persistenceFailed = false
    private let file: RefusalFile?

    public init() {
        file = nil
    }

    /// A barrier whose refusals are kept in `folder`'s refusal file under `context`; it starts closed when that context
    /// has one there.
    public init(persistingIn folder: URL, context: String) {
        let file = RefusalFile(folder: folder, context: context)
        self.file    = file
        do {
            self.refused = try file.load()
        } catch {
            persistenceUnavailable = true
            persistenceFailed = true
        }
    }

    public var isClosed: Bool {
        refresh()
        return refused != nil || persistenceUnavailable
    }

    private func refresh() {
        guard let file, !persistenceFailed else { return }
        do {
            refused = try file.load()
            persistenceUnavailable = false
        } catch {
            persistenceUnavailable = true
        }
    }

    /// Why `name` is not admitted now, or nil when it is.
    public func refusal(of name: String, _ arguments: JSONValue) -> String? {
        refresh()
        guard !Self.admittedWhileClosed.contains(name) else { return nil }
        if persistenceUnavailable {
            return "Not run: Braus cannot read this context's persisted refusals. Restore the refusal store before acting."
        }
        guard let refused,
              !(name == refused.tool && digest(of: arguments) == refused.digest) else { return nil }
        return "Not run: the person refused \(refused.tool) in this conversation, so Braus takes no other action "
            + "here, on any app, page, until the person allows that same call (asked again and approved, "
            + "or allowed by the person). Nothing was sent. Tell the person what was refused."
    }

    /// Takes in how Braus decided tool call `name`: a refusal by the person closes the barrier; the refused call
    /// itself consented to opens it.
    public func note(_ outcome: ToolCallOutcome, of name: String, _ arguments: JSONValue) {
        refresh()
        switch outcome {
            case .refusedByPerson:
                refused = Refused(tool: name, digest: digest(of: arguments))
                persistenceFailed = !(file?.save(refused) ?? true)
            case .consented:
                if !persistenceUnavailable, refused == Refused(tool: name, digest: digest(of: arguments)) {
                    if file?.save(nil) ?? true {
                        refused = nil
                        persistenceFailed = false
                    } else {
                        persistenceFailed = true
                    }
                }
            case .notDecided:
                break
        }
    }

    private func digest(of arguments: JSONValue) -> String {
        RefusalFile.digest(of: arguments, salt: file?.salt ?? RefusalFile.processSalt)
    }

    /// One barrier per key (an external client's profile), made on first use and kept while the store lives; with a
    /// folder, each keeps its refusals there.
    @MainActor
    public final class Store {
        private var barriers: [String: ActionBarrier] = [:]
        private let folder: URL?

        public init(persistingIn folder: URL? = nil) {
            self.folder = folder
        }

        public func barrier(for key: String) -> ActionBarrier {
            if let barrier = barriers[key] { return barrier }
            let barrier = folder.map { ActionBarrier(persistingIn: $0, context: key) } ?? ActionBarrier()
            barriers[key] = barrier
            return barrier
        }
    }
}
