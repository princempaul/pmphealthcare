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

    /// Details that don't name anyone but can still point to one person in a small community.
    private static let quasi: [(NSRegularExpression, String)] = [
        (#"\b(?-i:[A-Z][a-z]+(?:\s[A-Z][a-z]+)?\s(?:Lodge|Manor|Villa|Residence|Terrace|Gardens|Nursing Home|Retirement (?:Home|Residence|Village)|Long[- ]Term Care))\b"#, "a care home or facility name"),
        (#"\b(?:works?|worked|employed)\s(?:at|for|with)\s(?-i:[A-Z])"#, "an employer"),
        (#"\bage[d]?\s*:?\s*(?:9\d|1[01]\d)\b|\b(?:9\d|1[01]\d)[- ]?(?:y/?o|yrs?|years?)\b"#, "an exact age over 89"),
        (#"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s\d{1,2}(?:st|nd|rd|th)?\b(?!\s?(?:mg|mcg|g|ml|l|units?|%|tabs?|times|days?|weeks?|months?|years?|hours?|h)\b)|\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b(?:19|20)\d{2}-\d{2}-\d{2}\b"#, "a specific date"),
    ].compactMap { p, why in (try? NSRegularExpression(pattern: p, options: [.caseInsensitive])).map { ($0, why) } }

    /// The first such detail found, in plain words, or nil.
    static func quasiIdentifier(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        return quasi.first { $0.0.firstMatch(in: text, range: range) != nil }?.1
    }
}
