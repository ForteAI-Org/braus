//
//  WebSecureFields.swift
//  Braus
//

import Foundation
import Memory

/// WebSecureFields decides which inputs hold a secret whose value Braus never reads: it is never in a
/// scene, so never in the memory, and no script reads it back. The decision comes from the input's own
/// attributes, never from a label:
///
/// - `type=password`;
/// - an `autocomplete` token among `secretAutocomplete`: a password, a one-time code, or a card's
///   number, security code or expiry;
/// - a `name` or `id` whose words spell one of `secretNames`: a password, a one-time or verification
///   code, a card's number, security code or expiry.
///
/// A name is read as words, split where a character is not an ASCII letter or digit and where a
/// lowercase letter or a digit meets an uppercase one (`card_number`, `cardNumber`, `CARD-NUMBER`), and
/// one of `secretNames` matches only one word or a run of whole words. So `zipcode`, `phone_number`,
/// `order_no`, `pincode`, `promo_code`, `card_holder` or `quantity` stay ordinary fields, and neither
/// `pin` nor `code` alone counts: a postal PIN code and a promotion code are not secrets. Only a
/// text-like input counts by its autocomplete or its name: a checkbox named `otp` holds no secret.
///
/// `function` is the same rule in JavaScript, for the scripts that read values in the page. A secret
/// field named for nothing and without these tokens (six bare digit boxes) is not recognized.
enum WebSecureFields {

    static let secretAutocomplete = SensitivityRules.bundled.markup.secretAutocomplete
    static let secretNames = SensitivityRules.bundled.markup.secretNames
    static let nonTextTypes = SensitivityRules.bundled.markup.nonTextTypes

    /// Whether an element with tag `tag` and these attributes, by lowercase name, is a secure field.
    static func isSecure(
        tag       : String,
        attributes: [String: String]
    ) -> Bool {
        guard tag.uppercased() == "INPUT" else { return false }
        func value(_ name: String) -> String {
            (attributes[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let type = value("type")
        if type == "password" { return true }
        if nonTextTypes.contains(type) { return false }
        let tokens = value("autocomplete").split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.contains(where: secretAutocomplete.contains) { return true }
        return isSecretName(attributes["name"] ?? "") || isSecretName(attributes["id"] ?? "")
    }

    /// Whether one word of `text`, or a run of its whole words written together, is among `secretNames`.
    static func isSecretName(_ text: String) -> Bool {
        let words = words(text)
        for start in words.indices {
            var run = ""
            for word in words[start...] {
                run += word
                if secretNames.contains(run) { return true }
            }
        }
        return false
    }

    /// The words of a name or an id, lowercased, as `function` reads them.
    static func words(_ text: String) -> [String] {
        func isLowerOrDigit(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        var spaced   = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if let previous, isLowerOrDigit(previous), ("A"..."Z").contains(scalar) { spaced.append(" ") }
            spaced.append(scalar)
            previous = scalar
        }
        var words: [String] = []
        var word  = ""
        for scalar in String(spaced).lowercased().unicodeScalars {
            if isLowerOrDigit(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// `isSecure` as a JavaScript function of an element, reading the same attributes the same way.
    static let function: String = {
        func list(_ names: Set<String>) -> String {
            do { return String(decoding: try JSONEncoder().encode(names.sorted()), as: UTF8.self) }
            catch { preconditionFailure("Cannot encode secure markup rules: \(error)") }
        }
        return """
        ((e) => {
          if (!e || !e.tagName || e.tagName.toUpperCase() !== 'INPUT') return false;
          const attribute = n => (e.getAttribute(n) || '').trim().toLowerCase();
          const type = attribute('type');
          if (type === 'password') return true;
          if (\(list(nonTextTypes)).includes(type)) return false;
          const tokens = attribute('autocomplete').split(/\\s+/);
          if (tokens.some(t => \(list(secretAutocomplete)).includes(t))) return true;
          const secret = \(list(secretNames));
          const named = text => {
            const words = (text || '').replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/).filter(w => w);
            for (let start = 0; start < words.length; start++) {
              let run = '';
              for (let i = start; i < words.length; i++) { run += words[i]; if (secret.includes(run)) return true; }
            }
            return false;
          };
          return named(e.getAttribute('name')) || named(e.getAttribute('id'));
        })
        """
    }()
}
