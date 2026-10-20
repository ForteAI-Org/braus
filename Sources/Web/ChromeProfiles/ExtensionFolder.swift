//
//  ExtensionFolder.swift
//  Braus
//

import Foundation

/// ExtensionFolder is the folder of the Braus extension the person loads in Chrome (Load unpacked): a copy, in
/// Braus's own folder, of the extension the app carries. Chrome's folder picker does not open an app bundle,
/// and a new version of the app replaces its own copy, so the person loads this one.
///
/// It is prepared only when asked. A marker file says Braus prepared it; a folder without one, or a link, is not
/// Braus's and stays as it is. Preparing again brings an earlier copy up to date, file by file.
public struct ExtensionFolder: Sendable {

    public static let files = ["manifest.json", "background.js", "pair.html", "pair.js"]
    static let marker = ".braus-extension"

    /// The extension the app carries.
    public let source: URL
    /// The folder the person loads.
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source      = source
        self.destination = destination
    }

    public enum State: Sendable, Equatable {
        /// This copy of Braus carries no extension.
        case notBundled
        case notPrepared
        /// Prepared, with the files the app carries.
        case current
        /// Prepared from another version of the app: preparing again updates it.
        case outdated
        /// Something Braus did not prepare is there, and stays.
        case foreign(String)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notBundled
        case foreign(String)
        case notWritten(String)

        public var description: String {
            switch self {
                case .notBundled           : "this copy of Braus carries no Chrome extension"
                case .foreign(let reason)  : "Braus left the folder as it is: \(reason)"
                case .notWritten(let cause): "Braus could not prepare the folder: \(cause)"
            }
        }
    }

    /// The folder as it is now. Reads only.
    public func state() -> State {
        guard Self.files.allSatisfy({ NativeHostRegistration.kind(of: source.appending(path: $0)) == .other }) else {
            return .notBundled
        }
        switch NativeHostRegistration.kind(of: destination) {
            case .missing  : return .notPrepared
            case .directory: break
            case .link     : return .foreign("\(destination.lastPathComponent) is a link")
            case .other    : return .foreign("\(destination.lastPathComponent) is not a folder")
        }
        guard NativeHostRegistration.kind(of: destination.appending(path: Self.marker)) == .other else {
            return .foreign("\(destination.lastPathComponent) was not prepared by Braus")
        }
        // Every file is read before deciding: one that is not Braus's keeps the whole folder as it is, even after
        // another that is only out of date.
        var isOutdated = false
        for file in Self.files {
            let copy = destination.appending(path: file)
            switch NativeHostRegistration.kind(of: copy) {
                case .missing:
                    isOutdated = true
                case .other:
                    if (try? Data(contentsOf: source.appending(path: file))) != (try? Data(contentsOf: copy)) {
                        isOutdated = true
                    }
                case .link, .directory:
                    return .foreign("\(file) in it is not a file Braus wrote")
            }
        }
        return isOutdated ? .outdated : .current
    }

    /// Prepares the folder, or updates an earlier copy. Does nothing when it is current; throws, writing nothing,
    /// when the app carries no extension or the folder is not Braus's.
    @discardableResult
    public func prepare() throws -> State {
        switch state() {
            case .current            : return .current
            case .notBundled         : throw Failure.notBundled
            case .foreign(let reason): throw Failure.foreign(reason)
            case .notPrepared, .outdated: break
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let marker = destination.appending(path: Self.marker)
            if NativeHostRegistration.kind(of: marker) == .missing {
                try Data("Prepared by Braus from the extension it carries; preparing again replaces these files.\n"
                    .utf8).write(to: marker, options: .withoutOverwriting)
            }
            for file in Self.files {
                try Data(contentsOf: source.appending(path: file))
                    .write(to: destination.appending(path: file), options: .atomic)
            }
        } catch {
            throw Failure.notWritten(error.localizedDescription)
        }
        return state()
    }
}
