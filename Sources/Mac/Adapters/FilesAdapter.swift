import Darwin
import EngineCore
import Foundation
import LocalMCP
import Synchronization

/// FilesAdapter is the person's files with Finder closed: a working directory of its own, listing and finding,
/// reading text, making folders, copying, moving, writing, appending, editing, moving to the Trash. Every path is
/// confined to the root (the home folder) and kept out of its Library; `~` stands for the root, and a relative path
/// for one under the working directory. Every change is read back from the disk and compared exactly; a refusal has
/// done nothing.
///
/// Confinement is by descriptors, not by paths: a path is reduced to its components lexically (`resolve`; a NUL
/// anywhere is refused before any system call, since the kernel would read the name only up to it), then each
/// component is opened relative to the one before it, from the root's own descriptor, with `O_NOFOLLOW` at every
/// step (`openDirectory`, `openat`): a symbolic link anywhere, put there before or during the call, is never
/// followed, in or out of the root. Library is refused by its name, case aside, and by its identity on disk (the
/// device and inode of `Library` under the root), so a volume that ignores case cannot be asked for it under
/// another spelling. A file is written whole to a temporary name beside it and published at once, exclusively for
/// a new file (`linkat`, which never replaces) or by rename for an explicit replacement, so an error or a
/// cancellation leaves the old bytes as they were. A read-back reopens the path the same way.
///
/// Bounds, small and stated: a listing reads 2000 entries and answers 200; a search visits 2000 entries at most, 4
/// levels deep, and answers 200; a read gives 64 KiB at most and reads no more; a text written, appended or used in
/// an edit is 64 KiB at most; a file appended to, edited or copied is 1 MiB at most, read no further; a call has 5
/// seconds. Cancellation and the time are checked in every loop, on every entry read, chunk read or written, and
/// right before anything is published: before an effect, a cancellation is thrown and spent time refused with
/// nothing done; after one (an append under way, a parent folder made), the answer says so and nothing is repeated.
///
/// Not here, with the reason: `reveal` and `open_with` open a window in another app and are read back from its
/// accessibility tree, which an adapter does not read. No shell, no delete.
public struct FilesAdapter: AppAdapting {

    public let name       = "files"
    public let appNames   = ["Files", "Finder"]
    public let bundleIDs: Set<String> = ["com.apple.finder"]

    /// The most entries one listing or one search answers.
    static let maximumEntries = 200
    /// The most entries one listing reads, and one search visits, before it stops and says so.
    static let maximumVisited = 2000
    /// How deep a search goes below its folder.
    static let maximumDepth = 4
    /// The most bytes one read answers, and the default.
    static let maximumReadBytes = 65_536
    /// The most bytes a text written, appended or replaced may hold.
    static let maximumTextBytes = 65_536
    /// The largest file appended to, edited or copied.
    static let maximumFileBytes = 1_048_576
    /// How long one call may take, unless an instance is given another time (tests).
    static let timeBudget: Duration = .seconds(5)
    /// The most unreadable folders a search names.
    static let maximumNamedUnreadable = 20

    /// The root, resolved of symbolic links, and its path as given: an absolute path is admitted under either.
    private let root     : URL
    private let rootPaths: [String]
    /// The working directory of this adapter instance, as components under the root; relative paths resolve against
    /// it. Never the process's directory. Read once per call, never held across an await.
    private let state    : WorkingDirectory
    /// Moves an item to the Trash and answers where it went. The live one is FileManager's; tests
    /// pass one that keeps the person's Trash untouched.
    private let trash    : @Sendable (URL) throws -> URL?
    /// How long one call of this instance may take.
    private let time     : Duration

    /// The one mutable thing of an instance, behind a lock, shared by the copies of the struct.
    final class WorkingDirectory: Sendable {
        let components = Mutex<[String]>([])
    }

    public init(
        root : URL = FileManager.default.homeDirectoryForCurrentUser,
        trash: @escaping @Sendable (URL) throws -> URL? = { url in
            var moved: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &moved)
            return moved as URL?
        }
    ) {
        self.init(root: root, trash: trash, time: Self.timeBudget)
    }

    /// An instance with its own time per call, for the tests of what a spent budget refuses or stops.
    init(root: URL, trash: @escaping @Sendable (URL) throws -> URL?, time: Duration) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root      = resolved
        self.rootPaths = Array(Set([resolved.path, root.standardizedFileURL.path]))
        self.state     = WorkingDirectory()
        self.trash     = trash
        self.time      = time
    }

    public var verbs: [AdapterVerb] {
        let path = AdapterParameter("path", .string, "a path: ~ is the home folder, ~/… under it, a relative one under the working directory")
        let text = AdapterParameter("text", .string, "the text, UTF-8, 64 KiB at most", allowsEmpty: true, content: true)
        return [
            AdapterVerb("pwd", "Answer the working directory of this session.", safety: .read, readBack: "the working directory, a folder on disk"),
            AdapterVerb("cd", "Change the working directory of this session to a folder inside the home folder.",
                        parameters: [path], safety: .read, readBack: "the new working directory, a folder on disk"),
            AdapterVerb("list", "List a folder's items with kind, size and modification date.",
                        parameters: [path, AdapterParameter("hidden", .boolean, "include hidden items", required: false)],
                        safety: .read, readBack: "the folder's contents, 200 entries at most"),
            AdapterVerb("find", "Find items under a folder by name: a part of the name, or a pattern with * and ?.",
                        parameters: [
                            path, AdapterParameter("name", .string, "a part of the name, or a pattern with * and ?"),
                            AdapterParameter("depth", .integer, "how many levels below the folder, 4 at most, 2 by default",
                                             required: false, range: 0...Double(Self.maximumDepth)),
                            AdapterParameter("limit", .integer, "how many matches to answer, 200 at most",
                                             required: false, range: 1...Double(Self.maximumEntries)),
                        ],
                        safety: .read, readBack: "the matches, bounded, and whether the search stopped early"),
            AdapterVerb("read", "Read a text file, UTF-8, up to max_bytes (64 KiB at most).",
                        parameters: [path, AdapterParameter("max_bytes", .integer, "how many bytes to read, 64 KiB at most",
                                                            required: false, range: 1...Double(Self.maximumReadBytes))],
                        safety: .read, readBack: "the text, its size, and whether it was cut", contentResults: ["text"]),
            AdapterVerb("make_folder", "Make a folder, with any missing parents.", parameters: [path],
                        safety: .write, readBack: "the folder present on disk"),
            AdapterVerb("copy", "Copy a file to a new path. Refuses to replace an existing item.",
                        parameters: [
                            AdapterParameter("from", .string, "the file's path"),
                            AdapterParameter("to", .string, "the new path, or an existing folder to copy it into"),
                        ],
                        safety: .write, readBack: "the copy's bytes equal to the source's, the source unchanged"),
            AdapterVerb("move", "Move or rename an item. Refuses to replace an existing item.",
                        parameters: [
                            AdapterParameter("from", .string, "the item's path"),
                            AdapterParameter("to", .string, "the new path, or an existing folder to move it into"),
                        ],
                        safety: .write, readBack: "the item at its new path and gone from the old one"),
            AdapterVerb("write", "Write a text file. Refuses an existing file unless overwrite is true.",
                        parameters: [path, text, AdapterParameter("overwrite", .boolean, "replace an existing file", required: false)],
                        safety: .write, readBack: "the file's bytes equal to the text"),
            AdapterVerb("append", "Append text to an existing text file.", parameters: [path, text],
                        safety: .write, readBack: "the file's bytes equal to what they were plus the text"),
            AdapterVerb("edit", "Replace one occurrence of a text in a text file; refuses when it occurs more or less than once.",
                        parameters: [
                            path, AdapterParameter("find", .string, "the text to replace, which must occur exactly once", content: true),
                            AdapterParameter("replace", .string, "the text to put in its place; empty removes it",
                                             allowsEmpty: true, content: true),
                        ],
                        safety: .write, readBack: "the file's bytes equal to what they were with the one replacement"),
            AdapterVerb("move_to_trash", "Move an item to the Trash.", parameters: [path],
                        safety: .irreversible, readBack: "the item gone from its path and present in the Trash",
                        confirms: .readBack),
        ]
    }

    public func availability() async -> AdapterAvailability {
        switch openDirectory(.root) {
            case .success:
                return .ready
            case .failure(let problem):
                return .unavailable("The home folder cannot be opened: \(problem.reason)")
        }
    }

    public func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        let arguments = AdapterArguments(arguments)
        try Task.checkCancellation()
        // One working directory for the whole call, whatever `cd` does meanwhile from another call.
        let call = Call(cwd: Location(state.components.withLock { $0 }), budget: Budget(time))
        switch verb {
            case "pwd":           return pwd(call)
            case "cd":            return changeDirectory(try arguments.required("path"), call)
            case "list":          return try list(try arguments.required("path"), hidden: arguments.bool("hidden") ?? false, call)
            case "find":          return try find(try arguments.required("path"), name: try arguments.required("name"),
                                                  depth: Int(arguments.number("depth") ?? 2),
                                                  limit: Int(arguments.number("limit") ?? Double(Self.maximumEntries)), call)
            case "read":          return try read(try arguments.required("path"),
                                                  maxBytes: Int(arguments.number("max_bytes") ?? Double(Self.maximumReadBytes)), call)
            case "make_folder":   return try await makeFolder(try arguments.required("path"), call)
            case "copy":          return try await copy(try arguments.required("from"), to: try arguments.required("to"), call)
            case "move":          return try await move(try arguments.required("from"), to: try arguments.required("to"), call)
            case "write":         return try await write(try arguments.required("path"), text: try arguments.required("text"),
                                                         overwrite: arguments.bool("overwrite") ?? false, call)
            case "append":        return try await append(try arguments.required("path"), text: try arguments.required("text"), call)
            case "edit":          return try await edit(try arguments.required("path"), find: try arguments.required("find"),
                                                        replace: try arguments.required("replace"), call)
            case "move_to_trash": return try await moveToTrash(try arguments.required("path"), call)
            default:              throw AdapterFailure("files has no verb \(verb).")
        }
    }

    // MARK: One call

    /// What one call holds for its whole run: the working directory it saw at its start, and its time.
    struct Call {
        let cwd   : Location
        let budget: Budget
    }

    /// The time one call has; `expired` once it is spent.
    struct Budget {
        let deadline: ContinuousClock.Instant

        init(_ time: Duration) { deadline = ContinuousClock.now + time }

        var expired: Bool { ContinuousClock.now > deadline }
    }

    /// Why a call cannot go on before an effect: thrown for a cancellation, answered as the refusal of spent time;
    /// nil while it can.
    private func exhausted(_ call: Call) throws -> AdapterOutcome? {
        try Task.checkCancellation()
        return call.budget.expired ? .refused("The call ran out of its time before the change; nothing was done.") : nil
    }

    /// Why a loop stops before its next step: a cancellation thrown, spent time said; nil while it can go on.
    private static func stopping(_ call: Call) throws -> String? {
        try Task.checkCancellation()
        return call.budget.expired ? "ran out of time" : nil
    }

    // MARK: Paths

    /// A place under the root, by its components; the root itself has none.
    struct Location: Equatable, Sendable {
        let components: [String]

        static let root = Location([])

        init(_ components: [String]) { self.components = components }

        var isRoot: Bool { components.isEmpty }
        /// The last component; the root has none.
        var name: String { components.last ?? "" }
        var parent: Location { Location(Array(components.dropLast())) }
        var shown: String { components.isEmpty ? "~" : "~/" + components.joined(separator: "/") }

        func appending(_ name: String) -> Location { Location(components + [name]) }
        /// Whether this is `other` or lies under it.
        func isInside(_ other: Location) -> Bool {
            components.count >= other.components.count && Array(components.prefix(other.components.count)) == other.components
        }
    }

    /// Why a path is not admitted or not there: a refusal has done nothing; a miss names what does not exist.
    enum PathProblem: Error, Equatable {
        case refused(String)
        case missing(String)

        var reason: String {
            switch self {
                case .refused(let reason): return reason
                case .missing(let reason): return reason
            }
        }

        var outcome: AdapterOutcome {
            switch self {
                case .refused(let reason): return .refused(reason)
                case .missing(let reason): return .missing(reason)
            }
        }
    }

    /// Whether a name is Library's, case aside, as a volume that ignores case would take it.
    static func namesLibrary(_ component: String) -> Bool {
        component.caseInsensitiveCompare("Library") == .orderedSame
    }

    /// The path as components under the root, lexically: `~` the root, `~/…` under it, an absolute path under the
    /// root's own path, anything else under the working directory, which must still be a folder; `.` and `..`
    /// reduced, one that would climb above the root refused, a NUL refused before any system call, `Library` under
    /// any case refused. No link is resolved here: the descriptors never follow one.
    func resolve(_ path: String, _ call: Call) -> Result<Location, PathProblem> {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.refused("The path is empty.")) }
        guard !trimmed.utf8.contains(0) else { return .failure(.refused("The path holds a NUL character, which no file name can.")) }
        var components: [String]
        let rest: Substring
        if trimmed == "~" {
            components = []
            rest = ""
        } else if trimmed.hasPrefix("~/") {
            components = []
            rest = trimmed.dropFirst(2)
        } else if trimmed.hasPrefix("/") {
            var under: Substring?
            for rootPath in rootPaths {
                if trimmed == rootPath { under = "" } else if trimmed.hasPrefix(rootPath + "/") { under = trimmed.dropFirst(rootPath.count + 1) }
                if under != nil { break }
            }
            guard let under else { return .failure(.refused("\(path) is outside the home folder.")) }
            components = []
            rest = under
        } else {
            if case .failure = openDirectory(call.cwd) {
                return .failure(.refused("The working directory \(call.cwd.shown) is gone; cd to a folder that exists."))
            }
            components = call.cwd.components
            rest = trimmed[...]
        }
        for piece in rest.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
                case ".":
                    continue
                case "..":
                    guard !components.isEmpty else { return .failure(.refused("\(path) is outside the home folder.")) }
                    components.removeLast()
                default:
                    components.append(String(piece))
            }
        }
        if let first = components.first, Self.namesLibrary(first) {
            return .failure(.refused("\(path) is inside Library, which the files adapter does not touch."))
        }
        return .success(Location(components))
    }

    /// The location as a file URL, for what must take a path: the Trash.
    private func url(of location: Location) -> URL {
        location.isRoot ? root : root.appendingPathComponent(location.components.joined(separator: "/"))
    }

    // MARK: Descriptors

    /// An open descriptor, closed when the handle goes.
    final class Handle {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { _ = Darwin.close(fd) }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// The identity of an item on disk: its device and inode.
    private struct Identity: Equatable {
        let device: dev_t
        let inode : ino_t

        init(_ status: stat) {
            device = status.st_dev
            inode  = status.st_ino
        }
    }

    /// Whether `name`, right under the root, is Library itself by its identity on disk, whatever its spelling.
    private func isLibrary(_ name: String, underRoot rootFD: Int32) -> Bool {
        var library = stat(), item = stat()
        guard fstatat(rootFD, "Library", &library, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(rootFD, name, &item, AT_SYMLINK_NOFOLLOW) == 0 else { return Self.namesLibrary(name) }
        return Identity(library) == Identity(item) || Self.namesLibrary(name)
    }

    private static let libraryRefusal = "is inside Library, which the files adapter does not touch."

    /// The folder at `location` opened by walking from the root, each component relative to the one before and
    /// never through a link; what stopped the walk names the component it stopped at. Library, by name or identity,
    /// stops it at once.
    func openDirectory(_ location: Location) -> Result<Handle, PathProblem> {
        var fd = Darwin.open(root.path, Self.directoryFlags)
        guard fd >= 0 else { return .failure(.refused("the home folder could not be opened: \(Self.message(errno)).")) }
        var walked = Location.root
        for (index, component) in location.components.enumerated() {
            walked = walked.appending(component)
            if index == 0, isLibrary(component, underRoot: fd) {
                _ = Darwin.close(fd)
                return .failure(.refused("\(walked.shown) \(Self.libraryRefusal)"))
            }
            let next = openat(fd, component, Self.directoryFlags)
            let code = errno
            _ = Darwin.close(fd)
            guard next >= 0 else { return .failure(Self.problem(code, at: walked, wanting: "folder")) }
            fd = next
        }
        return .success(Handle(fd))
    }

    /// The parent folder of `location` opened by the walk, with the item's own name; the root has no parent, and
    /// Library under it is no item of this adapter's.
    private func locate(_ location: Location) -> Result<(parent: Handle, name: String), PathProblem> {
        guard !location.isRoot else { return .failure(.refused("The home folder itself is not an item.")) }
        return openDirectory(location.parent).flatMap { parent -> Result<(parent: Handle, name: String), PathProblem> in
            if location.parent.isRoot, isLibrary(location.name, underRoot: parent.fd) {
                return .failure(.refused("\(location.shown) \(Self.libraryRefusal)"))
            }
            return .success((parent, location.name))
        }
    }

    /// What a `fstatat`/`openat` error means for the item at `location`.
    private static func problem(_ code: Int32, at location: Location, wanting: String) -> PathProblem {
        switch code {
            case ENOENT        : return .missing("No \(wanting) at \(location.shown).")
            case ENOTDIR       : return .refused("\(location.shown) is not a folder.")
            case EISDIR        : return .refused("\(location.shown) is a folder, not a file.")
            case ELOOP         : return .refused("\(location.shown) is a symbolic link; the files adapter follows none.")
            case EACCES, EPERM : return .refused("\(location.shown) is not accessible.")
            case EEXIST        : return .refused("An item already exists at \(location.shown).")
            case ENXIO, EOPNOTSUPP: return .refused("\(location.shown) is not a plain file.")
            default            : return .refused("\(location.shown) could not be opened: \(message(code)).")
        }
    }

    private static func message(_ code: Int32) -> String { String(cString: strerror(code)) }

    /// What an item is, read without following a link; nil when there is no item of that name.
    enum Kind: Equatable {
        case file(size: Int, modified: Date)
        case folder(modified: Date)
        case link
        case other

        var isFolder: Bool {
            if case .folder = self { return true }
            return false
        }

        var word: String {
            switch self {
                case .file  : return "file"
                case .folder: return "folder"
                case .link  : return "link"
                case .other : return "other"
            }
        }
    }

    private func kind(of name: String, in parent: Handle) -> Kind? {
        var status = stat()
        guard fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Self.kind(of: status)
    }

    private static func kind(of status: stat) -> Kind {
        let modified = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
        switch status.st_mode & S_IFMT {
            case S_IFREG: return .file(size: Int(status.st_size), modified: modified)
            case S_IFDIR: return .folder(modified: modified)
            case S_IFLNK: return .link
            default     : return .other
        }
    }

    /// The plain file at `location` opened with `flags` under its parent, never through a link and never blocking
    /// (`O_NONBLOCK`, so a pipe or a device opens at once and is refused by its kind), with its size; a folder or
    /// anything else refused.
    private func openFile(_ location: Location, flags: Int32) -> Result<(file: Handle, size: Int), PathProblem> {
        switch locate(location) {
            case .failure(let problem):
                return .failure(problem)
            case .success(let found):
                let (parent, name) = found
                let fd = openat(parent.fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { return .failure(Self.problem(errno, at: location, wanting: "file")) }
                let file = Handle(fd)
                var status = stat()
                guard fstat(fd, &status) == 0, case .file(let size, _) = Self.kind(of: status) else {
                    return .failure(.refused("\(location.shown) is not a file."))
                }
                return .success((file, size))
        }
    }

    /// Up to `limit` bytes of the open file, from where it stands, read no further; an interrupted read is retried,
    /// any other error refuses, a cancellation is thrown, and spent time refuses what was read so far.
    private static func bytes(of file: Handle, upTo limit: Int, at location: Location, _ call: Call) throws -> Result<Data, PathProblem> {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while data.count < limit {
            if let stopped = try stopping(call) { return .failure(.refused("The read of \(location.shown) \(stopped).")) }
            let wanted = min(chunk.count, limit - data.count)
            let got = chunk.withUnsafeMutableBytes { Darwin.read(file.fd, $0.baseAddress, wanted) }
            if got < 0 {
                if errno == EINTR { continue }
                return .failure(.refused("\(location.shown) could not be read: \(message(errno))."))
            }
            if got == 0 { break }
            data.append(contentsOf: chunk[0..<got])
        }
        return .success(data)
    }

    /// The whole file, when it is within `limit` bytes now, whatever its size said a moment ago.
    private func wholeBytes(of location: Location, limit: Int, doing: String, _ call: Call) throws -> Result<Data, PathProblem> {
        switch openFile(location, flags: O_RDONLY) {
            case .failure(let problem):
                return .failure(problem)
            case .success(let opened):
                return try Self.bytes(of: opened.file, upTo: limit + 1, at: location, call).flatMap { data -> Result<Data, PathProblem> in
                    guard data.count <= limit else {
                        return .failure(.refused("\(location.shown) is over the \(limit) bytes this adapter \(doing)."))
                    }
                    return .success(data)
                }
        }
    }

    /// One entry of a folder, as `readdir` gives it and `fstatat` describes it.
    struct Entry {
        let name: String
        let kind: Kind
    }

    /// Up to `limit` entries of the open folder, hidden ones only when asked, read one by one and no further, the
    /// time and the task checked at each; the reason the read stopped short, when it did. The end of the folder is
    /// told apart from a read that failed, which refuses.
    private func entries(of folder: Handle, hidden: Bool, limit: Int, _ call: Call) throws -> Result<(entries: [Entry], stopped: String?), PathProblem> {
        let copy = dup(folder.fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { _ = Darwin.close(copy) }
            return .failure(.refused("the folder could not be read: \(Self.message(errno))."))
        }
        defer { closedir(stream) }
        var found: [Entry] = []
        while true {
            if let stopped = try Self.stopping(call) { return .success((found, "\(stopped) after \(found.count) entries")) }
            errno = 0
            guard let entry = readdir(stream) else {
                let code = errno
                if code == EINTR { continue }
                guard code == 0 else { return .failure(.refused("the folder could not be read whole: \(Self.message(code)).")) }
                return .success((found, nil))
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." || (!hidden && name.hasPrefix(".")) { continue }
            if found.count >= limit { return .success((found, "read \(limit) entries")) }
            // An entry gone between the directory read and its status is not there.
            guard let kind = kind(of: name, in: folder) else { continue }
            found.append(Entry(name: name, kind: kind))
        }
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// An entry as the answers write it: a link's name alone, since its destination is not read.
    private func json(of entry: Entry, at location: Location?) -> JSONValue {
        var object: [String: JSONValue] = ["name": .string(entry.name), "kind": .string(entry.kind.word)]
        switch entry.kind {
            case .file(let size, let modified):
                object["bytes"] = .number(Double(size))
                object["modified"] = .string(AdapterArguments.text(modified))
            case .folder(let modified):
                object["modified"] = .string(AdapterArguments.text(modified))
            case .link, .other:
                break
        }
        if let location { object["path"] = .string(location.shown) }
        return .object(object)
    }

    // MARK: The working directory

    private func pwd(_ call: Call) -> AdapterOutcome {
        switch openDirectory(call.cwd) {
            case .success:
                return .confirmed("The working directory is \(call.cwd.shown).", .object(["path": .string(call.cwd.shown)]))
            case .failure:
                return .refused("The working directory \(call.cwd.shown) is gone; cd to a folder that exists.")
        }
    }

    private func changeDirectory(_ path: String, _ call: Call) -> AdapterOutcome {
        let folder: Location
        switch resolve(path, call) {
            case .success(let location): folder = location
            case .failure(let problem): return problem.outcome
        }
        if case .failure(let problem) = openDirectory(folder) { return problem.outcome }
        state.components.withLock { $0 = folder.components }
        return .confirmed("The working directory is \(folder.shown).", .object(["path": .string(folder.shown)]))
    }

    // MARK: Reading

    private func list(_ path: String, hidden: Bool, _ call: Call) throws -> AdapterOutcome {
        let folder: Location
        switch resolve(path, call) {
            case .success(let location): folder = location
            case .failure(let problem): return problem.outcome
        }
        let handle: Handle
        switch openDirectory(folder) {
            case .success(let opened): handle = opened
            case .failure(let problem): return problem.outcome
        }
        let read: (entries: [Entry], stopped: String?)
        switch try entries(of: handle, hidden: hidden, limit: Self.maximumVisited, call) {
            case .success(let found): read = found
            case .failure(let problem): return .refused("\(folder.shown): \(problem.reason)")
        }
        let items = Self.sorted(read.entries)
        let shownItems = items.prefix(Self.maximumEntries)
        var result: [String: JSONValue] = ["path": .string(folder.shown), "items": .array(shownItems.map { json(of: $0, at: nil) })]
        if items.count > shownItems.count { result["more"] = .number(Double(items.count - shownItems.count)) }
        if let stopped = read.stopped { result["stopped"] = .string(stopped) }
        let count = read.stopped == nil ? "\(items.count) items" : "at least \(items.count) items"
        return .confirmed("\(count) in \(folder.shown)" + (read.stopped.map { ", stopped early: \($0)" } ?? "") + ".", .object(result))
    }

    /// Items under a folder whose name matches `name`: a pattern with `*` or `?` (`fnmatch`, case-insensitive), else a
    /// part of the name. Hidden items are skipped; links are neither followed nor shown, and counted; Library is never
    /// entered. Breadth first, each folder reopened by the walk and read within the budget of visited entries; a
    /// folder that cannot be read is named, never passed over as empty. The search says when it stopped early.
    private func find(_ path: String, name: String, depth: Int, limit: Int, _ call: Call) throws -> AdapterOutcome {
        let folder: Location
        switch resolve(path, call) {
            case .success(let location): folder = location
            case .failure(let problem): return problem.outcome
        }
        if case .failure(let problem) = openDirectory(folder) { return problem.outcome }
        let depth = max(0, min(depth, Self.maximumDepth)), limit = max(1, min(limit, Self.maximumEntries))
        let pattern = name.contains("*") || name.contains("?")
        var matches: [JSONValue] = []
        var visited = 0, links = 0
        var unreadable: [String] = [], unreadableCount = 0
        var stopped: String?
        var queue: [(folder: Location, level: Int)] = [(folder, 0)]
        search: while !queue.isEmpty {
            let (current, level) = queue.removeFirst()
            if let short = try Self.stopping(call) { stopped = short; break }
            let handle: Handle
            switch openDirectory(current) {
                case .success(let opened): handle = opened
                case .failure:
                    unreadableCount += 1
                    if unreadable.count < Self.maximumNamedUnreadable { unreadable.append(current.shown) }
                    continue
            }
            let read: (entries: [Entry], stopped: String?)
            switch try entries(of: handle, hidden: false, limit: Self.maximumVisited - visited, call) {
                case .success(let found): read = found
                case .failure:
                    unreadableCount += 1
                    if unreadable.count < Self.maximumNamedUnreadable { unreadable.append(current.shown) }
                    continue
            }
            visited += read.entries.count
            for entry in Self.sorted(read.entries) {
                let child = current.appending(entry.name)
                // Library is not the adapter's; a link is followed nowhere and describes nothing here.
                if current.isRoot, Self.namesLibrary(entry.name) { continue }
                if entry.kind == .link { links += 1; continue }
                let matched = pattern
                    ? fnmatch(name, entry.name, FNM_CASEFOLD) == 0
                    : entry.name.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                if matched {
                    if matches.count >= limit { stopped = "answered \(limit) matches"; break search }
                    matches.append(json(of: entry, at: child))
                }
                if entry.kind.isFolder, level < depth { queue.append((child, level + 1)) }
            }
            if let short = read.stopped {
                stopped = visited >= Self.maximumVisited ? "visited \(Self.maximumVisited) entries" : short
                break
            }
        }
        var result: [String: JSONValue] = ["path": .string(folder.shown), "matches": .array(matches),
                                           "visited": .number(Double(visited))]
        if let stopped { result["stopped"] = .string(stopped) }
        if links > 0 { result["links_skipped"] = .number(Double(links)) }
        if unreadableCount > 0 {
            result["unreadable"] = .array(unreadable.map { .string($0) })
            result["unreadable_count"] = .number(Double(unreadableCount))
        }
        var message = "\(matches.count) matches under \(folder.shown)"
        if let stopped { message += ", stopped early: \(stopped)" }
        if unreadableCount > 0 { message += "; \(unreadableCount) folders could not be read" }
        return .confirmed(message + ".", .object(result))
    }

    /// The first `maxBytes` of a text file, as UTF-8. Only that much is read from the disk. A cut inside a character
    /// drops that character's bytes, so the text ends whole; bytes that are not UTF-8 refuse the file as not text.
    private func read(_ path: String, maxBytes: Int, _ call: Call) throws -> AdapterOutcome {
        let location: Location
        switch resolve(path, call) {
            case .success(let found): location = found
            case .failure(let problem): return problem.outcome
        }
        let file: Handle, size: Int
        switch openFile(location, flags: O_RDONLY) {
            case .success(let opened): (file, size) = opened
            case .failure(let problem): return problem.outcome
        }
        let wanted = max(1, min(maxBytes, Self.maximumReadBytes))
        var data: Data
        switch try Self.bytes(of: file, upTo: wanted, at: location, call) {
            case .success(let read): data = read
            case .failure(let problem): return problem.outcome
        }
        let truncated = size > data.count
        // Cut inside a character: the trailing incomplete sequence is at most three bytes; they are dropped, no more.
        var dropped = 0
        while truncated, dropped < 3, !data.isEmpty, String(data: data, encoding: .utf8) == nil {
            data.removeLast()
            dropped += 1
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .refused("\(location.shown) is not a UTF-8 text file.")
        }
        let result: JSONValue = .object([
            "path": .string(location.shown), "text": .string(text), "bytes": .number(Double(data.count)),
            "size": .number(Double(size)), "truncated": .bool(truncated),
        ])
        return .confirmed("Read \(data.count) of \(size) bytes of \(location.shown)" + (truncated ? ", cut at the bound." : "."), result)
    }

    // MARK: Changes

    private func makeFolder(_ path: String, _ call: Call) async throws -> AdapterOutcome {
        let folder: Location
        switch resolve(path, call) {
            case .success(let location): folder = location
            case .failure(let problem): return problem.outcome
        }
        if case .success = openDirectory(folder) {
            return AdapterOutcome(.actedNoop, "\(folder.shown) already exists.", result: .object(["path": .string(folder.shown)]))
        }
        let result = JSONValue.object(["path": .string(folder.shown)])
        // Walk down; each component that is missing is made, after the time and the task are checked again; what
        // is there and is not a folder refuses. Once a parent was made, a stop is said as such, never as nothing done.
        var fd = Darwin.open(root.path, Self.directoryFlags)
        guard fd >= 0 else { return .refused("The home folder could not be opened: \(Self.message(errno)).") }
        var walked = Location.root
        var made = false
        for (index, component) in folder.components.enumerated() {
            walked = walked.appending(component)
            if index == 0, isLibrary(component, underRoot: fd) {
                _ = Darwin.close(fd)
                return .refused("\(walked.shown) \(Self.libraryRefusal)")
            }
            var next = openat(fd, component, Self.directoryFlags)
            if next < 0, errno == ENOENT {
                do {
                    if let spent = try exhausted(call) {
                        _ = Darwin.close(fd)
                        return made ? AdapterOutcome(.actedUnverified, "The time ran out after a parent of \(folder.shown) was made; list it.", result: result) : spent
                    }
                } catch {
                    _ = Darwin.close(fd)
                    guard made else { throw error }
                    return AdapterOutcome(.actedUnverified, "The call was cancelled after a parent of \(folder.shown) was made; list it.", result: result)
                }
                guard mkdirat(fd, component, 0o755) == 0 else {
                    let code = errno
                    _ = Darwin.close(fd)
                    return made
                        ? AdapterOutcome(.actedUnverified, "\(walked.shown) could not be made (\(Self.message(code))) after a parent was; list the parent.", result: result)
                        : .refused("\(walked.shown) could not be made: \(Self.message(code)); nothing was changed.")
                }
                made = true
                next = openat(fd, component, Self.directoryFlags)
            }
            let code = errno
            _ = Darwin.close(fd)
            guard next >= 0 else {
                let problem = Self.problem(code, at: walked, wanting: "folder")
                return made
                    ? AdapterOutcome(.actedUnverified, "\(problem.reason) A parent was made; list it.", result: result)
                    : .refused("\(problem.reason) Nothing was changed.")
            }
            fd = next
        }
        _ = Darwin.close(fd)
        return await .afterChange("The folder was made", look: "List its parent", result: result) {
            guard case .success = openDirectory(folder) else {
                return AdapterOutcome(.actedUnverified, "The folder did not read back.", result: result)
            }
            return .confirmed("Made \(folder.shown).", result)
        }
    }

    private func copy(_ from: String, to: String, _ call: Call) async throws -> AdapterOutcome {
        let source: Location, target: Location
        switch (resolve(from, call), resolve(to, call)) {
            case (.failure(let problem), _), (_, .failure(let problem)): return problem.outcome
            case (.success(let a), .success(let b)): (source, target) = (a, b)
        }
        guard !source.isRoot else { return .refused("The home folder itself is not a file.") }
        let before: Data
        switch try wholeBytes(of: source, limit: Self.maximumFileBytes, doing: "copies", call) {
            case .success(let bytes): before = bytes
            case .failure(let problem): return problem.outcome
        }
        // An existing folder as the target receives the copy under the source's name.
        let destination: Location
        if case .success = openDirectory(target) { destination = target.appending(source.name) } else { destination = target }
        guard destination != source else { return .refused("\(from) is already there.") }
        let parent: Handle, name: String
        switch locate(destination) {
            case .success(let found): (parent, name) = found
            case .failure(let problem): return problem.outcome
        }
        guard kind(of: name, in: parent) == nil else { return .refused("An item already exists at \(destination.shown).") }
        if let spent = try exhausted(call) { return spent }
        if case .failure(let problem) = try publish(before, as: name, in: parent, at: destination, replacing: false, call) {
            return problem.outcome
        }
        let result = JSONValue.object(["from": .string(source.shown), "to": .string(destination.shown),
                                       "bytes": .number(Double(before.count))])
        return await .afterChange("The file was copied", look: "Read both files", result: result) {
            guard case .success(let copied) = try wholeBytes(of: destination, limit: Self.maximumFileBytes, doing: "copies", call), copied == before,
                  case .success(let kept) = try wholeBytes(of: source, limit: Self.maximumFileBytes, doing: "copies", call), kept == before else {
                return AdapterOutcome(.actedUnverified, "The copy did not read back equal to the source.", result: result)
            }
            return .confirmed("Copied to \(destination.shown), \(before.count) bytes.", result)
        }
    }

    private func move(_ from: String, to: String, _ call: Call) async throws -> AdapterOutcome {
        let source: Location, target: Location
        switch (resolve(from, call), resolve(to, call)) {
            case (.failure(let problem), _), (_, .failure(let problem)): return problem.outcome
            case (.success(let a), .success(let b)): (source, target) = (a, b)
        }
        guard !source.isRoot else { return .refused("The home folder itself cannot be moved.") }
        let fromParent: Handle, fromName: String
        switch locate(source) {
            case .success(let found): (fromParent, fromName) = found
            case .failure(let problem): return problem.outcome
        }
        guard kind(of: fromName, in: fromParent) != nil else { return .missing("No item at \(source.shown).") }
        // An existing folder as the target receives the item under its own name.
        let destination: Location
        if case .success = openDirectory(target) { destination = target.appending(source.name) } else { destination = target }
        guard destination != source else { return .refused("\(from) is already there.") }
        guard !destination.isInside(source) else { return .refused("A folder cannot go inside itself.") }
        let toParent: Handle, toName: String
        switch locate(destination) {
            case .success(let found): (toParent, toName) = found
            case .failure(let problem): return problem.outcome
        }
        guard kind(of: toName, in: toParent) == nil else { return .refused("An item already exists at \(destination.shown).") }
        if let spent = try exhausted(call) { return spent }
        // One rename, atomic, that never replaces.
        guard renameatx_np(fromParent.fd, fromName, toParent.fd, toName, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            return code == EEXIST
                ? .refused("An item appeared at \(destination.shown) meanwhile; nothing was moved.")
                : .refused("\(source.shown) could not be moved: \(Self.message(code)); nothing was changed.")
        }
        let result = JSONValue.object(["from": .string(source.shown), "to": .string(destination.shown)])
        return await .afterChange("The item was moved", look: "List both folders", result: result) {
            guard kind(of: toName, in: toParent) != nil, kind(of: fromName, in: fromParent) == nil else {
                return AdapterOutcome(.actedUnverified, "The item did not read back at its new path.", result: result)
            }
            return .confirmed("Moved to \(destination.shown).", result)
        }
    }

    /// Writes `text` as a new file, or over an existing one when `overwrite` is true: the bytes go to a temporary
    /// name beside it, then are published at once, exclusively for a new file and by rename for a replacement.
    private func write(_ path: String, text: String, overwrite: Bool, _ call: Call) async throws -> AdapterOutcome {
        guard text.utf8.count <= Self.maximumTextBytes else {
            return .refused("The text is \(text.utf8.count) bytes, over the \(Self.maximumTextBytes) this adapter writes.")
        }
        let location: Location
        switch resolve(path, call) {
            case .success(let found): location = found
            case .failure(let problem): return problem.outcome
        }
        let parent: Handle, name: String
        switch locate(location) {
            case .success(let found): (parent, name) = found
            case .failure(let problem): return problem.outcome
        }
        let existing = kind(of: name, in: parent)
        switch existing {
            case nil:
                break
            case .file?:
                guard overwrite else { return .refused("\(location.shown) already exists; pass overwrite true to replace it.") }
            case .folder?:
                return .refused("\(location.shown) is a folder.")
            case .link?:
                return .refused("\(location.shown) is a symbolic link; the files adapter writes through none.")
            case .other?:
                return .refused("\(location.shown) is not a plain file.")
        }
        let bytes = Data(text.utf8)
        if let spent = try exhausted(call) { return spent }
        // A file that is not there is made exclusively, overwrite or not; one that is, with overwrite, is replaced.
        let replacing = overwrite && existing != nil
        if case .failure(let problem) = try publish(bytes, as: name, in: parent, at: location, replacing: replacing, call) {
            return problem.outcome
        }
        let result = JSONValue.object(["path": .string(location.shown), "bytes": .number(Double(bytes.count))])
        return await .afterChange("The file was written", look: "Read the file", result: result) {
            guard case .success(let read) = try wholeBytes(of: location, limit: Self.maximumFileBytes, doing: "reads back", call),
                  read == bytes else {
                return AdapterOutcome(.actedUnverified, "The file did not read back equal to the text.", result: result)
            }
            return .confirmed("Wrote \(bytes.count) bytes to \(location.shown).", result)
        }
    }

    /// Appends in place, with `O_APPEND`, which adds and never destroys; a write that stops short, cancelled or out
    /// of time included, has appended that much and is said as such.
    private func append(_ path: String, text: String, _ call: Call) async throws -> AdapterOutcome {
        guard text.utf8.count <= Self.maximumTextBytes else {
            return .refused("The text is \(text.utf8.count) bytes, over the \(Self.maximumTextBytes) this adapter appends.")
        }
        let location: Location
        switch resolve(path, call) {
            case .success(let found): location = found
            case .failure(let problem): return problem.outcome
        }
        let before: Data
        switch try wholeBytes(of: location, limit: Self.maximumFileBytes, doing: "appends to", call) {
            case .success(let bytes): before = bytes
            case .failure(.missing): return .missing("No file at \(location.shown); write makes one.")
            case .failure(let problem): return problem.outcome
        }
        let file: Handle
        switch openFile(location, flags: O_WRONLY | O_APPEND) {
            case .success(let opened): file = opened.file
            case .failure(let problem): return problem.outcome
        }
        let bytes = Data(text.utf8)
        if let spent = try exhausted(call) { return spent }
        let result = JSONValue.object(["path": .string(location.shown), "bytes": .number(Double(bytes.count)),
                                       "size": .number(Double(before.count + bytes.count))])
        if case .stopped(let written, let why) = Self.writeAll(bytes, to: file, call) {
            return AdapterOutcome(.actedUnverified, "The append to \(location.shown) stopped after \(written) of \(bytes.count) bytes (\(why)). Read the file before appending again.", result: result)
        }
        return await .afterChange("The text was appended", look: "Read the file", result: result) {
            guard case .success(let read) = try wholeBytes(of: location, limit: Self.maximumFileBytes + Self.maximumTextBytes, doing: "reads back", call),
                  read == before + bytes else {
                return AdapterOutcome(.actedUnverified, "The file did not read back as what it was plus the text.", result: result)
            }
            return .confirmed("Appended \(bytes.count) bytes to \(location.shown).", result)
        }
    }

    /// Replaces the one occurrence of `find` with `replace`, bytes for bytes, published by rename; `find` occurring
    /// more or less than once refuses with the count, nothing written.
    private func edit(_ path: String, find: String, replace: String, _ call: Call) async throws -> AdapterOutcome {
        guard find.utf8.count <= Self.maximumTextBytes, replace.utf8.count <= Self.maximumTextBytes else {
            return .refused("The texts are over the \(Self.maximumTextBytes) bytes this adapter edits with.")
        }
        let location: Location
        switch resolve(path, call) {
            case .success(let found): location = found
            case .failure(let problem): return problem.outcome
        }
        let before: Data
        switch try wholeBytes(of: location, limit: Self.maximumFileBytes, doing: "edits", call) {
            case .success(let bytes): before = bytes
            case .failure(let problem): return problem.outcome
        }
        guard String(data: before, encoding: .utf8) != nil else { return .refused("\(location.shown) is not a UTF-8 text file.") }
        let occurrences = Self.occurrences(of: Data(find.utf8), in: before)
        guard occurrences.count == 1, let range = occurrences.first else {
            return .refused("The text to replace occurs \(occurrences.count) times in \(location.shown); it must occur exactly once. Nothing was changed.")
        }
        var expected = before
        expected.replaceSubrange(range, with: Data(replace.utf8))
        let parent: Handle, name: String
        switch locate(location) {
            case .success(let found): (parent, name) = found
            case .failure(let problem): return problem.outcome
        }
        if let spent = try exhausted(call) { return spent }
        if case .failure(let problem) = try publish(expected, as: name, in: parent, at: location, replacing: true, call) {
            return problem.outcome
        }
        let result = JSONValue.object(["path": .string(location.shown), "size": .number(Double(expected.count))])
        return await .afterChange("The text was replaced", look: "Read the file", result: result) {
            guard case .success(let read) = try wholeBytes(of: location, limit: Self.maximumFileBytes + Self.maximumTextBytes, doing: "reads back", call),
                  read == expected else {
                return AdapterOutcome(.actedUnverified, "The file did not read back with the one replacement.", result: result)
            }
            return .confirmed("Replaced one occurrence in \(location.shown).", result)
        }
    }

    /// The Trash is reached by path, FileManager's only way: the item is checked under its parent, never through a
    /// link, right before; the moment between is the one gap of this adapter, said here.
    private func moveToTrash(_ path: String, _ call: Call) async throws -> AdapterOutcome {
        let location: Location
        switch resolve(path, call) {
            case .success(let found): location = found
            case .failure(let problem): return problem.outcome
        }
        guard !location.isRoot else { return .refused("The home folder itself cannot go to the Trash.") }
        let parent: Handle, name: String
        switch locate(location) {
            case .success(let found): (parent, name) = found
            case .failure(let problem): return problem.outcome
        }
        guard kind(of: name, in: parent) != nil else { return .missing("No item at \(location.shown).") }
        if let spent = try exhausted(call) { return spent }
        let result = JSONValue.object(["path": .string(location.shown)])
        return await .afterChange("The item went to the Trash", look: "List its folder", result: result) {
            let trashed = try trash(url(of: location))
            guard kind(of: name, in: parent) == nil, let trashed, FileManager.default.fileExists(atPath: trashed.path) else {
                return AdapterOutcome(.actedUnverified, "The item did not read back in the Trash.", result: result)
            }
            return .confirmed("Moved \(location.shown) to the Trash.", .object(["path": .string(location.shown), "trash": .string(trashed.path)]))
        }
    }

    // MARK: Publishing bytes

    /// Writes `bytes` whole to a temporary name in `parent`, then publishes them as `name`: by a hard link, which
    /// never replaces, for a new file; by rename, atomic, for a replacement. The temporary file is the owner's alone
    /// (`0600`) while it is written; a new file stays so, and a replacement takes the permission bits of the file it
    /// replaces, read under the parent right before (`fstatat`, `fchmod`), so a private file stays private and a
    /// script stays executable; those bits unreadable or not applied refuse with the old file untouched. The time and
    /// the task are checked on every chunk and once more right before the publication. Any failure, a cancellation
    /// included, removes the temporary file (`defer`) and leaves what was at `name` as it was: a refusal has changed
    /// nothing visible, and a cancellation is thrown with the old bytes intact.
    private func publish(_ bytes: Data, as name: String, in parent: Handle, at location: Location, replacing: Bool,
                         _ call: Call) throws -> Result<Void, PathProblem> {
        let temporary = ".braus-\(UUID().uuidString).tmp"
        let fd = openat(parent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .failure(.refused("\(location.shown) could not be written beside: \(Self.message(errno)); nothing was changed."))
        }
        let file = Handle(fd)
        // Once published by rename the temporary name is gone and the unlink finds nothing; on every other path it
        // removes what was written.
        defer { _ = unlinkat(parent.fd, temporary, 0) }
        if replacing {
            var status = stat()
            guard fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
                return .failure(.refused("\(location.shown) is not the plain file it was; nothing was changed."))
            }
            guard fchmod(fd, status.st_mode & 0o7777) == 0 else {
                return .failure(.refused("\(location.shown): its permissions could not be kept (\(Self.message(errno))); nothing was changed."))
            }
        }
        switch Self.writeAll(bytes, to: file, call) {
            case .stopped(let written, let why) where why == "cancelled":
                _ = written
                throw CancellationError()
            case .stopped(let written, let why):
                return .failure(.refused("\(location.shown) could not be written (\(written) of \(bytes.count) bytes, \(why)); nothing was changed."))
            case .whole:
                break
        }
        if let spent = try exhausted(call) { return .failure(.refused(spent.message)) }
        let published = replacing
            ? renameat(parent.fd, temporary, parent.fd, name)
            : linkat(parent.fd, temporary, parent.fd, name, 0)
        let code = errno
        guard published == 0 else {
            switch code {
                case EEXIST : return .failure(.refused("\(location.shown) appeared meanwhile; nothing was written."))
                case EISDIR, ENOTDIR: return .failure(.refused("\(location.shown) is a folder now; nothing was written."))
                default     : return .failure(.refused("\(location.shown) could not be published: \(Self.message(code)); nothing was changed."))
            }
        }
        return .success(())
    }

    /// How a write of every byte ended: whole, or stopped after some, with why (cancelled, out of time, an error).
    enum WriteEnd: Equatable {
        case whole
        case stopped(written: Int, why: String)
    }

    /// Writes every byte, the time and the task checked before each chunk, an interrupted write retried.
    private static func writeAll(_ bytes: Data, to file: Handle, _ call: Call) -> WriteEnd {
        var written = 0
        return bytes.withUnsafeBytes { buffer -> WriteEnd in
            while written < bytes.count {
                if Task.isCancelled { return .stopped(written: written, why: "cancelled") }
                if call.budget.expired { return .stopped(written: written, why: "ran out of time") }
                let wrote = Darwin.write(file.fd, buffer.baseAddress! + written, min(bytes.count - written, 65_536))
                if wrote < 0, errno == EINTR { continue }
                // Nothing written and no error is a write that goes nowhere: stopped at once, not tried until the time ends.
                guard wrote > 0 else { return .stopped(written: written, why: wrote < 0 ? message(errno) : "the write took no bytes") }
                written += wrote
            }
            return .whole
        }
    }

    /// The ranges of `needle` in `data`, in order, not overlapping; none for an empty needle.
    static func occurrences(of needle: Data, in data: Data) -> [Range<Data.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<Data.Index>] = []
        var from = data.startIndex
        while from < data.endIndex, let found = data.range(of: needle, in: from..<data.endIndex) {
            ranges.append(found)
            from = found.upperBound
        }
        return ranges
    }
}
