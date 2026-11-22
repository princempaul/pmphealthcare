import SwiftUI

/// One quiet, clinical palette: deep teal on warm paper, bright teal at night.
enum Theme {
    static let accent = Color("AccentColor")
    static let action = Color(red: 0.80, green: 0.27, blue: 0.20)
    static let watch = Color(red: 0.85, green: 0.58, blue: 0.13)
    static let ok = Color(red: 0.20, green: 0.58, blue: 0.40)
    static let card = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.08)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let label = Font.system(size: 11, weight: .semibold).width(.expanded)
    static let mono = Font.system(.caption, design: .monospaced)

    static func color(for level: String) -> Color {
        switch level.uppercased() {
        case "ACTION": return action
        case "WATCH": return watch
        default: return .secondary
        }
    }
}

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(1.2).foregroundStyle(.secondary)
    }
}

struct LevelDot: View {
    let level: String
    var body: some View {
        Circle().fill(Theme.color(for: level)).frame(width: 8, height: 8)
    }
}
