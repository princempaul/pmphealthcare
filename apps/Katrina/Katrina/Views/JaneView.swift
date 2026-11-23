import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Jane desk: commands for Jane App go to a dedicated Claude session on the iMac (Remote Control,
/// Claude in Chrome), never through Katrina's files. This panel only copies a template and opens it.
struct JaneView: View {
    @EnvironmentObject var brain: BrainStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    private struct Command: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let text: String
    }

    private let commands: [Command] = [
        Command(icon: "calendar", title: "Today's schedule", detail: "Who's booked and what for",
                text: "Jane: show today's schedule, one line per appointment."),
        Command(icon: "square.and.pencil", title: "Add a draft note", detail: "Saved unsigned; you sign in Jane",
                text: "Jane: add a draft chart note for [patient]. Note: "),
        Command(icon: "paperplane", title: "Send an intake form", detail: "Asks you to confirm before sending",
                text: "Jane: send the [form name] form to [patient]."),
        Command(icon: "calendar.badge.plus", title: "Book an appointment", detail: "Confirms before booking",
                text: "Jane: book [patient] for [service] on [day] at [time]."),
        Command(icon: "arrow.left.arrow.right", title: "Move or cancel", detail: "Confirms before changing",
                text: "Jane: move [patient]'s [day] appointment to [new day and time]."),
        Command(icon: "doc.badge.clock", title: "Forms not back", detail: "Who still owes intake forms",
                text: "Jane: which patients booked this week haven't completed their intake forms?"),
    ]

    private var desk: (machine: String, running: Bool?)? {
        brain.commandMac.map { ($0.machine, $0.host?.janeDesk) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        StatusLight(color: desk?.running == true ? Theme.ok : desk?.running == false ? Theme.action : .secondary,
                                    pulsing: desk?.running == true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Jane desk (iMac)").font(.headline)
                            Text(statusLine).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { openDesk() } label: { Label("Open Jane desk in Claude", systemImage: "arrow.up.forward.app") }
                } footer: {
                    Text("In the Claude app: Code > \"Jane desk (iMac)\". It works in the Chrome window where Jane is signed in.")
                }

                Section("Commands") {
                    ForEach(commands) { c in
                        Button { copy(c) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: c.icon).foregroundStyle(Theme.accent).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).foregroundStyle(.primary)
                                    Text(c.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if copied == c.title { Text("Copied").font(.caption.weight(.semibold)).foregroundStyle(Theme.ok) }
                            }
                        }
                    }
                } 

                Section {
                    Label("Notes stay unsigned drafts until you sign them in Jane.", systemImage: "signature")
                    Label("Forms and booking changes wait for your yes.", systemImage: "hand.raised")
                    Label("No billing, payments or settings, ever.", systemImage: "dollarsign.circle")
                    Label("Patient details go only to the Jane desk, never into Katrina, iCloud or GitHub.", systemImage: "lock.shield")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Jane")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var statusLine: String {
        guard let d = desk else { return "No Mac has checked in yet" }
        switch d.running {
        case .some(true): return "Running on \(d.machine)"
        case .some(false): return "Not running on \(d.machine). On the iMac: ./jane-desk.sh"
        case .none: return "Waiting for \(d.machine) to report (it updates itself within 6 hours)"
        }
    }

    /// Tap a command: copy its template, then open the desk so Paul pastes it and fills in the patient there.
    private func copy(_ c: Command) {
        #if os(iOS)
        UIPasteboard.general.string = c.text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.text, forType: .string)
        #endif
        copied = c.title
        openDesk()
    }

    private func openDesk() {
        if let url = URL(string: "https://claude.ai/code") { openURL(url) }
    }
}
