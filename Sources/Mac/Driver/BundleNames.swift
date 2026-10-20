import Foundation

/// BundleNames reads an application's names from its own bundle, in the person's languages: pure metadata, no launch,
/// no permission. A command-line process has no localizations of its own, so AppKit answers in English; this reads the
/// app's tables directly: the system apps' `InfoPlist.loctable` (every language in one file), else
/// `<language>.lproj/InfoPlist.strings`. The launcher and the Seat read the same names through it.
public enum BundleNames {

    /// One table per language of `languages` the bundle localizes, in that order, each localization once ("en-IT" and
    /// "en-US" both read "en"); a language the bundle does not localize reads nothing of its own. Nothing is kept
    /// between calls: a bundle updated or reinstalled is read as it is now.
    public static func tables(of bundle: Bundle, for languages: [String]) -> [[String: String]] {
        let available = bundle.localizations
        let loctable = bundle.url(forResource: "InfoPlist", withExtension: "loctable")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: Any] }
        var seen: Set<String> = []
        var tables: [[String: String]] = []
        for language in languages {
            guard let localization = Bundle.preferredLocalizations(from: available, forPreferences: [language]).first,
                  seen.insert(localization).inserted else { continue }
            if let names = loctable?[localization] as? [String: String] {
                tables.append(names)
            } else if let url = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil,
                                           localization: localization),
                      let names = NSDictionary(contentsOf: url) as? [String: String] {
                tables.append(names)
            }
        }
        return tables
    }

    /// The display name and the bundle name of each of `tables(of:for:)`, in that order, empty names and repeats
    /// left out.
    public static func names(of bundle: Bundle, for languages: [String]) -> [String] {
        var names: [String] = []
        for table in tables(of: bundle, for: languages) {
            for case let name? in [table["CFBundleDisplayName"], table["CFBundleName"]]
            where !name.isEmpty && !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}
