//
//  main.swift
//  Braus
//

import Foundation

// Chrome's native messaging host for the Braus extension. Chrome starts one for each extension instance that
// connects, that is for each Chrome profile the extension runs in, and passes the caller's origin as an argument.
// It relays, unchanged, between:
// - Chrome on stdin and stdout: each message a 4-byte length in native byte order, then UTF-8 JSON (at most 1 MB
//   toward Chrome);
// - the app's `ChromeProfileHub` on its Unix socket, one JSON object per line.
// The socket is `<Application Support>/Braus/ChromeProfiles/hub.sock` unless `--socket <path>` names another (a
// test fixture's wrapper does). Its directory must belong to this user with mode 0700, or nothing is connected.
// The host interprets nothing: the extension checks every command against its instance and pairing, and the hub
// routes by instance and tab. It ends when either end closes.

func socketPath(_ arguments: [String]) -> String {
    if let flag = arguments.firstIndex(of: "--socket"), arguments.indices.contains(flag + 1) {
        return arguments[flag + 1]
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Braus/ChromeProfiles/hub.sock").path(percentEncoded: false)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("braus-chrome-host: \(message)\n".utf8))
    exit(1)
}

/// Connects to the hub after checking that only this user can reach its directory.
func connectHub(_ path: String) -> Int32 {
    var info = stat()
    let directory = (path as NSString).deletingLastPathComponent
    guard stat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
        fail("\(directory) is not private to this user (0700)")
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0, path.utf8.count < 104 else { fail("no socket for \(path)") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { fail("Braus is not listening at \(path)") }
    // A write after Braus closed must fail and end the relay, not raise SIGPIPE.
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return descriptor
}

/// Reads exactly `count` bytes from `descriptor`, or nil at its end.
func readExactly(_ descriptor: Int32, _ count: Int) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: max(count, 1))
    while data.count < count {
        let wanted = count - data.count
        let got = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, min(wanted, $0.count)) }
        if got <= 0 { return nil }
        data.append(contentsOf: buffer[0..<got])
    }
    return data
}

func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return true }
        var offset = 0
        while offset < bytes.count {
            let written = write(descriptor, base + offset, bytes.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

// A write after Chrome closed the pipe must fail and end the relay, not raise SIGPIPE.
_ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
let hub = connectHub(socketPath(Array(CommandLine.arguments.dropFirst())))
let done = DispatchSemaphore(value: 0)

// Chrome to the hub: a native message becomes one line.
Thread {
    while let header = readExactly(STDIN_FILENO, 4) {
        let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
        guard let body = readExactly(STDIN_FILENO, length), (try? JSONSerialization.jsonObject(with: body)) != nil,
              writeAll(hub, body + Data([0x0A]))
        else { break }
    }
    done.signal()
}.start()

// The hub to Chrome: a line becomes one native message.
Thread {
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    reading: while true {
        let got = buffer.withUnsafeMutableBytes { read(hub, $0.baseAddress, $0.count) }
        if got <= 0 { break }
        pending.append(contentsOf: buffer[0..<got])
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= 1024 * 1024 else { break reading }
            var length = UInt32(line.count)
            let header = Data(bytes: &length, count: 4)
            guard writeAll(STDOUT_FILENO, header + line) else { break reading }
        }
    }
    done.signal()
}.start()

done.wait()
close(hub)
exit(0)
