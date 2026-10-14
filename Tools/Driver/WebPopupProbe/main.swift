//
//  main.swift
//  WebPopupProbe
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import AppKit

// Switches: --open panel|sheet|modal|popover, --token <token> (or WEBPOPUP_PROBE_TOKEN), --self-test.
let arguments = CommandLine.arguments

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("WebPopupProbe: \(message)\n".utf8))
    exit(64)
}

let token = (option("--token") ?? ProcessInfo.processInfo.environment["WEBPOPUP_PROBE_TOKEN"] ?? "default")
    .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
let launchSurface = option("--open").map { name -> ProbeSurface in
    guard let surface = ProbeSurface(rawValue: name) else { fail("unknown surface '\(name)'") }
    return surface
}
let isSelfTest = arguments.contains("--self-test")
if isSelfTest && launchSurface == nil { fail("--self-test needs --open <surface>") }

let delegate = ProbeController(log: ProbeLog(token: token), launchSurface: launchSurface, isSelfTest: isSelfTest)
let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
