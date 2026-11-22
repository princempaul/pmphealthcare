import Foundation

/// The PHI wall, same rules as brain.py: nothing that looks like patient detail is kept or sent.
enum Privacy {
    private static let patterns: [NSRegularExpression] = [
        #"\b\d{4}[- ]?\d{3}[- ]?\d{3}(?:[- ]?[A-Z]{2})?\b"#,                     // Ontario health card
        #"\b(19|20)\d{2}[-/](0[1-9]|1[0-2])[-/](0[1-9]|[12]\d|3[01])\b"#,          // dates (DOB)
        #"\b(DOB|MRN|HCN|OHIP)\b"#,
        #"\b(room|rm|bed)\s*#?\s*\d+[A-Z]?\b"#,
        #"\b(Mr|Mrs|Ms|Miss)\.?\s+[A-Z][a-z]+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let clinical = try! NSRegularExpression(
        pattern: #"\b(resident|patient|chart|progress note|labs?|diagnos\w*|mg|dose|vitals|wound|delirium|dementia)\b"#,
        options: [.caseInsensitive])

    static func looksLikePatientDetail(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if patterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        return clinical.numberOfMatches(in: text, range: range) >= 3
    }
}
