import Foundation

/// A spoken instruction to Bardic itself, e.g. "Hey Bardic, add Living Internet Alliance to my
/// dictionary". Only a dictation that *starts* with the wake phrase is a command; it changes a
/// setting and nothing is pasted.
///
/// Parsing is a fixed set of patterns rather than the cleanup model: it's instant, predictable, and
/// can't be talked into changing something the user didn't ask for.
public enum VoiceCommand: Equatable, Sendable {
    case addToDictionary(String)
    case removeFromDictionary(String)
    /// Raw value of the app's `TriggerKey`: rightOption, rightCommand, rightControl or fn.
    case setTriggerKey(String)
    case setAICleanup(Bool)
    case setRule(CleanupRules.Rule, Bool)
    case setToneAdaptation(Bool)
    case help
    /// Addressed to Bardic, but not understood. Holds what was heard after the wake phrase.
    case unknown(String)

    /// The command's kind for the log, without anything the user said: dictionary terms and the text
    /// of an unknown command stay out of the unified log and "Copy debug info".
    public var logDescription: String {
        switch self {
        case .addToDictionary: return "addToDictionary"
        case .removeFromDictionary: return "removeFromDictionary"
        case .setTriggerKey(let key): return "setTriggerKey(\(key))"
        case .setAICleanup(let on): return "setAICleanup(\(on))"
        case .setRule(let rule, let on): return "setRule(\(rule.rawValue), \(on))"
        case .setToneAdaptation(let on): return "setToneAdaptation(\(on))"
        case .help: return "help"
        case .unknown: return "unknown"
        }
    }

    /// Longest dictionary term a voice command may add. Longer ones are refused: every term goes into
    /// each cleanup prompt and into Whisper's prompt.
    public static let maxDictionaryTermLength = 48

    /// Returns nil when the transcript doesn't start with "Hey Bardic" (it's ordinary dictation).
    public static func parse(_ transcript: String) -> VoiceCommand? {
        guard let body = commandBody(transcript) else { return nil }
        let lower = body.lowercased()
        if lower.isEmpty { return .help }

        if let term = match(body, #"^(?:please\s+)?(?:add|put)\s+(.+?)\s+(?:to|in|into)\s+(?:my\s+|the\s+)?(?:personal\s+)?(?:dictionary|vocabulary)(?:\s+please)?$"#) {
            return cleanTerm(term).map(VoiceCommand.addToDictionary) ?? .unknown(body)
        }
        if let term = match(body, #"^(?:please\s+)?(?:remove|delete|take)\s+(.+?)\s+(?:from|out of)\s+(?:my\s+|the\s+)?(?:personal\s+)?(?:dictionary|vocabulary)(?:\s+please)?$"#) {
            return cleanTerm(term).map(VoiceCommand.removeFromDictionary) ?? .unknown(body)
        }
        if let keyName = match(lower, #"^(?:please\s+)?(?:change|set|switch|make)\s+(?:the\s+|my\s+)?(?:push[\s-]?to[\s-]?talk\s+|dictation\s+|trigger\s+|hot\s?)?key\s+(?:to|into)\s+(?:the\s+)?(.+?)(?:\s+key)?$"#)
            ?? match(lower, #"^(?:please\s+)?use\s+(?:the\s+)?(.+?)(?:\s+key)?(?:\s+(?:as|for)\s+(?:the\s+)?(?:push[\s-]?to[\s-]?talk|dictation|trigger)(?:\s+key)?)?$"#) {
            if let key = triggerKey(named: keyName) { return .setTriggerKey(key) }
            return .unknown(body)
        }
        if let (thing, on) = toggle(lower) {
            if thing.range(of: #"^(?:the\s+)?(?:ai\s+)?clean\s?-?up$"#, options: .regularExpression) != nil {
                return .setAICleanup(on)
            }
            if thing.range(of: #"tone"#, options: .regularExpression) != nil { return .setToneAdaptation(on) }
            if let rule = rule(named: thing) { return .setRule(rule, on) }
            return .unknown(body)
        }
        if lower.range(of: #"^(?:help|what can (?:i|you) (?:say|do)|what are (?:the|your) commands)"#,
                       options: .regularExpression) != nil {
            return .help
        }
        return .unknown(body)
    }

    /// What follows the wake phrase, without leading punctuation and the final period; nil when the
    /// transcript doesn't start with it. Whisper writes the name a few ways, so near-misses count.
    static func commandBody(_ transcript: String) -> String? {
        let pattern = #"^\s*(?:hey|hay|hi|okay|ok)[\s,.!]+(?:bardic|bardick|bardik|bartic|bardics|bar\s?dick|bardock|bardig)\b[\s,.!:;-]*"#
        guard let range = transcript.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        var body = String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = body.last, ".!?".contains(last) { body.removeLast() }
        return body.trimmingCharacters(in: .whitespaces)
    }

    private static func match(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// "turn off grammar fixes", "turn grammar fixes off", "enable lists", "disable cleanup".
    private static func toggle(_ lower: String) -> (String, Bool)? {
        if let thing = match(lower, #"^(?:please\s+)?(?:turn|switch)\s+on\s+(.+)$"#) { return (thing, true) }
        if let thing = match(lower, #"^(?:please\s+)?(?:turn|switch)\s+off\s+(.+)$"#) { return (thing, false) }
        if let thing = match(lower, #"^(?:please\s+)?(?:turn|switch)\s+(.+?)\s+on$"#) { return (thing, true) }
        if let thing = match(lower, #"^(?:please\s+)?(?:turn|switch)\s+(.+?)\s+off$"#) { return (thing, false) }
        if let thing = match(lower, #"^(?:please\s+)?(?:enable|start)\s+(.+)$"#) { return (thing, true) }
        if let thing = match(lower, #"^(?:please\s+)?(?:disable|stop)\s+(.+)$"#) { return (thing, false) }
        return nil
    }

    static func triggerKey(named name: String) -> String? {
        let n = name.lowercased().replacingOccurrences(of: #"[^a-z ]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        switch n {
        case "right option", "option", "right alt", "alt", "right option key": return "rightOption"
        case "right command", "command", "right cmd", "cmd": return "rightCommand"
        case "right control", "control", "right ctrl", "ctrl": return "rightControl"
        case "function", "fn", "f n", "globe", "function globe", "fn globe", "globe function": return "fn"
        default: return nil
        }
    }

    static func rule(named thing: String) -> CleanupRules.Rule? {
        let t = thing.replacingOccurrences(of: #"^(?:the\s+)"#, with: "", options: .regularExpression)
        if t.range(of: #"correction"#, options: .regularExpression) != nil { return .selfCorrections }
        if t.range(of: #"formatting|voice commands|spoken commands"#, options: .regularExpression) != nil { return .formattingCommands }
        if t.range(of: #"list"#, options: .regularExpression) != nil { return .autoLists }
        if t.range(of: #"written|number|times|emails"#, options: .regularExpression) != nil { return .writtenForms }
        if t.range(of: #"grammar"#, options: .regularExpression) != nil { return .grammarFixes }
        return nil
    }

    /// Strips quotes and a leading "the" before a capitalized name ("the Living Internet Alliance"
    /// → "Living Internet Alliance"). Commas are dropped because they separate dictionary entries.
    static func cleanTerm(_ term: String) -> String? {
        var t = term.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
        if let r = t.range(of: #"^(?:the|a|an)\s+(?=\p{Lu})"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        t = t.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
