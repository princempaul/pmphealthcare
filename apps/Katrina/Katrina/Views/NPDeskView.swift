import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
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
                Section("Calculators") {
                    NavigationLink { NPCalculatorsView() } label: {
                        row(icon: "function", title: "Calculators and scales", detail: "eGFR, FIB-4, BMI, CHA₂DS₂-VASc, PHQ-9, GAD-7, CIWA-Ar, COWS")
                    }
                }

                Section {
                    Label("No names, birth dates, health card numbers, addresses, phone or email. Write [patient] instead.", systemImage: "person.crop.circle.badge.xmark")
                    Label("Every draft is for your review. Nothing is signed, sent or filed from here.", systemImage: "signature")
                    Label("Chats live in memory only and vanish when the desk locks.", systemImage: "lock.shield")
                    Label("With look-up on, answers cite your trusted sources. Still confirm doses and thresholds yourself.", systemImage: "books.vertical")
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
    @State private var editingStyle = false
    @State private var confirmAttach = false
    @State private var pickingPDF = false
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var attachProblem: String?

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
                            if model.streaming.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(model.lookUp ? "Checking sources and drafting…" : "Drafting…").foregroundStyle(.secondary)
                                }.id("busy")
                            } else {
                                Text(model.streaming).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .id("busy")
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.lines.count) { _, _ in withAnimation { proxy.scrollTo(model.lines.last?.id, anchor: .bottom) } }
                .onChange(of: model.streaming.count / 120) { _, _ in proxy.scrollTo("busy", anchor: .bottom) }
            }
            composer
        }
        .navigationTitle(model.template.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: $model.lookUp) { Label("Look up trusted sources", systemImage: "globe") }
                    Button { editingStyle = true } label: { Label("My style for this", systemImage: "text.badge.star") }
                    Button { confirmAttach = true } label: { Label("Attach a guideline or printed page", systemImage: "paperclip") }
                    Button(role: .destructive) { model.reset(); draft = model.template.starter } label: { Label("Clear", systemImage: "trash") }
                        .disabled(model.lines.isEmpty || model.busy)
                } label: { Label("Options", systemImage: model.lookUp ? "globe" : "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editingStyle) { NPStyleEditor(template: model.template) }
        .confirmationDialog("Reference material only", isPresented: $confirmAttach, titleVisibility: .visible) {
            Button("PDF: it has no patient information") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pickingPDF = true } }
            Button("Photo: it has no patient information") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pickingPhoto = true } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Attach a guideline, a blank form or a printed page. The app can't check inside a file, so never attach anything about a patient: no charts, results, referrals or completed forms.")
        }
        .fileImporter(isPresented: $pickingPDF, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { attachProblem = "Couldn't read that file."; return }
            guard data.count <= 15_000_000 else { attachProblem = "That PDF is over 15 MB. Attach the section you need."; return }
            model.attachment = ClinicAssistant.Attachment(name: url.lastPathComponent, isPDF: true, base64: data.base64EncodedString())
            attachProblem = nil
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let jpeg = Clipboard.jpeg(from: data, maxSide: 1568) {
                    model.attachment = ClinicAssistant.Attachment(name: "Photo", isPDF: false, base64: jpeg.base64EncodedString())
                    attachProblem = nil
                } else {
                    attachProblem = "Couldn't read that photo."
                }
                photo = nil
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
                if !line.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SOURCES").font(Theme.monoSmall).foregroundStyle(.secondary)
                        ForEach(line.sources) { src in
                            if let url = src.url.flatMap(URL.init(string:)) {
                                Link(destination: url) {
                                    Label(src.title, systemImage: "link").font(.footnote).multilineTextAlignment(.leading)
                                }
                            } else {
                                Label(src.title, systemImage: "doc.text").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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
        VStack(alignment: .leading, spacing: 8) {
            if let a = model.attachment {
                HStack(spacing: 8) {
                    Image(systemName: a.isPDF ? "doc.richtext" : "photo").foregroundStyle(Theme.accent)
                    Text("\(a.name) goes with your next message").font(.footnote).lineLimit(1)
                    Spacer()
                    Button { model.attachment = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            if let attachProblem { Text(attachProblem).font(.footnote).foregroundStyle(Theme.action) }
            composerRow
        }
        .padding(12)
        .background(.bar)
    }

    private var composerRow: some View {
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
    }

    private func send() {
        let q = draft
        draft = ""
        Task {
            let sent = await model.send(q, chat: chat)
            if !sent && draft.isEmpty { draft = q }
        }
    }
}

/// Paul's own format for one kind of document. Saved on this device and added to every draft of that kind.
struct NPStyleEditor: View {
    let template: NPTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 260).font(.callout)
                } header: { Text(template.title) } footer: {
                    Text("Paste your headings, phrases and order, or an example with every patient detail taken out. Katrina follows it each time. Up to 4,000 characters.")
                }
                if let problem { Section { Text(problem).foregroundStyle(Theme.action) } }
            }
            .formStyle(.grouped)
            .navigationTitle("My style")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if Privacy.looksLikeIdentifier(text) {
                            problem = "That looks like it has identifying detail (a name, date of birth, health card number, phone, email, postal code or room). Take it out, then save."
                        } else {
                            ClinicAssistant.setStyle(text, for: template)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { text = ClinicAssistant.style(for: template) }
        }
    }
}

/// Copies text for pasting into Jane. On iPhone it stays off other devices and expires after two minutes.
enum Clipboard {
    /// Shrinks any image the system can read (HEIC included) to a JPEG the API accepts.
    static func jpeg(from data: Data, maxSide: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

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
