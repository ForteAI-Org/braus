import Darwin
import Foundation

/// AppClaims says which owner drives each app, by its bundle ID, on every route and in every Braus process (I03): a
/// worker's, an external client's, the command line's. A session claims the app before anything can reach it, before
/// its launch, its adoption by the Seat or its first input, and keeps the `Hold` it gets until it gives the app back;
/// while another owner holds it, a claim is refused, with nothing sent and no other route taken. One owner's sessions
/// share a claim (a worker's native session and its Seat, so a handoff between them keeps the app), each with its own
/// hold: one session giving its hold back, or going away, never frees another's.
///
/// Across processes, the claim takes an exclusive advisory lock (`flock`) on one file per bundle ID in `namespace`,
/// opened without following a link and close-on-exec, so no app it launches inherits it, and never removed. The lock
/// belongs to the claim's record, which only its holds keep alive: the last hold dropped, by `close` or by its session
/// going away, closes the file and so frees the app for another process; the system frees it when the process exits
/// or crashes. No process ID is written or signalled, and nothing polls. A namespace that cannot be locked refuses the
/// claim. Without a namespace, claims are this process's only.
@MainActor
public final class AppClaims {

    /// The claims of the process, locked in `defaultNamespace`.
    public static let shared = AppClaims(namespace: defaultNamespace)

    /// One folder per user that every Braus process (the app, the command line) shares.
    public static var defaultNamespace: URL {
        FileManager.default.temporaryDirectory.appending(path: "braus-app-claims", directoryHint: .isDirectory)
    }

    /// Why a claim was refused.
    public enum Refusal: Error, Equatable, Sendable {
        /// Another owner's session in this process holds the app.
        case heldHere
        /// Another Braus process holds the app.
        case heldElsewhere
        /// The lock folder or file could not be opened.
        case unavailable(String)
    }

    /// Hold is one session's share of a claim: the app stays its owner's while any hold of the claim lives.
    public final class Hold {
        public let bundleID: String
        fileprivate let record: Record

        fileprivate init(bundleID: String, record: Record) {
            self.bundleID = bundleID
            self.record   = record
        }
    }

    /// Record is a claim: its owner and its lock, closed when the last hold lets it go.
    fileprivate final class Record: @unchecked Sendable {
        let owner     : AnyHashable
        let descriptor: Int32?

        init(owner: AnyHashable, descriptor: Int32?) {
            self.owner      = owner
            self.descriptor = descriptor
        }

        deinit {
            if let descriptor { Darwin.close(descriptor) }
        }
    }

    private final class Entry {
        weak var record: Record?
        init(_ record: Record) { self.record = record }
    }

    private let namespace: URL?
    private var entries: [String: Entry] = [:]

    /// `namespace` is where the cross-process locks live; nil keeps the claims within this process.
    public init(namespace: URL? = nil) {
        self.namespace = namespace
    }

    /// A hold of `bundleID` for `owner`, or why not: another owner holds it here or in another process.
    public func acquire(_ bundleID: String, owner: AnyHashable) -> Result<Hold, Refusal> {
        if let record = entries[bundleID]?.record {
            guard record.owner == owner else { return .failure(.heldHere) }
            return .success(Hold(bundleID: bundleID, record: record))
        }
        var descriptor: Int32?
        if let namespace {
            switch Self.lock(bundleID, in: namespace) {
                case .success(let locked): descriptor = locked
                case .failure(let refusal): return .failure(refusal)
            }
        }
        let record = Record(owner: owner, descriptor: descriptor)
        entries[bundleID] = Entry(record)
        return .success(Hold(bundleID: bundleID, record: record))
    }

    /// Whether a hold of `bundleID` lives in this process now.
    public func isHeld(_ bundleID: String) -> Bool { entries[bundleID]?.record != nil }

    /// What an agent reads when `name` could not be claimed: nothing was sent to it and no other route was used.
    public nonisolated static func sentence(_ refusal: Refusal, name: String) -> String {
        switch refusal {
            case .heldHere, .heldElsewhere:
                let who = refusal == .heldHere ? "another Braus worker or client" : "another Braus process"
                return "\(name) is being driven by \(who) right now, so nothing was sent to it and no other route was "
                    + "used. Wait until it is done, or ask the person."
            case .unavailable(let reason):
                return "Braus could not claim \(name) for this session (\(reason)), so nothing was sent to it and no "
                    + "other route was used."
        }
    }

    /// Takes the exclusive lock of `bundleID` in `namespace` without waiting: the open descriptor holding it, or why
    /// not. The folder must be a folder of this user, not a link; the file is opened without following a link,
    /// close-on-exec, and must be a regular file.
    nonisolated static func lock(_ bundleID: String, in namespace: URL) -> Result<Int32, Refusal> {
        let files = FileManager.default
        do {
            try files.createDirectory(at: namespace, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.unavailable("its lock folder could not be made"))
        }
        var folder = stat()
        guard lstat(namespace.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid() else {
            return .failure(.unavailable("its lock folder is not a folder of this user"))
        }
        let path = namespace.appending(path: fileName(of: bundleID)).path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return .failure(.unavailable("its lock file could not be opened")) }
        var file = stat()
        guard fstat(descriptor, &file) == 0, file.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            return .failure(.unavailable("its lock file is not a regular file"))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            Darwin.close(descriptor)
            return .failure(busy ? .heldElsewhere : .unavailable("its lock file could not be locked"))
        }
        return .success(descriptor)
    }

    /// A file name for `bundleID`: its letters, digits, dots, dashes and underscores, anything else escaped.
    nonisolated static func fileName(of bundleID: String) -> String {
        let kept = bundleID.unicodeScalars.map { scalar -> String in
            switch scalar {
                case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "_": String(scalar)
                default: String(format: "%%%04X", scalar.value)
            }
        }
        return kept.joined() + ".lock"
    }
}
