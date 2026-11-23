import SwiftUI

/// Control-tower look: deep ink at night, warm paper by day, one teal accent, status lights that mean something.
enum Theme {
    static let accent = Color("AccentColor")
    static let action = Color(red: 0.93, green: 0.33, blue: 0.27)
    static let watch = Color(red: 0.96, green: 0.65, blue: 0.18)
    static let ok = Color(red: 0.24, green: 0.74, blue: 0.47)
    static let live = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let card = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.09)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let label = Font.system(size: 11, weight: .semibold).width(.expanded)
    static let mono = Font.system(.caption, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)

    static func color(for level: String) -> Color {
        switch level.uppercased() {
        case "ACTION": return action
        case "WATCH": return watch
        default: return .secondary
        }
    }

    static func color(for level: TowerItem.Level) -> Color {
        switch level {
        case .action: return action
        case .watch: return watch
        case .info: return accent
        }
    }

    static func color(forMission state: String) -> Color {
        switch state {
        case "running", "queued": return live
        case "needs_approval": return action
        case "done", "pushed", "closed": return ok
        case "failed": return watch
        default: return .secondary
        }
    }

    static func label(forMission state: String) -> String {
        switch state {
        case "queued": return "Queued"
        case "running": return "Working"
        case "done": return "Report ready"
        case "needs_approval": return "Needs your approval"
        case "pushed": return "Pushed"
        case "failed": return "Failed"
        case "stopped": return "Stopped"
        case "discarded": return "Discarded"
        case "closed": return "Closed"
        default: return state.capitalized
        }
    }
}

struct Card: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint?.opacity(0.45) ?? Theme.hairline))
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(Card(tint: tint)) }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased()).font(Theme.label).tracking(1.2).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(Theme.monoSmall).foregroundStyle(.secondary) }
        }
    }
}

struct LevelDot: View {
    let level: String
    var body: some View {
        Circle().fill(Theme.color(for: level)).frame(width: 8, height: 8)
    }
}

/// A status light that breathes while something is live.
struct StatusLight: View {
    let color: Color
    var pulsing = false
    var size: CGFloat = 9
    @State private var on = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.35)).frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(on ? 1 : 0.4).opacity(on ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: on)
            }
            Circle().fill(color).frame(width: size, height: size)
                .shadow(color: color.opacity(0.7), radius: pulsing ? 4 : 0)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { on = pulsing }
    }
}

/// Small capsule tag.
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Relative time in a few characters: "now", "4m", "3h", "2d".
func ago(_ date: Date?) -> String {
    guard let date else { return "–" }
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
