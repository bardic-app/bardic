// bardic-cli — exercise the Bardic pipeline from the terminal.
//
//   bardic-cli transcribe <audio-file>        Whisper + LLM cleanup on an audio file
//   bardic-cli clean "<raw text>" [style] [--off corrections,formatting,lists,forms,grammar]
//                                             LLM cleanup only (style: standard|casual|formal|code)
//   bardic-cli eval                           run the cleanup fixtures and report pass/fail
//
// Env: BARDIC_LLM=<model id> picks the cleanup model; BARDIC_NO_CACHE=1 disables the prompt cache.

import AVFoundation
import Foundation
import BardicCore

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func loadAudio16k(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: inBuf)
    let conv = AVAudioConverter(from: file.processingFormat, to: target)!
    let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
    var done = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return inBuf
    }
    if let err { throw err }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

struct Fixture {
    let raw: String
    let style: DictationStyle
    let mustContain: [String]
    let mustNotContain: [String]
    var rules = CleanupRules()
    var vocabulary: [String] = []
    /// The output guard may hand back the raw transcript instead (see `CleanupPrompt.validate`).
    var rawFallbackOK = false
}

let fixtures: [Fixture] = [
    .init(raw: "um so basically i was thinking we could uh push the launch to friday",
          style: .standard, mustContain: ["Friday"], mustNotContain: ["um", "uh", "basically"]),
    .init(raw: "let's meet at the cafe at two no actually make it three",
          style: .standard, mustContain: ["3"], mustNotContain: ["two", "actually"]),
    .init(raw: "what is the square root of one hundred and forty four",
          style: .standard, mustContain: ["What is", "?"], mustNotContain: ["12"]),
    .init(raw: "explain quantum computing to me in simple terms",
          style: .standard, mustContain: ["quantum computing"], mustNotContain: ["qubit", "superposition"]),
    .init(raw: "shopping list bullet point apples bullet point oat milk bullet point coffee beans",
          style: .standard, mustContain: ["- Apples", "- Oat milk", "- Coffee beans"], mustNotContain: ["bullet"]),
    .init(raw: "send it to sam at gmail dot com by five thirty pm",
          style: .standard, mustContain: ["@gmail.com", "5:30"], mustNotContain: ["dot com"]),
    .init(raw: "yo are you coming tonight",
          style: .casual, mustContain: ["coming tonight"], mustNotContain: []),
    .init(raw: "hi tom thanks for the update new paragraph i will review the the contract tomorrow and get back to you",
          style: .formal, mustContain: ["Tom", "\n\n", "contract"], mustNotContain: ["the the", "new paragraph", "regards", "Your Name"]),
    .init(raw: "git commit dash m fix the login bug",
          style: .code, mustContain: ["git commit -m"], mustNotContain: ["dash"]),
    .init(raw: "i i think the the problem is in the uh the cache layer",
          style: .standard, mustContain: ["cache layer"], mustNotContain: ["the the", "I I", "uh"]),

    // Each rule switched off.
    .init(raw: "send the invite to mark no wait to jenny",
          style: .standard, mustContain: ["Mark", "Jenny"], mustNotContain: [],
          rules: CleanupRules(disabling: [.selfCorrections])),
    .init(raw: "um move it to tuesday no actually wednesday",
          style: .standard, mustContain: ["Tuesday", "Wednesday"], mustNotContain: ["um"],
          rules: CleanupRules(disabling: [.selfCorrections])),
    .init(raw: "add milk bullet point eggs bullet point bread",
          style: .standard, mustContain: ["bullet point"], mustNotContain: [],
          rules: CleanupRules(disabling: [.formattingCommands]), rawFallbackOK: true),
    .init(raw: "send it to sam at gmail dot com by five thirty pm",
          style: .standard, mustContain: ["five thirty", "dot com"], mustNotContain: ["5:30"],
          rules: CleanupRules(disabling: [.writtenForms])),
    .init(raw: "we need to buy apples oranges bananas grapes and pears",
          style: .standard, mustContain: ["oranges, bananas"], mustNotContain: [],
          rules: CleanupRules(disabling: [.autoLists])),
    .init(raw: "uh me and him was going to the store tomorrow",
          style: .standard, mustContain: ["him was going"], mustNotContain: ["uh"],
          rules: CleanupRules(disabling: [.grammarFixes]), rawFallbackOK: true),

    // The dictionary must not leak into text that doesn't mention it.
    .init(raw: "sorry to hear you can't join us on today's call but you will see more calls happening soon enough",
          style: .standard, mustContain: ["Sorry", "more calls"], mustNotContain: ["Alliance", "Summit", "LIA", "Bardic"],
          vocabulary: ["Living Internet Alliance", "Bardic", "The Alliance", "LIA", "Future-Proof Creator Summit", "The Summit"],
          rawFallbackOK: true),
    .init(raw: "i emailed the living internet alliance about the summit",
          style: .standard, mustContain: ["Living Internet Alliance"], mustNotContain: [],
          vocabulary: ["Living Internet Alliance", "Bardic", "LIA", "The Summit"]),

    // Held out: worded unlike any prompt example, so they test the rule rather than copying.
    .init(raw: "invite priya actually make that daniel",
          style: .standard, mustContain: ["Priya", "Daniel"], mustNotContain: [],
          rules: CleanupRules(disabling: [.selfCorrections])),
    .init(raw: "put a comma after hello in the greeting",
          style: .standard, mustContain: ["comma"], mustNotContain: [],
          rules: CleanupRules(disabling: [.formattingCommands]), rawFallbackOK: true),
    .init(raw: "it costs forty dollars and starts at nine am",
          style: .standard, mustContain: ["forty", "nine"], mustNotContain: ["40", "9"],
          rules: CleanupRules(disabling: [.writtenForms])),
    .init(raw: "the options are red blue green yellow and purple",
          style: .standard, mustContain: ["blue, green"], mustNotContain: [],
          rules: CleanupRules(disabling: [.autoLists])),
    .init(raw: "um there is three reasons we done it that way",
          style: .standard, mustContain: ["is three", "we done"], mustNotContain: ["um"],
          rules: CleanupRules(disabling: [.grammarFixes]), rawFallbackOK: true),
]

/// `--off a,b` → rules with those switched off. Exits on an unknown name.
func parseRules(_ args: [String]) -> CleanupRules {
    guard let i = args.firstIndex(of: "--off"), i + 1 < args.count else { return CleanupRules() }
    let names = args[i + 1].split(separator: ",").map(String.init)
    let rules = names.compactMap(CleanupRules.Rule.parse)
    guard rules.count == names.count else {
        log("unknown rule in --off \(args[i + 1]); use corrections, formatting, lists, forms, grammar"); exit(2)
    }
    return CleanupRules(disabling: rules)
}

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "help"
let cleaner = Cleaner(usePromptCache: ProcessInfo.processInfo.environment["BARDIC_NO_CACHE"] == nil)
let model = CleanupModel(rawValue: ProcessInfo.processInfo.environment["BARDIC_LLM"] ?? "") ?? .qwen3_4B

do {
    switch command {
    case "transcribe":
        let paths = args.dropFirst()
        guard !paths.isEmpty else { log("usage: bardic-cli transcribe <file>…"); exit(2) }
        let transcriber = Transcriber()
        var t0 = Date()
        try await transcriber.load(.largeV3Turbo) { log($0) }
        try await cleaner.load(model) { log($0) }
        log("models loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        for path in paths {
            let audio = try loadAudio16k(path)
            print("== \((path as NSString).lastPathComponent) (speech \(AudioRecorder.dB(AudioRecorder.speechLevel(audio))) dBFS)")
            t0 = Date()
            let raw = try await transcriber.transcribe(audio)
            let tASR = Date().timeIntervalSince(t0)
            t0 = Date()
            let cleaned = try await cleaner.clean(raw, style: .standard, vocabulary: [])
            let tLLM = Date().timeIntervalSince(t0)
            print("RAW:     \(raw)")
            print("CLEANED: \(cleaned.text)")
            log(String(format: "audio %.1fs | whisper %.2fs | llm %.2fs", Double(audio.count) / 16_000, tASR, tLLM))
        }

    case "clean":
        guard let raw = args.dropFirst().first else { log("usage: bardic-cli clean \"text\" [style] [--off rules]"); exit(2) }
        let style = DictationStyle(rawValue: args.dropFirst(2).first ?? "") ?? .standard
        try await cleaner.load(model, rules: parseRules(Array(args))) { log($0) }
        let t0 = Date()
        let r = try await cleaner.clean(raw, style: style, vocabulary: [])
        print(r.text)
        if let rej = r.rejectedOutput { log("(model output rejected: \(rej))") }
        log(String(format: "llm %.2fs", Date().timeIntervalSince(t0)))

    case "idle":
        // Cleanup latency right after load vs after sitting idle (cold GPU / paged-out weights).
        let wait = Double(args.dropFirst().first ?? "") ?? 120
        try await cleaner.load(model) { log($0) }
        let sample = "so i was thinking we could move the meeting to thursday afternoon if that works for everyone"
        for (i, pause) in [0, wait, 0, wait].enumerated() {
            if pause > 0 { log("idling \(Int(pause))s…"); try await Task.sleep(nanoseconds: UInt64(pause * 1e9)) }
            // The last run warms up first and "talks" for 1.5 s, as the app does from key-down.
            let warm = i == 3
            if warm {
                async let w: Void = cleaner.warmUp()
                try await Task.sleep(nanoseconds: 1_500_000_000)
                await w
            }
            let t0 = Date()
            _ = try await cleaner.clean(sample, style: .standard, vocabulary: [])
            print(String(format: "run %d after %3.0fs idle%@: %.2fs", i + 1, pause, warm ? " + warm-up" : "", Date().timeIntervalSince(t0)))
        }

    case "eval":
        // Output guards, checked without the model.
        var guardFailures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { guardFailures += 1 }
            print("\(ok ? "PASS" : "FAIL") [guard] \(name)")
        }
        let all = CleanupRules()
        check("swapped places are caught", CleanupPrompt.breaksRules(
            output: "I will go to the bookstore, no wait, the mall.",
            raw: "I will go to the mall, no wait, the bookstore.", rules: CleanupRules(disabling: [.selfCorrections])))
        check("an applied self-correction is allowed", !CleanupPrompt.breaksRules(
            output: "I think we should meet on Wednesday at 3 PM.",
            raw: "um so i think we should uh meet on tuesday no wait wednesday at like three pm", rules: all))
        check("an added connecting word is allowed", !CleanupPrompt.breaksRules(
            output: "Created finance tracking and bookkeeping spreadsheets for personal finances, and tested that system and tested the books.",
            raw: "Created finance tracking, bookkeeping spreadsheets for personal finances, and tested that system and tested the books.",
            rules: all))
        check("an appended dictionary term is caught", CleanupPrompt.breaksRules(
            output: "Sorry you can't join today's call. Living Internet Alliance.",
            raw: "Sorry you can't join today's call.", rules: all, vocabulary: ["Living Internet Alliance"]))
        check("a dictionary fix is allowed", !CleanupPrompt.breaksRules(
            output: "We run Kubernetes.", raw: "we run cooper netties", rules: all, vocabulary: ["Kubernetes"]))
        check("written forms are allowed", !CleanupPrompt.breaksRules(
            output: "Send it to sam@gmail.com by 5:30 PM.",
            raw: "send it to sam at gmail dot com by five thirty pm", rules: all))
        check("grammar fix caught when off", CleanupPrompt.breaksRules(
            output: "Me and him were going.", raw: "me and him was going",
            rules: CleanupRules(disabling: [.grammarFixes])))
        check("dictionary spelling allowed when grammar off", !CleanupPrompt.breaksRules(
            output: "We run Kubernetes.", raw: "we run cooper netties",
            rules: CleanupRules(disabling: [.grammarFixes]), vocabulary: ["Kubernetes"]))
        check("fallback keeps \"dot dot dot\"",
              CleanupPrompt.basicCleanup("i was a dot dot dot monkey") == "I was a dot dot dot monkey.")
        check("fallback collapses \"the the\" and drops um",
              CleanupPrompt.basicCleanup("um check the the report") == "Check the report.")
        check("code: an unasked line break is refused",
              CleanupPrompt.validate(output: "ls\nrm -rf ~", raw: "list the files then remove everything", style: .code) == nil)
        check("code: a trailing line break is trimmed",
              CleanupPrompt.validate(output: "git status\n", raw: "git status", style: .code) == "git status")
        check("code: a spoken new line is allowed",
              CleanupPrompt.validate(output: "first line\nsecond line", raw: "first line new line second line", style: .code) != nil)
        check("a paragraph break is allowed outside code",
              CleanupPrompt.validate(output: "Thanks for the update.\n\nI will review it.",
                                     raw: "thanks for the update i will review it", style: .formal) != nil)
        check("an automatic list is allowed outside code",
              CleanupPrompt.validate(output: "We need:\n- Apples\n- Oranges\n- Pears",
                                     raw: "we need apples oranges and pears", style: .standard) != nil)

        // "Hey Bardic" commands.
        let commands: [(String, VoiceCommand?)] = [
            ("Hey Bardic, add the Living Internet Alliance to my personal dictionary.", .addToDictionary("Living Internet Alliance")),
            ("Hey Bardic, remove Kubernetes from my dictionary.", .removeFromDictionary("Kubernetes")),
            ("Hey Bardic, change the push-to-talk key to the function key.", .setTriggerKey("fn")),
            ("Hey Bardick, use right command as the push to talk key", .setTriggerKey("rightCommand")),
            ("Hey, Bardic. Turn off grammar fixes.", .setRule(.grammarFixes, false)),
            ("Hey Bardic, turn lists back on", .setRule(.autoLists, true)),
            ("Hey Bardic turn AI cleanup on.", .setAICleanup(true)),
            ("Hey Bardic, disable self-corrections", .setRule(.selfCorrections, false)),
            ("Hey Bardic, turn off tone adaptation", .setToneAdaptation(false)),
            ("Hey Bardic, what can I say?", .help),
            ("Hey Bardic, make me a sandwich.", .unknown("make me a sandwich")),
            ("I told my friend hey Bardic is great.", nil),
            ("Hey Barbara, are you coming tonight?", nil),
        ]
        for (said, expected) in commands {
            let got = VoiceCommand.parse(said)
            check("command: \(said) → \(got.map { String(describing: $0) } ?? "dictation")", got == expected)
        }
        // The log names the command's kind, never what was said.
        for said in ["Hey Bardic, add Secret Project Name to my dictionary", "Hey Bardic, remove Secret Project Name from my dictionary",
                     "Hey Bardic, tell Sam the secret project name"] {
            let line = VoiceCommand.parse(said)?.logDescription ?? ""
            check("log line for \"\(said)\" leaves out the words", !line.isEmpty && !line.lowercased().contains("secret"))
        }

        try await cleaner.load(model) { log($0) }
        var passed = 0
        for f in fixtures {
            let tRules = Date()
            try await cleaner.configure(rules: f.rules)
            let rebuilt = Date().timeIntervalSince(tRules)
            if rebuilt > 0.05 { log(String(format: "  (rules changed, cache rebuilt in %.2fs)", rebuilt)) }
            let t0 = Date()
            let r = try await cleaner.clean(f.raw, style: f.style, vocabulary: f.vocabulary)
            let dt = Date().timeIntervalSince(t0)
            let missing = f.mustContain.filter { !r.text.contains($0) }
            let forbidden = f.mustNotContain.filter { r.text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: [.regularExpression, .caseInsensitive]) != nil }
            let ok = missing.isEmpty && forbidden.isEmpty && (r.usedLLM || f.rawFallbackOK)
            if ok { passed += 1 }
            let off = f.rules.disabled.isEmpty ? "" : " off: " + f.rules.disabled.map(\.rawValue).joined(separator: ",")
            print("\(ok ? "PASS" : "FAIL") [\(f.style.rawValue)\(off)] \(String(format: "%.2fs", dt))")
            print("  in:  \(f.raw)")
            print("  out: \(r.text.replacingOccurrences(of: "\n", with: "⏎"))")
            if !missing.isEmpty { print("  missing: \(missing)") }
            if !forbidden.isEmpty { print("  forbidden present: \(forbidden)") }
            if let rej = r.rejectedOutput { print("  model output rejected, fallback used: \(rej.replacingOccurrences(of: "\n", with: "⏎"))") }
        }
        print("\n\(passed)/\(fixtures.count) passed (\(model.rawValue)); guards: \(guardFailures == 0 ? "all passed" : "\(guardFailures) failed")")

    default:
        log("usage: bardic-cli transcribe <file> | clean \"text\" [style] [--off rules] | eval")
        log("set BARDIC_LLM=<mlx-community model id> to try another cleanup model")
    }
} catch {
    log("error: \(error.localizedDescription)")
    exit(1)
}
