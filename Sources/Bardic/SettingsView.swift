import SwiftUI
import BardicCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            CleanupTab().tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            DictionaryTab().tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab().tabItem { Label("History", systemImage: "clock") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @AppStorage("triggerKey") private var triggerKeyRaw = TriggerKey.rightOption.rawValue
    @AppStorage("addTrailingSpace") private var addTrailingSpace = true
    @AppStorage("voiceCommands") private var voiceCommands = true
    @AppStorage("language") private var language = "en"
    @AppStorage("checkForUpdates") private var checkForUpdates = true

    var body: some View {
        Form {
            Picker("Push-to-talk key", selection: $triggerKeyRaw) {
                ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text("Hold to dictate, release to insert. Double-tap for hands-free; tap again to finish. Esc cancels. \(TriggerKey.fnHint) You can also change the key from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Add a space after inserted text", isOn: $addTrailingSpace)
            Picker("Language", selection: $language) {
                Text("English").tag("en")
                Text("Auto-detect").tag("")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
            }
            Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
            Toggle("Check for updates (asks GitHub at launch and once a day)", isOn: $checkForUpdates)

            Section("“Hey Bardic” commands") {
                Toggle("Listen for “Hey Bardic” at the start of a dictation", isOn: $voiceCommands)
                Text("Start a dictation with “Hey Bardic” to change a setting instead of typing. Nothing is pasted, and the pill confirms the change. Examples:\n• “Hey Bardic, add Living Internet Alliance to my dictionary”\n• “Hey Bardic, remove Kubernetes from my dictionary”\n• “Hey Bardic, change the push-to-talk key to the function key”\n• “Hey Bardic, turn off AI cleanup” / “turn on grammar fixes” / “turn off lists”")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Permissions") {
                LabeledContent("Microphone") {
                    Text(state.micGranted ? "Granted" : "Not granted").foregroundStyle(state.micGranted ? .green : .red)
                }
                LabeledContent("Accessibility") {
                    HStack {
                        Text(state.accessibilityGranted ? "Granted" : "Not granted")
                            .foregroundStyle(state.accessibilityGranted ? .green : .red)
                        if !state.accessibilityGranted {
                            Button("Open Settings") { Permissions.openAccessibilitySettings() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CleanupTab: View {
    @EnvironmentObject var state: AppState
    @AppStorage("aiCleanup") private var aiCleanup = true
    @AppStorage("contextAware") private var contextAware = true

    private static let ruleInfo: [(CleanupRules.Rule, String, String)] = [
        (.selfCorrections, "Apply self-corrections", "“Tuesday, no wait, Wednesday” becomes “Wednesday”."),
        (.formattingCommands, "Spoken formatting commands", "“new line”, “bullet point”, “comma” and “period” become formatting."),
        (.autoLists, "Turn enumerations into lists", "Several items in a row become a bulleted list."),
        (.writtenForms, "Written numbers, times and addresses", "“three thirty pm” becomes “3:30 PM”, “at gmail dot com” becomes “@gmail.com”."),
        (.grammarFixes, "Fix grammar and misheard words", "When off, only punctuation and capitals are changed."),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("AI cleanup", isOn: $aiCleanup)
                Text("Removes fillers (um, uh), stutters and false starts, and fixes punctuation and capitals. When off, Whisper's text is pasted as-is.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Adapt tone to the current app (Slack, Mail, Xcode…)", isOn: $contextAware)
                    .disabled(!aiCleanup)
            }

            Section {
                ForEach(Self.ruleInfo, id: \.0) { rule, title, detail in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(title, isOn: Binding(
                            get: { state.cleanupRules[rule] },
                            set: { state.cleanupRules[rule] = $0 }))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("What cleanup does")
                    Spacer()
                    if state.applyingRules {
                        ProgressView().controlSize(.small)
                        Text("Applying…").font(.caption)
                    }
                }
            } footer: {
                Text("Whisper itself already writes digits and punctuation. Turning a rule off stops the AI from changing that part further; it doesn't make the text word-for-word.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!aiCleanup)
        }
        .formStyle(.grouped)
    }
}

private struct ModelsTab: View {
    @EnvironmentObject var state: AppState
    @AppStorage("speechModel") private var speechModelRaw = SpeechModel.largeV3Turbo.rawValue
    @AppStorage("cleanupModel") private var cleanupModelRaw = CleanupModel.qwen3_4B.rawValue

    var body: some View {
        Form {
            Picker("Speech recognition", selection: $speechModelRaw) {
                ForEach(SpeechModel.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Picker("Cleanup LLM", selection: $cleanupModelRaw) {
                ForEach(CleanupModel.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text("Everything runs on this Mac. Models download once from Hugging Face, then work offline.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Apply & reload models") { Task { await state.loadModels() } }
                if case .loading(let msg) = state.phase { ProgressView().controlSize(.small); Text(msg).font(.caption) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictionaryTab: View {
    @EnvironmentObject var state: AppState
    @AppStorage("vocabulary") private var vocabularyText = ""
    /// Edited locally so a new, still-empty row doesn't vanish; saved on every change.
    @State private var terms: [String] = []
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Personal dictionary").font(.headline)
            Text("Add names, companies, products and jargon that Bardic gets wrong. Type each one in its own box, spelled exactly the way it should appear. Bardic listens for these words and writes them this way.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Examples: Living Internet Alliance · Siobhan · Kubernetes · GitHub")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(terms.indices, id: \.self) { i in
                    HStack {
                        TextField("Name or term", text: Binding(
                            get: { i < terms.count ? terms[i] : "" },
                            set: { if i < terms.count { terms[i] = $0.replacingOccurrences(of: ",", with: "") } }))
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: i)
                        Button { terms.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                    }
                }
                if terms.isEmpty {
                    Text("No terms yet.").foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button { terms.append(""); focused = terms.count - 1 } label: {
                    Label("Add term", systemImage: "plus")
                }
                Spacer()
                Text("Or say “Hey Bardic, add Living Internet Alliance to my dictionary.”")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { terms = state.vocabulary }
        .onChange(of: terms) { _, new in
            let joined = new.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            if joined != vocabularyText { vocabularyText = joined }
        }
        // A voice command may add a term while this tab is open.
        .onChange(of: vocabularyText) { _, _ in
            let saved = state.vocabulary
            if saved != terms.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                terms = saved
            }
        }
    }
}

private struct AboutTab: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var copied = false
    @State private var checking = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Bardic").font(.title.bold())
                Text("Version \(UpdateChecker.currentVersion) (build \(Diagnostics.buildNumber))")
                    .foregroundStyle(.secondary)
                Text("Local, private voice dictation. Free and open source (MIT).")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                if let update = updates.available {
                    Button("Download \(update.version)") { NSWorkspace.shared.open(update.url) }
                } else {
                    Button(checking ? "Checking…" : "Check for updates") {
                        checking = true
                        Task { await updates.check(); checking = false }
                    }
                    .disabled(checking)
                }
                if let result = updates.lastResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Link("GitHub page", destination: UpdateChecker.pageURL)
                Button("Acknowledgements") {
                    if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }

            Divider().padding(.vertical, 4)

            VStack(spacing: 6) {
                Button(copied ? "Copied" : "Copy debug info") {
                    Diagnostics.copyReport(state)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                Text("Versions, Mac model, model status and recent log lines, for a bug report. No dictated text is included.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading) {
            List(state.history) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).textSelection(.enabled)
                    if item.raw != item.text {
                        Text("raw: \(item.raw)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.app ?? "–") · \(item.usedLLM ? "AI" : "raw") · \(item.timing)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .contextMenu { Button("Copy") { state.copy(item.text) } }
            }
            HStack {
                Text("Stored only on this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear history", role: .destructive) { state.clearHistory() }
            }
        }
    }
}
