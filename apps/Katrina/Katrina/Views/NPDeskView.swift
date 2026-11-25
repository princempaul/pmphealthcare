import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The NP's own area. It opens only with the NP PIN (or Face ID) and locks itself when the app has been away.
struct NPDeskView: View {
    @EnvironmentObject var np: NPSession

    var body: some View {
        if np.unlocked { NPHomeView() } else { NPLockView() }
    }
}

struct NPLockView: View {
    @EnvironmentObject var np: NPSession
    @State private var pin = ""
    @State private var again = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "stethoscope.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
            Text(np.hasPin ? "NP desk" : "Set up your NP login").font(Theme.display(28))
            Text(np.hasPin
                 ? "Enter your PIN" + (np.faceID && np.biometricsAvailable ? " or use Face ID." : ".")
                 : "Choose a 6-digit PIN for the NP desk. It's separate from your phone's passcode and stays on this device.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)

            pinField("6-digit PIN", text: $pin)
                .onChange(of: pin) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(6))
                    if digits != v { pin = digits; return }
                    if np.hasPin && digits.count == 6 { if !np.unlock(pin: digits) { pin = "" } }
                }
            if !np.hasPin {
                pinField("Same PIN again", text: $again)
                    .onChange(of: again) { _, v in
                        let digits = String(v.filter(\.isNumber).prefix(6))
                        if digits != v { again = digits }
                    }
                Button("Create login") {
                    if np.createPin(pin, again: again) { pin = ""; again = "" }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(pin.count != 6 || again.count != 6)
            } else if np.faceID && np.biometricsAvailable {
                Button { Task { await np.unlockWithBiometrics() } } label: { Label("Use Face ID", systemImage: "faceid") }
                    .buttonStyle(.bordered)
            }
            if !np.message.isEmpty { Text(np.message).font(.footnote).foregroundStyle(Theme.action).multilineTextAlignment(.center) }
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await np.unlockWithBiometrics() }
    }

    private func pinField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .multilineTextAlignment(.center)
            .font(.title3.monospacedDigit())
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct NPHomeView: View {
    @EnvironmentObject var np: NPSession
    @State private var showJane = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showJane = true } label: {
                        row(icon: "stethoscope", title: "Jane desk", detail: "Schedule, draft notes, forms and bookings in Jane")
                    }
                } header: { Text("Jane") }

                Section("Notes") { ForEach(NPTemplate.notes) { link($0) } }
                Section("Letters and email") { ForEach(NPTemplate.letters) { link($0) } }
                Section("Ask and prepare") { ForEach(NPTemplate.other) { link($0) } }

                Section {
                    Label("No names, birth dates, health card numbers, addresses, phone or email. Write [patient] instead.", systemImage: "person.crop.circle.badge.xmark")
                    Label("Every draft is for your review. Nothing is signed, sent or filed from here.", systemImage: "signature")
                    Label("Chats live in memory only and vanish when the desk locks.", systemImage: "lock.shield")
                    Label("Claude can't browse here, so confirm doses and thresholds at the source.", systemImage: "books.vertical")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("NP desk")
            .navigationDestination(for: NPTemplate.self) { NPAssistantView(template: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { np.lock() } label: { Label("Lock", systemImage: "lock.fill") }
                }
            }
            .sheet(isPresented: $showJane) { JaneView() }
        }
    }

    private func link(_ t: NPTemplate) -> some View {
        NavigationLink(value: t) { row(icon: t.icon, title: t.title, detail: t.detail) }
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NPAssistantView: View {
    @EnvironmentObject var chat: ChatStore
    @StateObject private var model: ClinicAssistant
    @State private var draft: String
    @State private var copied: UUID?

    init(template: NPTemplate) {
        _model = StateObject(wrappedValue: ClinicAssistant(template: template))
        _draft = State(initialValue: template.starter)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text("Use [patient] instead of names. Replace the [brackets] below, or clear them.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(model.lines) { line in row(line).id(line.id) }
                        if model.busy {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Drafting…").foregroundStyle(.secondary) }.id("busy")
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.lines.count) { _, _ in withAnimation { proxy.scrollTo(model.lines.last?.id, anchor: .bottom) } }
            }
            composer
        }
        .navigationTitle(model.template.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { model.reset(); draft = model.template.starter }.disabled(model.lines.isEmpty || model.busy)
            }
        }
    }

    @ViewBuilder
    private func row(_ line: ClinicAssistant.Line) -> some View {
        switch line.kind {
        case .mine:
            HStack { Spacer(minLength: 60)
                Text(line.text).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .reply:
            VStack(alignment: .leading, spacing: 10) {
                Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Clipboard.copy(line.text)
                    copied = line.id
                } label: {
                    Label(copied == line.id ? "Copied (clears in 2 minutes)" : "Copy", systemImage: copied == line.id ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
            .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .note:
            Label(line.text, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.watch)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Type or dictate", text: $draft, axis: .vertical)
                .lineLimit(1...8).textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.headline).frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
        }
        .padding(12)
        .background(.bar)
    }

    private func send() {
        let q = draft
        draft = ""
        Task { await model.send(q, chat: chat) }
    }
}

/// Copies text for pasting into Jane. On iPhone it stays off other devices and expires after two minutes.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
