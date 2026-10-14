//
//  ChromeProcess.swift
//  Braus
//

import Darwin
import Foundation

/// ChromeProcess is one Chrome this process started with `--remote-debugging-pipe`, and the
/// transport over its two pipes.
///
/// The child inherits only standard input, output and error (on `/dev/null` or the chosen log)
/// and descriptors 3 and 4; every other descriptor of this process stays closed to it. Chrome
/// runs in its own process group, so `terminate` reaches its helpers too.
actor ChromeProcess {

    let processID: pid_t
    nonisolated let transport: PipeTransport

    private var hasExited = false

    private init(processID: pid_t, transport: PipeTransport) {
        self.processID = processID
        self.transport = transport
    }

    /// Starts Chrome. Throws `CDPError.launchFailed` before any effect when the binary is
    /// missing, or with the spawn's error; nothing is left running or open after a throw.
    static func spawn(_ options: ChromeLaunchOptions) throws -> ChromeProcess {
        let executable = options.executableURL.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CDPError.launchFailed("no executable at \(executable)")
        }
        try FileManager.default.createDirectory(at: options.userDataDirectory, withIntermediateDirectories: true)

        // Chrome reads commands on its fd 3 and writes answers on its fd 4.
        let toChrome   = try makePipe()
        let fromChrome = try makePipe()
        var spawned    = false
        defer {
            Darwin.close(toChrome.read)
            Darwin.close(fromChrome.write)
            if !spawned {
                Darwin.close(toChrome.write)
                Darwin.close(fromChrome.read)
            }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let errorPath = options.standardErrorURL?.path(percentEncoded: false) ?? "/dev/null"
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, errorPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, toChrome.read, 3)
        posix_spawn_file_actions_adddup2(&actions, fromChrome.write, 4)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + options.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var processID: pid_t = 0
        let status = posix_spawn(&processID, executable, &actions, &attributes, argv, environ)
        guard status == 0 else {
            throw CDPError.launchFailed("posix_spawn failed: \(String(cString: strerror(status)))")
        }
        spawned = true

        // A write after Chrome died must fail, not raise SIGPIPE in this process.
        _ = fcntl(toChrome.write, F_SETNOSIGPIPE, 1)
        let transport = PipeTransport(
            toBrowser  : FileHandle(fileDescriptor: toChrome.write, closeOnDealloc: true),
            fromBrowser: FileHandle(fileDescriptor: fromChrome.read, closeOnDealloc: true)
        )
        return ChromeProcess(processID: processID, transport: transport)
    }

    /// Asks Chrome to quit with SIGTERM, waits up to `graceSeconds` for it, then kills its
    /// process group. Returns once the process is reaped. Idempotent.
    func terminate(graceSeconds: Double = 5) async {
        transport.close()
        guard !hasExited else { return }
        kill(processID, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            if reap(blocking: false) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        kill(-processID, SIGKILL)
        _ = reap(blocking: true)
    }

    /// Whether Chrome has exited, reaping it when it has.
    func isRunning() -> Bool {
        !hasExited && !reap(blocking: false)
    }

    private func reap(blocking: Bool) -> Bool {
        var status: Int32 = 0
        let result = waitpid(processID, &status, blocking ? 0 : WNOHANG)
        if result == processID || (result == -1 && errno == ECHILD) { hasExited = true }
        return hasExited
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw CDPError.launchFailed("pipe failed: \(String(cString: strerror(errno)))")
        }
        // Move both ends above the child's 0 to 4: a dup2 onto its own number keeps
        // close-on-exec, so an end that was already 3 or 4 would never reach Chrome.
        let moved = descriptors.map { descriptor in
            defer { Darwin.close(descriptor) }
            return fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
        }
        guard moved.allSatisfy({ $0 >= 0 }) else {
            moved.filter { $0 >= 0 }.forEach { Darwin.close($0) }
            throw CDPError.launchFailed("could not move the pipe: \(String(cString: strerror(errno)))")
        }
        return (moved[0], moved[1])
    }
}
