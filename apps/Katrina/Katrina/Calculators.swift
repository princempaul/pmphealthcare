import Foundation

/// Arithmetic only: no network, no tokens, nothing stored. Each result names its formula so it can be checked.
enum Calc {
    static func bmi(kg: Double, cm: Double) -> Double? {
        guard kg > 0, cm > 0 else { return nil }
        let m = cm / 100
        return kg / (m * m)
    }

    /// CKD-EPI 2021 creatinine equation (no race term). Creatinine in µmol/L.
    static func egfr(creatinineUmol: Double, age: Double, female: Bool) -> Double? {
        guard creatinineUmol > 0, age >= 18 else { return nil }
        let scr = creatinineUmol / 88.4
        let k = female ? 0.7 : 0.9
        let a = female ? -0.241 : -0.302
        return 142 * pow(min(scr / k, 1), a) * pow(max(scr / k, 1), -1.200) * pow(0.9938, age) * (female ? 1.012 : 1)
    }

    /// FIB-4 = age × AST / (platelets × √ALT). Platelets in 10⁹/L.
    static func fib4(age: Double, ast: Double, alt: Double, platelets: Double) -> Double? {
        guard age > 0, ast > 0, alt > 0, platelets > 0 else { return nil }
        return age * ast / (platelets * alt.squareRoot())
    }

    static func fib4Band(_ v: Double, age: Double) -> String {
        let high = 2.67, low = age >= 65 ? 2.0 : 1.3
        if v < low { return "Low risk of advanced fibrosis" }
        if v > high { return "High risk of advanced fibrosis" }
        return "Indeterminate: needs a second test"
    }

    static func egfrBand(_ v: Double) -> String {
        switch v {
        case 90...: return "G1 (90 or more)"
        case 60..<90: return "G2 (60 to 89)"
        case 45..<60: return "G3a (45 to 59)"
        case 30..<45: return "G3b (30 to 44)"
        case 15..<30: return "G4 (15 to 29)"
        default: return "G5 (under 15)"
        }
    }

    static func bmiBand(_ v: Double) -> String {
        switch v {
        case ..<18.5: return "Underweight"
        case 18.5..<25: return "Normal weight"
        case 25..<30: return "Overweight"
        case 30..<35: return "Obesity class I"
        case 35..<40: return "Obesity class II"
        default: return "Obesity class III"
        }
    }

    static func chadsVasc(age: Double, female: Bool, chf: Bool, htn: Bool, diabetes: Bool, stroke: Bool, vascular: Bool) -> Int {
        (chf ? 1 : 0) + (htn ? 1 : 0) + (diabetes ? 1 : 0) + (stroke ? 2 : 0) + (vascular ? 1 : 0)
            + (age >= 75 ? 2 : age >= 65 ? 1 : 0) + (female ? 1 : 0)
    }
}

/// A questionnaire scored by adding items. Bands are (highest score in band, label).
struct Scale: Identifiable, Hashable {
    struct Item: Hashable { let label: String; let max: Int }
    let id: String
    let name: String
    let items: [Item]
    let bands: [Band]
    let note: String
    struct Band: Hashable { let upTo: Int; let label: String }

    var maxScore: Int { items.reduce(0) { $0 + $1.max } }
    func band(for score: Int) -> String { bands.first { score <= $0.upTo }?.label ?? bands.last?.label ?? "" }

    private static func each(_ labels: [String], max: Int) -> [Item] { labels.map { Item(label: $0, max: max) } }

    static let all: [Scale] = [
        Scale(id: "phq9", name: "PHQ-9 (depression)",
              items: each(["Little interest or pleasure", "Feeling down or hopeless", "Sleep trouble", "Tired, little energy",
                           "Appetite change", "Feeling bad about self", "Trouble concentrating", "Moving slowly or restless",
                           "Thoughts of self-harm"], max: 3),
              bands: [.init(upTo: 4, label: "Minimal"), .init(upTo: 9, label: "Mild"), .init(upTo: 14, label: "Moderate"),
                      .init(upTo: 19, label: "Moderately severe"), .init(upTo: 27, label: "Severe")],
              note: "Each item 0 to 3 over the last 2 weeks. Any score above 0 on the last item needs a safety assessment."),
        Scale(id: "gad7", name: "GAD-7 (anxiety)",
              items: each(["Nervous or on edge", "Can't stop worrying", "Worrying too much", "Trouble relaxing",
                           "Restless", "Easily annoyed", "Afraid something awful might happen"], max: 3),
              bands: [.init(upTo: 4, label: "Minimal"), .init(upTo: 9, label: "Mild"), .init(upTo: 14, label: "Moderate"),
                      .init(upTo: 21, label: "Severe")],
              note: "Each item 0 to 3 over the last 2 weeks."),
        Scale(id: "ciwa", name: "CIWA-Ar (alcohol withdrawal)",
              items: each(["Nausea and vomiting", "Tremor", "Sweats", "Anxiety", "Agitation", "Tactile disturbances",
                           "Auditory disturbances", "Visual disturbances", "Headache"], max: 7)
                  + [Item(label: "Orientation", max: 4)],
              bands: [.init(upTo: 9, label: "Mild"), .init(upTo: 18, label: "Moderate"), .init(upTo: 67, label: "Severe")],
              note: "Cut-offs differ between protocols. Use your site's order set for dosing."),
        Scale(id: "cows", name: "COWS (opioid withdrawal)",
              items: [Item(label: "Resting pulse", max: 4), Item(label: "Sweating", max: 4), Item(label: "Restlessness", max: 5),
                      Item(label: "Pupil size", max: 5), Item(label: "Bone or joint aches", max: 4), Item(label: "Runny nose or tearing", max: 4),
                      Item(label: "GI upset", max: 5), Item(label: "Tremor", max: 4), Item(label: "Yawning", max: 4),
                      Item(label: "Anxiety or irritability", max: 4), Item(label: "Gooseflesh", max: 5)],
              bands: [.init(upTo: 4, label: "None"), .init(upTo: 12, label: "Mild"), .init(upTo: 24, label: "Moderate"),
                      .init(upTo: 36, label: "Moderately severe"), .init(upTo: 48, label: "Severe")],
              note: "Score each item from the COWS form; some items skip values (pulse is 0, 1, 2 or 4)."),
    ]
}

/// Token use this month, counted on the device from what the API reports. Dollars are in the Anthropic Console.
enum Usage {
    private static var month: String { String(ISO8601DateFormatter().string(from: Date()).prefix(7)) }

    static func record(_ usage: [String: Any]?) {
        guard let usage else { return }
        let d = UserDefaults.standard
        if d.string(forKey: "usage.month") != month {
            d.set(month, forKey: "usage.month")
            for k in ["in", "out", "cached", "searches", "requests"] { d.set(0, forKey: "usage.\(k)") }
        }
        func add(_ key: String, _ n: Int) { d.set(d.integer(forKey: "usage.\(key)") + n, forKey: "usage.\(key)") }
        add("in", (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0))
        add("cached", usage["cache_read_input_tokens"] as? Int ?? 0)
        add("out", usage["output_tokens"] as? Int ?? 0)
        add("searches", (usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0)
        add("requests", 1)
    }

    static var summary: String {
        let d = UserDefaults.standard
        guard d.string(forKey: "usage.month") == month, d.integer(forKey: "usage.requests") > 0 else { return "Nothing used yet this month." }
        func k(_ key: String) -> String {
            let n = d.integer(forKey: "usage.\(key)")
            return n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
        }
        return "\(k("requests")) requests · \(k("in")) tokens in · \(k("cached")) reused from cache · \(k("out")) out · \(k("searches")) searches"
    }
}
