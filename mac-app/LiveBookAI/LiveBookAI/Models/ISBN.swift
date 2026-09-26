import Foundation

/// ISBN / EAN identifiers recognized from OCR text.
struct ISBN: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case isbn10
        case isbn13
        case ean13
    }

    /// Raw digits without separators (e.g. "9787108025302").
    let digits: String
    let kind: Kind
    /// True when the checksum is valid.
    let isValid: Bool
    /// Human-readable display (with hyphens when known).
    let display: String

    var isISBN: Bool {
        kind == .isbn10 || kind == .isbn13
    }
}

/// ISBN-10 / ISBN-13 / EAN-13 parser with checksum validation.
enum ISBNParser {
    /// Parses the first valid ISBN/EAN found inside an arbitrary string.
    static func parse(from text: String) -> ISBN? {
        let normalized = text.uppercased()
        // ISBN-13 / EAN-13: 13 digits, optional 'X' not allowed.
        if let m = matchDigits(in: normalized, exactly: 13) {
            if let isbn = makeISBN(digits: m, kind: .isbn13) ?? makeISBN(digits: m, kind: .ean13) {
                return isbn
            }
        }
        // ISBN-10: 10 digits, last char may be 'X'.
        if let m = matchISBN10(in: normalized) {
            return makeISBN(digits: m, kind: .isbn10)
        }
        // Try raw digit sequences with length 13 then 10 (fallback without 'ISBN' prefix).
        let digitOnly = normalized.filter(\.isNumber)
        if digitOnly.count == 13 {
            if let isbn = makeISBN(digits: digitOnly, kind: .isbn13) ?? makeISBN(digits: digitOnly, kind: .ean13) {
                return isbn
            }
        }
        if digitOnly.count == 10 {
            return makeISBN(digits: digitOnly, kind: .isbn10)
        }
        return nil
    }

    /// ISBN-10 checksum: (d1*10 + d2*9 + ... + d10*1) % 11 == 0, d10 may be 'X' (==10).
    static func isbn10ChecksumValid(_ digits: String) -> Bool {
        let chars = Array(digits.uppercased())
        guard chars.count == 10 else { return false }
        var sum = 0
        for (index, ch) in chars.enumerated() {
            let weight = 10 - index
            if index == 9, ch == "X" {
                sum += 10 * weight
                continue
            }
            guard let d = ch.wholeNumberValue, (0...9).contains(d) else { return false }
            sum += d * weight
        }
        return sum % 11 == 0
    }

    /// ISBN-13 / EAN-13 checksum: alternating weights 1/3/1/3..., sum % 10 == 0.
    static func isbn13ChecksumValid(_ digits: String) -> Bool {
        guard digits.count == 13, digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (index, ch) in digits.enumerated() {
            guard let d = ch.wholeNumberValue else { return false }
            let weight = index % 2 == 0 ? 1 : 3
            sum += d * weight
        }
        return sum % 10 == 0
    }

    // MARK: - Private

    private static func matchDigits(in text: String, exactly count: Int) -> String? {
        let pattern = "(?:ISBN(?:-1[03])?:?\\s*)?[0-9][0-9\\-\\s]{\(count - 1),}[0-9X]"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let candidate = String(text[range])
        let digits = candidate.filter { $0.isNumber || $0 == "X" }
        guard digits.count == count else { return nil }
        return digits
    }

    private static func matchISBN10(in text: String) -> String? {
        let pattern = "(?:ISBN(?:-10)?:?\\s*)?[0-9][0-9\\-\\s]{8,}[0-9X]"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let candidate = String(text[range])
        let digits = candidate.filter { $0.isNumber || $0 == "X" }
        guard digits.count == 10 else { return nil }
        return digits
    }

    private static func makeISBN(digits: String, kind: ISBN.Kind) -> ISBN? {
        switch kind {
        case .isbn10:
            guard isbn10ChecksumValid(digits) else { return nil }
        case .isbn13:
            // ISBN-13 must start with 978 or 979.
            guard digits.hasPrefix("978") || digits.hasPrefix("979") else { return nil }
            guard isbn13ChecksumValid(digits) else { return nil }
        case .ean13:
            guard !(digits.hasPrefix("978") || digits.hasPrefix("979")) else { return nil }
            guard isbn13ChecksumValid(digits) else { return nil }
        }
        return ISBN(digits: digits, kind: kind, isValid: true, display: displayString(digits, kind: kind))
    }

    private static func displayString(_ digits: String, kind: ISBN.Kind) -> String {
        switch kind {
        case .isbn10:
            if digits.count == 10 {
                return "ISBN \(digits.prefix(1))-\(digits.dropFirst(1).prefix(4))-\(digits.dropFirst(5).prefix(3))-\(digits.suffix(1))"
            }
            return digits
        case .isbn13:
            if digits.count == 13 {
                return "ISBN \(digits.prefix(3))-\(digits.dropFirst(3).prefix(1))-\(digits.dropFirst(4).prefix(4))-\(digits.dropFirst(8).prefix(4))-\(digits.suffix(1))"
            }
            return digits
        case .ean13:
            return "EAN \(digits)"
        }
    }
}
