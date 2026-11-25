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

    /// The NP desk allows clinical wording (doses, labs, diagnoses) but not who the person is.
    private static let identifiers: [NSRegularExpression] = [
        #"\b\d{4}[- ]?\d{3}[- ]?\d{3}(?:[- ]?[A-Z]{2})?\b"#,                    // Ontario health card
        #"\b(DOB|MRN|HCN|OHIP)\b"#,
        #"\b(born|birth\w*)\b[^\n]{0,24}\b\d{1,4}[-/ .][A-Za-z0-9]{1,9}[-/ .]\d{1,4}\b"#,
        #"\b(room|rm|bed)\s*#?\s*\d+[A-Z]?\b"#,
        #"\b(?-i:(?:Mr|Mrs|Ms|Miss|Mx)\.?\s+[A-Z][a-z]+)"#,
        #"\(?\b\d{3}\)?[-. ]\d{3}[-. ]\d{4}\b"#,                                // phone
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,                          // email
        #"\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z][ -]?\d[ABCEGHJ-NPRSTV-Z]\d\b"#,  // postal code
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func looksLikeIdentifier(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return identifiers.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}

