//
//  ProbeLog.swift
//  WebPopupProbe
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import Foundation

/// ProbeLog keeps every event of one run as a JSON array in `/tmp/webpopup-probe-<token>.json`.
///
/// The file is truncated at launch and rewritten atomically after each event, so a reader
/// always sees a complete, valid document. Main thread only.
final class ProbeLog {

    private let url    : URL
    private var events : [[String: Any]] = []

    init(token: String) {
        url = URL(fileURLWithPath: "/tmp/webpopup-probe-\(token).json")
        flush()
    }

    func append(_ event: [String: Any]) {
        var stamped = event
        stamped["seq"] = events.count
        events.append(stamped)
        flush()
    }

    private func flush() {
        guard JSONSerialization.isValidJSONObject(events),
              let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
        else {
            FileHandle.standardError.write(Data("WebPopupProbe: event not serializable\n".utf8))
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("WebPopupProbe: cannot write \(url.path): \(error)\n".utf8))
        }
    }
}
