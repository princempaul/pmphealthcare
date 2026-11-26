import SwiftUI

/// Calculators for the NP desk. Numbers only: nothing is sent anywhere or saved.
struct NPCalculatorsView: View {
    var body: some View {
        List {
            Section("Formulas") {
                NavigationLink("eGFR (CKD-EPI 2021)") { EGFRView() }
                NavigationLink("FIB-4 (liver fibrosis)") { FIB4View() }
                NavigationLink("BMI") { BMIView() }
                NavigationLink("CHA₂DS₂-VASc") { ChadsView() }
            }
            Section("Scales") {
                ForEach(Scale.all) { s in NavigationLink(s.name) { ScaleView(scale: s) } }
            }
            Section {
                Text("These do arithmetic on the numbers you enter. Nothing leaves the phone and nothing is saved. Check the result against the source before it goes in a chart.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Calculators")
    }
}

private struct NumberRow: View {
    let label: String
    let unit: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $text).multilineTextAlignment(.trailing).frame(maxWidth: 110)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text(unit).foregroundStyle(.secondary).font(.footnote)
        }
    }
}

private struct ResultRow: View {
    let value: String
    let meaning: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Theme.display(30))
            Text(meaning).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

private struct EGFRView: View {
    @State private var cr = "", age = ""
    @State private var female = false
    var body: some View {
        Form {
            NumberRow(label: "Creatinine", unit: "µmol/L", text: $cr)
            NumberRow(label: "Age", unit: "years", text: $age)
            Toggle("Female", isOn: $female)
            if let v = Calc.egfr(creatinineUmol: num(cr), age: num(age), female: female) {
                ResultRow(value: "\(Int(v.rounded())) mL/min/1.73 m²", meaning: Calc.egfrBand(v))
            }
            Text("CKD-EPI 2021 creatinine equation, adults only.").font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).navigationTitle("eGFR")
    }
}

private struct FIB4View: View {
    @State private var age = "", ast = "", alt = "", plt = ""
    var body: some View {
        Form {
            NumberRow(label: "Age", unit: "years", text: $age)
            NumberRow(label: "AST", unit: "U/L", text: $ast)
            NumberRow(label: "ALT", unit: "U/L", text: $alt)
            NumberRow(label: "Platelets", unit: "×10⁹/L", text: $plt)
            if let v = Calc.fib4(age: num(age), ast: num(ast), alt: num(alt), platelets: num(plt)) {
                ResultRow(value: String(format: "%.2f", v), meaning: Calc.fib4Band(v, age: num(age)))
            }
            Text("Age × AST ÷ (platelets × √ALT). Cut-offs 1.3 and 2.67; lower cut-off 2.0 from age 65. Less reliable under 35.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).navigationTitle("FIB-4")
    }
}

private struct BMIView: View {
    @State private var kg = "", cm = ""
    var body: some View {
        Form {
            NumberRow(label: "Weight", unit: "kg", text: $kg)
            NumberRow(label: "Height", unit: "cm", text: $cm)
            if let v = Calc.bmi(kg: num(kg), cm: num(cm)) {
                ResultRow(value: String(format: "%.1f kg/m²", v), meaning: Calc.bmiBand(v))
            }
        }
        .formStyle(.grouped).navigationTitle("BMI")
    }
}

private struct ChadsView: View {
    @State private var age = ""
    @State private var female = false, chf = false, htn = false, dm = false, stroke = false, vasc = false
    var body: some View {
        Form {
            NumberRow(label: "Age", unit: "years", text: $age)
            Toggle("Female", isOn: $female)
            Toggle("Heart failure", isOn: $chf)
            Toggle("Hypertension", isOn: $htn)
            Toggle("Diabetes", isOn: $dm)
            Toggle("Stroke, TIA or thromboembolism", isOn: $stroke)
            Toggle("Vascular disease", isOn: $vasc)
            ResultRow(value: "\(Calc.chadsVasc(age: num(age), female: female, chf: chf, htn: htn, diabetes: dm, stroke: stroke, vascular: vasc))",
                      meaning: "Out of 9. Use your guideline's threshold for anticoagulation.")
        }
        .formStyle(.grouped).navigationTitle("CHA₂DS₂-VASc")
    }
}

private struct ScaleView: View {
    let scale: Scale
    @State private var scores: [Int]

    init(scale: Scale) {
        self.scale = scale
        _scores = State(initialValue: Array(repeating: 0, count: scale.items.count))
    }

    private var total: Int { scores.reduce(0, +) }

    var body: some View {
        Form {
            Section {
                ResultRow(value: "\(total) / \(scale.maxScore)", meaning: scale.band(for: total))
            }
            Section {
                ForEach(Array(scale.items.enumerated()), id: \.offset) { i, item in
                    Stepper(value: $scores[i], in: 0...item.max) {
                        HStack { Text(item.label); Spacer(); Text("\(scores[i])").font(.body.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
            } footer: { Text(scale.note) }
            Section { Button("Reset") { scores = Array(repeating: 0, count: scale.items.count) } }
        }
        .formStyle(.grouped).navigationTitle(scale.name)
    }
}
