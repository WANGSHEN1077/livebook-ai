import Foundation

/// Fuzzy text matcher used to decide whether OCR output "contains" an expected book title.
enum TitleMatcher {
    /// Normalize: lowercase, strip punctuation/whitespace.
    static func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        let allowed = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(allowed))
    }

    /// Returns true when `ocr` plausibly contains the expected `title`.
    /// Strategy: normalized containment (either direction) or high token overlap.
    static func matches(ocr: String, expectedTitle: String) -> Bool {
        let nOCR = normalize(ocr)
        let nTitle = normalize(expectedTitle)
        guard !nOCR.isEmpty, !nTitle.isEmpty else { return false }

        // Direct containment both ways handles "Shakespeare, In Fact" and Chinese subtitles.
        if nOCR.contains(nTitle) || nTitle.contains(nOCR) { return true }

        // Token overlap: expected title words mostly present.
        let tokens = Set(nTitle.split(separator: " "))
        guard !tokens.isEmpty else { return false }
        let present = tokens.filter { nOCR.contains(String($0)) }.count
        return Double(present) / Double(tokens.count) >= 0.7
    }

    /// Best overlapping substring overlap ratio (0...1).
    static func overlap(ocr: String, expectedTitle: String) -> Double {
        let nOCR = normalize(ocr)
        let nTitle = normalize(expectedTitle)
        guard !nOCR.isEmpty, !nTitle.isEmpty else { return 0 }
        if nOCR.contains(nTitle) || nTitle.contains(nOCR) { return 1 }
        let tokens = Set(nTitle.split(separator: " "))
        guard !tokens.isEmpty else { return 0 }
        let present = tokens.filter { nOCR.contains(String($0)) }.count
        return Double(present) / Double(tokens.count)
    }

    /// Transcript channel match: the host's spoken words are broken up by
    /// fillers/interjections, so the full title is almost never contiguous.
    /// Match when any contiguous fragment of the title (>= minFragment chars)
    /// appears in the window's aggregated transcript text.
    static func transcriptMatches(spoken: String, expectedTitle: String, minFragment: Int = 3) -> Bool {
        let nSpoken = normalize(spoken)
        let nTitle = normalize(expectedTitle)
        guard !nSpoken.isEmpty, !nTitle.isEmpty else { return false }
        if nSpoken.contains(nTitle) || nTitle.contains(nSpoken) { return true }

        // Longest-match first: prefer meaningful title fragments over short
        // generic ones (e.g. "莎士比亚") to reduce false positives.
        for len in stride(from: nTitle.count, through: minFragment, by: -1) {
            var start = 0
            while start + len <= nTitle.count {
                let lo = nTitle.index(nTitle.startIndex, offsetBy: start)
                let hi = nTitle.index(lo, offsetBy: len)
                if nSpoken.contains(String(nTitle[lo..<hi])) {
                    return true
                }
                start += 1
            }
        }
        return false
    }
}
