import Foundation

/// Checksums validates ASCII card numbers and international bank account numbers locally.
enum Checksums {
    static func luhn(_ value: String) -> Bool {
        let digits = value.filter { $0 != " " && $0 != "-" }
        guard (12...19).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) }),
              Set(digits).count > 1 else { return false }
        var sum = 0
        for (index, byte) in digits.utf8.reversed().enumerated() {
            var digit = Int(byte - 48)
            if index % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
            sum += digit
        }
        return sum % 10 == 0
    }

    static func iban(_ value: String) -> Bool {
        let bytes = Array(value.uppercased().filter { $0 != " " }.utf8)
        guard (15...34).contains(bytes.count), bytes.prefix(2).allSatisfy({ (65...90).contains($0) }),
              bytes[2...3].allSatisfy({ (48...57).contains($0) }),
              bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return false }
        var remainder = 0
        for byte in Array(bytes.dropFirst(4)) + bytes.prefix(4) {
            let number = byte >= 65 ? Int(byte - 65) + 10 : Int(byte - 48)
            remainder = (remainder * (number >= 10 ? 100 : 10) + number) % 97
        }
        return remainder == 1
    }
}
