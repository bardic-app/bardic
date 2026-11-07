import AppKit
import Combine
import OSLog
import ServiceManagement
import SwiftUI
import BardicCore

@MainActor
final class LevelMeter: ObservableObject {
    @Published var level: Float = 0
}

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let raw: String
    let text: String
    let app: String?
    let usedLLM: Bool
    let timing: String
}

enum Phase: Equatable {
    case loading(String)
    case idle
    case recording(handsFree: Bool)
    case processing
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "bardic", category: "app")

    /// Replaces the home folder with "~" so log lines that end up in "Copy debug info" (errors often
    /// carry file paths) don't reveal the macOS user name.
    nonisolated static func redactingHome(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // Persisted preferences
    @AppStorage("triggerKey") var triggerKeyRaw = TriggerKey.rightOption.rawValue
    @AppStorage("speechModel") var speechModelRaw = SpeechModel.largeV3Turbo.rawValue
    @AppStorage("cleanupModel") var cleanupModelRaw = CleanupModel.qwen3_4B.rawValue
    @AppStorage("aiCleanup") var aiCleanup = true
    @AppStorage("contextAware") var contextAware = true
    @AppStorage("vocabulary") var vocabularyText = ""
    @AppStorage("language") var language = "en"
    @AppStorage("addTrailingSpace") var addTrailingSpace = true
    /// A dictation starting with "Hey Bardic" changes a setting instead of being pasted.
    @AppStorage("voiceCommands") var voiceCommands = true
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    /// JSON-encoded `CleanupRules`; empty means all rules on.
    @AppStorage("cleanupRules") private var cleanupRulesJSON = ""

    @Published var phase: Phase = .loading("Starting…") {
        didSet { if phase != oldValue { AppState.log.notice("phase: \(AppState.redactingHome(String(describing: self.phase)), privacy: .public)") } }
    }
    /// Mic level for the HUD bars. Kept out of AppState's own @Published properties: it changes
    /// ~40 times a second, and every AppState change also rebuilds the menu bar button, which then
    /// drops clicks (the dropdown wouldn't open while recording).
    let meter = LevelMeter()
    /// Short message shown in the HUD while idle, e.g. when nothing was heard.
    @Published var notice: String?
    @Published var history: [HistoryItem] = []
    /// The speech model couldn't be downloaded or loaded; the UI offers Retry.
    @Published var modelLoadFailed = false
    /// The cleanup model failed to load. Dictation still works, pasting the raw transcript.
    @Published var cleanupUnavailable = false
    @Published var micGranted = Permissions.microphoneGranted
    @Published var accessibilityGranted = Permissions.accessibilityGranted
    /// The cleanup model is rebuilding its prompt cache after a rule change.
    @Published var applyingRules = false
    private var rulesTask: Task<Void, Never>?

    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let cleaner = Cleaner()
    let hotkeys = HotkeyManager()
    lazy var hud = HUDController(state: self)
    lazy var onboarding = OnboardingController(state: self)

    private var targetApp: NSRunningApplication?
    /// The most recent app in front other than Bardic, so text started or stopped from Bardic's
    /// own menu still goes to the app the user is working in.
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private(set) var recordStart = Date()
    /// Last time the mic picked up something louder than room noise. Not @Published: the HUD
    /// polls it on a timer rather than redrawing for every audio chunk.
    private(set) var lastVoiceAt = Date()
    private var permissionTimer: Timer?

    var vocabulary: [String] {
        get {
            vocabularyText.split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            vocabularyText = newValue.map { $0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    var cleanupRules: CleanupRules {
        get {
            guard let data = cleanupRulesJSON.data(using: .utf8),
                  let rules = try? JSONDecoder().decode(CleanupRules.self, from: data) else { return CleanupRules() }
            return rules
        }
        set {
            guard newValue != cleanupRules,
                  let data = try? JSONEncoder().encode(newValue) else { return }
            objectWillChange.send()
            cleanupRulesJSON = String(decoding: data, as: UTF8.self)
            applyRulesSoon()
        }
    }

    /// Rebuilding the cleanup prompt cache takes about a second, so wait for the user to stop
    /// flipping toggles first.
    private func applyRulesSoon() {
        rulesTask?.cancel()
        rulesTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let rules = cleanupRules
            applyingRules = true
            do {
                try await cleaner.configure(rules: rules)
                AppState.log.notice("cleanup rules applied; off: \(rules.disabled.map(\.rawValue).joined(separator: ","), privacy: .public)")
            } catch {
                AppState.log.error("applying cleanup rules failed: \(AppState.redactingHome(String(describing: error)), privacy: .public)")
            }
            // A newer change may still be rebuilding; leave "Applying…" up until it finishes.
            if rules == cleanupRules { applyingRules = false }
        }
    }

    var triggerKey: TriggerKey { TriggerKey(rawValue: triggerKeyRaw) ?? .rightOption }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                AppState.log.error("launch at login failed: \(AppState.redactingHome(error.localizedDescription), privacy: .public)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - Startup

    func start() {
        chooseDefaultModelsForThisMac()
        removeRetiredModels()
        loadHistory()
        if !UserDefaults.standard.bool(forKey: "debugSaveAudio") { removeDebugAudio() }
        recorder.onLevel = { [weak self] rms in
            Task { @MainActor in
                guard let self else { return }
                self.meter.level = AudioRecorder.meterLevel(rms)
                if rms > AudioRecorder.voiceLevel { self.lastVoiceAt = Date() }
            }
        }
        hotkeys.onEvent = { [weak self] e in self?.handle(e) }
        hotkeys.start()
        watchPermissions()
        lastExternalApp = Self.externalFrontmostApp
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != NSRunningApplication.current { AppState.shared.lastExternalApp = app }
            }
        }

        // People who already granted both permissions (e.g. upgrading from an earlier build) have
        // effectively been through setup.
        if !hasCompletedOnboarding && micGranted && accessibilityGranted {
            hasCompletedOnboarding = true
        }
        if hasCompletedOnboarding {
            Task {
                if Permissions.microphoneUndetermined { micGranted = await Permissions.requestMicrophone() }
                if !Permissions.accessibilityGranted { Permissions.promptAccessibility() }
            }
        } else {
            // The setup window asks for permissions one at a time, with an explanation.
            onboarding.show()
        }
        Task { await loadModels() }
        UpdateChecker.shared.start()
    }

    /// The 4B cleanup model needs ~2.3 GB of RAM on top of Whisper; on 8 GB Macs that competes with
    /// everything else, so start them on the 1.5B model. Only applies until the user picks one.
    /// Qwen 2.5 3B was the default cleanup model until 0.3.0. Its research-only license doesn't fit a
    /// public app, so it was replaced. Delete its download (~1.6 GB); anyone who had it selected now
    /// gets the new default.
    private func removeRetiredModels() {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/mlx-community/Qwen2.5-3B-Instruct-4bit", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
            AppState.log.notice("Removed the retired Qwen 2.5 3B download")
        } catch {
            AppState.log.error("Couldn't remove the retired Qwen 2.5 3B download: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func chooseDefaultModelsForThisMac() {
        guard UserDefaults.standard.object(forKey: "cleanupModel") == nil else { return }
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if gb <= 8.5 {
            cleanupModelRaw = CleanupModel.qwen25_1_5B.rawValue
            AppState.log.notice("\(Int(gb.rounded())) GB RAM: defaulting to the 1.5B cleanup model")
        }
    }

    var speechModel: SpeechModel { SpeechModel(rawValue: speechModelRaw) ?? .largeV3Turbo }
    var cleanupModel: CleanupModel { CleanupModel(rawValue: cleanupModelRaw) ?? .qwen3_4B }

    func loadModels() async {
        let speech = speechModel
        let llm = cleanupModel
        modelLoadFailed = false
        cleanupUnavailable = false
        let report: @Sendable (String) -> Void = { msg in
            Task { @MainActor in
                // A late progress message mustn't overwrite the outcome once loading has finished.
                if case .loading = AppState.shared.phase { AppState.shared.phase = .loading(msg) }
            }
        }
        phase = .loading("Loading speech model…")

        // Check for room before starting a multi-gigabyte download that would fail partway.
        var needed: Int64 = Transcriber.isDownloaded(speech) ? 0 : speech.approxBytes
        if aiCleanup && !Cleaner.isDownloaded(llm) { needed += llm.approxBytes }
        if needed > 0, let free = Paths.freeDiskBytes, free < needed + 1_000_000_000 {
            let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_000_000_000) }
            AppState.log.error("not enough disk: need \(needed), free \(free)")
            modelLoadFailed = true
            phase = .error("Bardic needs about \(gb(needed + 1_000_000_000)) free to download its models; this Mac has \(gb(free)).")
            return
        }

        do {
            try await transcriber.load(speech, progress: report)
        } catch {
            AppState.log.error("speech model load failed: \(AppState.redactingHome(String(describing: error)), privacy: .public)")
            modelLoadFailed = true
            phase = .error(Self.friendlyLoadError(error, what: "speech model"))
            return
        }

        if aiCleanup {
            phase = .loading("Loading language model…")
            do {
                try await cleaner.load(llm, rules: cleanupRules, progress: report)
            } catch {
                // Dictation still works without cleanup: it pastes Whisper's text as-is.
                AppState.log.error("cleanup model load failed: \(AppState.redactingHome(String(describing: error)), privacy: .public)")
                cleanupUnavailable = true
            }
        }
        phase = .idle
    }

    func retryModelLoad() {
        Task { await loadModels() }
    }

    private static func friendlyLoadError(_ error: Error, what: String) -> String {
        if isNetworkError(error) {
            return "Couldn't download the models. Check your internet connection, then press Retry."
        }
        return "The \(what) didn't load: \(error.localizedDescription)"
    }

    /// Accessibility is granted in System Settings while we run; poll so the UI updates and
    /// global key monitors are re-registered once trust is granted.
    private func watchPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ax = Permissions.accessibilityGranted
                if ax != self.accessibilityGranted {
                    self.accessibilityGranted = ax
                    if ax { self.hotkeys.start() }
                }
                self.micGranted = Permissions.microphoneGranted
            }
        }
    }

    // MARK: - Dictation flow

    private func handle(_ e: HotkeyManager.Event) {
        switch e {
        case .start: startRecording(handsFree: false)
        case .handsFreeLocked: if case .recording = phase { phase = .recording(handsFree: true) }
        case .stop: Task { await stopAndProcess() }
        case .cancel: cancelRecording()
        }
    }

    func toggleFromMenu() {
        if case .recording = phase {
            finishFromUI()
        } else {
            startRecording(handsFree: true)
            // Let a tap of the dictation key (or Esc) end it, same as hotkey hands-free mode.
            if case .recording = phase { hotkeys.beginHandsFree() }
        }
    }

    /// Finish button in the HUD, or Stop in the menu.
    func finishFromUI() {
        hotkeys.reset()
        Task { await stopAndProcess() }
    }

    /// Cancel button in the HUD.
    func cancelFromUI() {
        hotkeys.reset()
        cancelRecording()
    }

    private static var externalFrontmostApp: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front == NSRunningApplication.current ? nil : front
    }

    func startRecording(handsFree: Bool) {
        guard phase == .idle || { if case .error = phase { return true }; return false }() else {
            hotkeys.reset()
            if case .loading = phase { NSSound.beep() }
            return
        }
        guard micGranted else {
            phase = .error("Microphone access is off. Enable it in System Settings.")
            hotkeys.reset()
            hud.show()
            return
        }
        targetApp = Self.externalFrontmostApp ?? lastExternalApp
        notice = nil
        do {
            try recorder.start()
            // Wake the cleanup model while the user talks, so it isn't cold when they finish.
            if aiCleanup { Task { await cleaner.warmUp() } }
            recordStart = Date()
            lastVoiceAt = recordStart
            phase = .recording(handsFree: handsFree)
            hud.show()
        } catch {
            phase = .error(error.localizedDescription)
            hotkeys.reset()
            hud.flashAndHide()
        }
    }

    func cancelRecording() {
        guard case .recording = phase else { return }
        recorder.stop()
        phase = .idle
        hud.hide()
    }

    func stopAndProcess() async {
        guard case .recording = phase else { return }
        // Bardic is never the app in front, so without this macOS may throttle it (App Nap) while
        // it transcribes and cleans up.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Transcribing and cleaning up a dictation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let rms = AudioRecorder.rms(samples)
        let speech = AudioRecorder.speechLevel(samples)
        let levels = String(format: "%.1fs, speech %d dBFS, rms %d dBFS, peak %d dBFS", seconds,
                            AudioRecorder.dB(speech), AudioRecorder.dB(rms),
                            AudioRecorder.dB(AudioRecorder.peak(samples)))

        // Ignore accidental taps and silence (Whisper hallucinates "Thank you." on silence).
        guard seconds > 0.4 else {
            AppState.log.notice("dictation: \(levels, privacy: .public) → too short, ignored")
            phase = .idle
            hud.hide()
            return
        }
        guard speech > AudioRecorder.silenceLevel else {
            AppState.log.notice("dictation: \(levels, privacy: .public) → below silence threshold")
            saveDebugAudio(samples, outcome: "silent")
            phase = .idle
            flashNotice("Didn't catch that. Is the mic too quiet?")
            return
        }

        // Paste where the user is now: in hands-free mode they may have clicked into another app.
        if let front = Self.externalFrontmostApp { targetApp = front } else if targetApp == nil { targetApp = lastExternalApp }
        phase = .processing
        let appName = targetApp?.localizedName
        let style: DictationStyle = contextAware ? .forBundleID(targetApp?.bundleIdentifier) : .standard

        do {
            let t0 = Date()
            // "Bardic" in Whisper's prompt helps it hear the wake phrase.
            let raw = try await transcriber.transcribe(samples, language: language.isEmpty ? nil : language,
                                                       vocabulary: voiceCommands ? vocabulary + ["Bardic"] : vocabulary)
            let tASR = Date().timeIntervalSince(t0)
            guard !raw.isEmpty else {
                AppState.log.notice("dictation: \(levels, privacy: .public) → no words recognized")
                saveDebugAudio(samples, outcome: "empty")
                phase = .idle
                flashNotice("Didn't catch any words. Try again?")
                return
            }

            if voiceCommands, let command = VoiceCommand.parse(raw) {
                let reply = perform(command)
                AppState.log.notice("dictation: \(levels, privacy: .public) → voice command: \(command.logDescription, privacy: .public)")
                phase = .idle
                flashNotice(reply)
                return
            }

            var text = raw
            var usedLLM = false
            let t1 = Date()
            if aiCleanup, CleanupPrompt.needsLLM(raw, rules: cleanupRules), await cleaner.isLoaded {
                let result = try await cleaner.clean(raw, style: style, vocabulary: vocabulary)
                text = result.text
                usedLLM = result.usedLLM
                if let s = result.stats {
                    AppState.log.notice("cleanup: \(s.promptTokens) prompt tokens, prefix cache \(s.usedPrefixCache ? "hit" : "MISS", privacy: .public), \(String(format: "%.2fs", Date().timeIntervalSince(t1)), privacy: .public)\(result.usedLLM ? "" : ", model output rejected", privacy: .public)")
                }
            }
            let tLLM = Date().timeIntervalSince(t1)
            if addTrailingSpace, !text.hasSuffix("\n") { text += " " }

            // Make sure the original app still has focus before pasting.
            if let app = targetApp, NSWorkspace.shared.frontmostApplication != app {
                app.activate()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            await TextInserter.insert(text)
            AppState.log.notice("dictation: \(levels, privacy: .public) → inserted \(text.count) chars into \(appName ?? "?", privacy: .private) (style \(style.rawValue, privacy: .public))")
            saveDebugAudio(samples, outcome: "ok")

            let timing = String(format: "%.1fs audio · whisper %.2fs · llm %.2fs", seconds, tASR, tLLM)
            addHistory(HistoryItem(date: Date(), raw: raw, text: text.trimmingCharacters(in: .whitespaces),
                                   app: appName, usedLLM: usedLLM, timing: timing))
            phase = .idle
            hud.hide()
        } catch {
            phase = .error(error.localizedDescription)
            hud.flashAndHide()
        }
    }

    // MARK: - Voice commands

    /// Carries out a "Hey Bardic" command and returns the confirmation shown in the pill.
    private func perform(_ command: VoiceCommand) -> String {
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        switch command {
        case .addToDictionary(let term):
            guard term.count <= VoiceCommand.maxDictionaryTermLength, !term.contains(where: \.isNewline) else {
                return "That's too long for a dictionary entry (\(VoiceCommand.maxDictionaryTermLength) characters at most)"
            }
            if vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                return "“\(term)” is already in your dictionary"
            }
            vocabulary.append(term)
            return "Added “\(term)” to your dictionary"
        case .removeFromDictionary(let term):
            let before = vocabulary.count
            vocabulary.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
            return vocabulary.count < before ? "Removed “\(term)” from your dictionary"
                                             : "“\(term)” isn't in your dictionary"
        case .setTriggerKey(let raw):
            guard let key = TriggerKey(rawValue: raw) else { return "Bardic doesn't know that key" }
            triggerKeyRaw = key.rawValue
            hotkeys.start()
            return "Push-to-talk key is now \(key.displayName)"
        case .setAICleanup(let on):
            aiCleanup = on
            // Cleanup may have been off since launch, so its model was never loaded.
            if on { Task { if !(await cleaner.isLoaded) { await loadModels() } } }
            return "AI cleanup is \(onOff(on))"
        case .setRule(let rule, let on):
            cleanupRules[rule] = on
            return "\(CleanupRules.displayName(rule)) is \(onOff(on))"
        case .setToneAdaptation(let on):
            contextAware = on
            return "Adapting tone to the app is \(onOff(on))"
        case .help:
            return "Try: “Hey Bardic, add … to my dictionary”, “change the key to Fn”, “turn off grammar fixes”"
        case .unknown(let heard):
            return "Bardic didn't understand: “\(heard)”"
        }
    }

    /// Briefly shows a message in the HUD pill without changing the phase.
    private func flashNotice(_ message: String) {
        notice = message
        hud.flashAndHide(after: 2.5)
    }

    /// Off by default. `defaults write com.booleanmode.bardic debugSaveAudio -bool YES` keeps the
    /// last 20 recordings in ~/Library/Application Support/Bardic/DebugAudio for diagnosing problems.
    private func saveDebugAudio(_ samples: [Float], outcome: String) {
        guard UserDefaults.standard.bool(forKey: "debugSaveAudio") else {
            // Switched off (possibly while running): don't keep recordings from when it was on.
            removeDebugAudio()
            return
        }
        let dir = debugAudioURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        try? AudioRecorder.writeWAV(samples, to: dir.appendingPathComponent("\(stamp)-\(outcome).wav"))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for old in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(20) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private var debugAudioURL: URL { Paths.appSupport.appendingPathComponent("DebugAudio", isDirectory: true) }

    private func removeDebugAudio() {
        let dir = debugAudioURL
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - History

    private var historyURL: URL { Paths.appSupport.appendingPathComponent("history.json") }

    /// History holds everything dictated, so only this user may read it. An atomic write replaces the
    /// file, which resets its permissions, so this runs after every write as well as at launch.
    private func restrictHistoryPermissions() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    private func addHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        guard let data = try? JSONEncoder().encode(history) else { return }
        if FileManager.default.fileExists(atPath: historyURL.path) {
            try? data.write(to: historyURL, options: .atomic)
        } else {
            // Create it private from the start rather than tightening it afterwards.
            FileManager.default.createFile(atPath: historyURL.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
        restrictHistoryPermissions()
    }

    private func loadHistory() {
        restrictHistoryPermissions()
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        history = items
    }

    func clearHistory() {
        history.removeAll()
        try? FileManager.default.removeItem(at: historyURL)
        removeDebugAudio()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
