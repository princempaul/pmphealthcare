import AppIntents
import Foundation

/// "Hey Siri, ask Katrina PA" — Siri asks what you need, Katrina answers out loud.
struct AskKatrinaIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Katrina"
    static var description = IntentDescription("Ask Katrina about your projects, Macs, missions, GitHub, websites or clinic systems, and hear the answer.")
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you need?"))
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await Dispatcher.refresh(brain: BrainStore.shared, github: GitHubStore.shared)
        let answer = await ChatStore.shared.reply(to: question, voice: true)
        return .result(dialog: IntentDialog(stringLiteral: VoiceOutput.speakable(answer)))
    }
}

/// "Hey Siri, what needs me in Katrina PA" — the Tower, read out. No AI call, so it's instant and free.
struct WhatNeedsMeIntent: AppIntent {
    static var title: LocalizedStringResource = "What needs me"
    static var description = IntentDescription("Hear what needs you right now across your Macs, missions, GitHub and websites.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let brain = BrainStore.shared, github = GitHubStore.shared, sites = SiteMonitor.shared
        await Dispatcher.refresh(brain: brain, github: github)
        await sites.refresh()
        let items = TowerBoard.needsYou(brain: brain, github: github, sites: sites).filter { $0.level != .info }
        let live = TowerBoard.inFlight(brain: brain, github: github).count
        var text: String
        if items.isEmpty {
            text = "All clear. Nothing needs you right now."
        } else {
            let top = items.prefix(3).map { $0.title }.joined(separator: ". ")
            text = "\(items.count) thing\(items.count == 1 ? "" : "s") need\(items.count == 1 ? "s" : "") you. \(top)."
            if items.count > 3 { text += " And \(items.count - 3) more in the Tower." }
        }
        if live > 0 { text += " \(live) in flight." }
        return .result(dialog: IntentDialog(stringLiteral: VoiceOutput.speakable(text)))
    }
}

/// "Hey Siri, talk to Katrina PA" — opens straight into Talk mode.
struct TalkToKatrinaIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Katrina"
    static var description = IntentDescription("Open Katrina in hands-free Talk mode.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "talk.open")
        return .result()
    }
}

struct KatrinaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskKatrinaIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something", "Hey \(.applicationName)"],
                    shortTitle: "Ask Katrina", systemImageName: "sparkles")
        AppShortcut(intent: WhatNeedsMeIntent(),
                    phrases: ["What needs me in \(.applicationName)", "\(.applicationName) status", "Check \(.applicationName)"],
                    shortTitle: "What needs me", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: TalkToKatrinaIntent(),
                    phrases: ["Talk to \(.applicationName)", "Open \(.applicationName) talk mode"],
                    shortTitle: "Talk to Katrina", systemImageName: "waveform")
    }
}
