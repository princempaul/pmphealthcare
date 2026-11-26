import SwiftUI

/// Talk mode: a spoken back-and-forth with Katrina. Listen, think, speak, listen again.
struct TalkView: View {
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var input = VoiceInput()
    @ObservedObject private var output = VoiceOutput.shared
    @State private var phase: Phase = .starting
    @State private var heard = ""
    @State private var answer = ""
    @State private var problem: String?
    @State private var breathe = false

    enum Phase { case starting, listening, thinking, speaking, paused }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.07, blue: 0.10), Color(red: 0.02, green: 0.16, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 28) {
                HStack {
                    Text("KATRINA").font(Theme.label).tracking(3).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button { end() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white.opacity(0.8))
                            .frame(width: 40, height: 40).background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                orb
                Text(statusText).font(.headline).foregroundStyle(.white.opacity(0.75))
                VStack(spacing: 14) {
                    if !heard.isEmpty || !input.transcript.isEmpty {
                        Text(phase == .listening ? input.transcript : heard)
                            .font(.title3).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                    }
                    if !answer.isEmpty && phase != .listening {
                        ScrollView {
                            Text(answer).font(.title3.weight(.medium)).foregroundStyle(.white).multilineTextAlignment(.center)
                        }
                        .frame(maxHeight: 220)
                    }
                    if let problem { Text(problem).font(.callout).foregroundStyle(Theme.watch).multilineTextAlignment(.center) }
                }
                .padding(.horizontal, 8)
                Spacer()
                controls
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .task { await listen() }
        .onChange(of: input.state) { _, st in
            if case .denied(let why) = st { problem = why; phase = .paused }
            else if st == .idle && phase == .listening { phase = .paused }   // stopped with nothing heard
        }
        .onDisappear { input.stop(); output.stop() }
    }

    // MARK: pieces

    private var orb: some View {
        let scale = 1 + CGFloat(input.level) * 0.6
        return ZStack {
            Circle().fill(orbColor.opacity(0.18)).frame(width: 240, height: 240)
                .scaleEffect(breathe ? 1.08 : 0.94)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)
            Circle().fill(RadialGradient(colors: [orbColor, orbColor.opacity(0.35)], center: .center, startRadius: 4, endRadius: 90))
                .frame(width: 150, height: 150)
                .scaleEffect(phase == .listening ? scale : (phase == .speaking ? 1.06 : 1))
                .shadow(color: orbColor.opacity(0.7), radius: 30)
                .animation(.easeOut(duration: 0.12), value: input.level)
            if phase == .thinking { ProgressView().controlSize(.large).tint(.white) }
        }
        .onAppear { breathe = true }
        .onTapGesture { tapOrb() }
    }

    private var orbColor: Color {
        switch phase {
        case .listening: return Theme.live
        case .thinking: return Color(red: 0.55, green: 0.45, blue: 1.0)
        case .speaking: return Theme.accent
        default: return .gray
        }
    }

    private var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Tap to interrupt"
        case .paused: return "Tap to talk"
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                if phase == .paused { Task { await listen() } } else { pause() }
            } label: {
                Image(systemName: phase == .paused ? "mic.fill" : "pause.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(.white.opacity(0.12), in: Circle())
            }
            Button { end() } label: {
                Image(systemName: "phone.down.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Theme.action, in: Circle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: the loop

    private func listen() async {
        output.stop()
        problem = nil
        input.reset()
        input.onFinished = { text in _ = Task { await respond(to: text) } }
        phase = .listening
        await input.start()
        if case .denied(let why) = input.state { problem = why; phase = .paused }
    }

    private func respond(to text: String) async {
        heard = text
        answer = ""
        phase = .thinking
        let reply = await chat.reply(to: text, voice: true)
        answer = reply
        guard phase == .thinking else { return }     // paused or closed while waiting: stay quiet
        phase = .speaking
        output.speak(reply) {
            if phase == .speaking { Task { await listen() } }   // hands-free: listen again
        }
    }

    private func tapOrb() {
        switch phase {
        case .speaking: output.stop(); Task { await listen() }
        case .listening: input.finish()
        case .paused: Task { await listen() }
        default: break
        }
    }

    private func pause() {
        input.stop()
        output.stop()
        phase = .paused
    }

    private func end() {
        phase = .paused
        input.stop()
        output.stop()
        dismiss()
    }
}
