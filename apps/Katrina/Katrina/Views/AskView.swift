import SwiftUI

struct AskView: View {
    @EnvironmentObject var brain: BrainStore
    @EnvironmentObject var chat: ChatStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let suggestions = ["What's open?", "What needs me today?", "What breaks if I change the booking form?", "Which projects have loose work?"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if chat.lines.isEmpty { empty }
                            ForEach(chat.lines) { line in bubble(line).id(line.id) }
                            if chat.busy {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(chat.status).foregroundStyle(.secondary) }.id("busy")
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: chat.lines.count) { _, _ in withAnimation { proxy.scrollTo(chat.lines.last?.id, anchor: .bottom) } }
                }
                composer
            }
            .navigationTitle("Ask Katrina")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem { Button("New") { chat.reset() }.disabled(chat.lines.isEmpty || chat.busy) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask about any project").font(Theme.display(26))
            Text("Katrina answers from what your Macs reported, so most questions need no lookups.").foregroundStyle(.secondary)
            FlowRow(items: suggestions) { s in
                Button(s) { send(s) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private func bubble(_ line: ChatLine) -> some View {
        switch line.role {
        case .paul:
            HStack { Spacer(minLength: 60)
                Text(line.text).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .katrina:
            Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .note:
            Label(line.text, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.watch)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Katrina", text: $draft, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit { send(draft) }
            Button { send(draft) } label: {
                Image(systemName: "arrow.up").font(.headline).frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || chat.busy)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
        .background(.bar)
    }

    private func send(_ text: String) {
        let q = text
        draft = ""
        Task { await chat.ask(q, brain: brain) }
    }
}

/// Wrapping row of chips.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(items, id: \.self, content: content) }
            VStack(alignment: .leading, spacing: 8) { ForEach(items, id: \.self, content: content) }
        }
    }
}
