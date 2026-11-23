import SwiftUI

struct NotesView: View {
    @EnvironmentObject var brain: BrainStore
    @State private var topic = ""
    @State private var text = ""
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        List {
                Section {
                    TextField("Project or topic", text: $topic)
                    TextField("Decision or reminder", text: $text, axis: .vertical).lineLimit(2...6)
                    Button("Keep note") { save() }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let message { Text(message).font(.footnote).foregroundStyle(failed ? Theme.action : Theme.ok) }
                } header: { Text("New note") } footer: {
                    Text("Notes reach both Macs at their next hourly update. Project decisions only, never patient details.")
                }
                Section("All notes") {
                    if brain.notes.isEmpty { Text("No notes yet.").foregroundStyle(.secondary) }
                    ForEach(brain.notes) { n in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.text)
                            Text("\(n.topic) · \(String(n.created.prefix(10))) · \(n.machine)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .refreshable { await brain.reload() }
            .navigationTitle("Notes")
    }

    private func save() {
        do {
            try brain.addNote(topic: topic, text: text)
            message = "Kept. It reaches your Macs within the hour."; failed = false
            topic = ""; text = ""
        } catch {
            message = error.localizedDescription; failed = true
        }
    }
}
