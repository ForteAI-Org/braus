//
//  Scratch.swift
//  Braus
//
//  Created by Eliomar Rodriguez on 15/10/2026.
//

import Foundation
import Synchronization

/// Scratch is where tests put the folders they write. Every folder lives under one root of the test process,
/// removed when the process exits; a root left by a process that died first is removed by the next process
/// that asks for a folder. A test never has to remove what it asked for, and a folder it hands on to a
/// service or a store outlives the test that made it, until the process ends.
public enum Scratch {

    /// A path of its own, named `prefix-N`, under the process's root. Nothing is created at the path itself. A
    /// count, not a UUID: a path a test hands to the memory as a value must not read as a secret, or it is withheld.
    public static func directory(_ prefix: String) -> URL {
        root.appendingPathComponent("\(prefix)-\(issued.add(1, ordering: .relaxed).newValue)", isDirectory: true)
    }

    private static let issued = Atomic(0)

    private static let marker = "braus-tests-"

    private static let root: URL = {
        let files     = FileManager.default
        let temporary = files.temporaryDirectory
        for name in (try? files.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix(marker) {
            guard let pid = pid_t(name.dropFirst(marker.count)), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? files.removeItem(at: temporary.appendingPathComponent(name))
        }
        atexit {
            let files = FileManager.default
            try? files.removeItem(at: files.temporaryDirectory.appendingPathComponent("braus-tests-\(getpid())"))
        }
        let root = temporary.appendingPathComponent(marker + String(getpid()), isDirectory: true)
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()
}
