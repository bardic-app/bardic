import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// On-device LLM that turns a raw transcript into the text the speaker meant (MLX on the GPU).
///
/// The system prompt and few-shot examples (~700 tokens) are identical on every call, so their
/// KV cache is prefilled once at load. Each request copies that cache and only prefills its own
/// short suffix, which cuts cleanup latency from ~1.5 s to a few hundred ms.
public actor Cleaner {
    private var container: ModelContainer?
    private var loadedModel: CleanupModel?

    /// Token IDs of the shared prompt prefix, and the KV cache holding exactly those tokens.
    private var prefixTokens: [Int] = []
    private var prefixCache: [KVCache]?

    /// Which cleanup rules are on. They shape the system prompt and examples, so changing them
    /// rebuilds the prefix cache.
    public private(set) var rules = CleanupRules()

    /// Set to false to prefill the whole prompt every time (for A/B testing the cache).
    private var usePromptCache: Bool

    public init(usePromptCache: Bool = true) {
        self.usePromptCache = usePromptCache
    }

    public var isLoaded: Bool { container != nil }

    /// True when the model's config and weights are on disk.
    public static func isDownloaded(_ model: CleanupModel) -> Bool {
        let folder = Paths.cleanupModel(model)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
    }

    public func load(_ model: CleanupModel, rules: CleanupRules = .init(),
                     progress: (@Sendable (String) -> Void)? = nil) async throws {
        if loadedModel == model, container != nil {
            try await configure(rules: rules)
            return
        }
        self.rules = rules
        container = nil
        prefixCache = nil
        prefixTokens = []
        Memory.cacheLimit = 32 * 1024 * 1024

        progress?("Loading language model…")
        let wasDownloaded = Self.isDownloaded(model)
        var configuration = LLMModelFactory.shared.configuration(id: model.rawValue)
        // Keep the registry's settings for this model, but download the pinned commit.
        if let revision = model.revision { configuration.id = .id(model.rawValue, revision: revision) }
        do {
            container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { p in
                if p.fractionCompleted < 1 {
                    progress?("Downloading language model… \(Int(p.fractionCompleted * 100))%")
                }
            }
        } catch {
            // A complete-looking model that won't load is damaged; remove it so Retry fetches a fresh
            // copy. A partial download is kept, because the next attempt resumes it.
            if wasDownloaded, !isNetworkError(error) {
                try? FileManager.default.removeItem(at: Paths.cleanupModel(model))
            }
            throw error
        }
        loadedModel = model
        try await buildPrefixCache()
        // Warm up the generation path so the first real dictation isn't slow.
        _ = try? await clean("hello there", style: .standard, vocabulary: [])
    }

    /// Switches cleanup rules. Rebuilds the prompt-prefix cache (about 1.3 s on the 3B model) when they
    /// changed. Requests that arrive meanwhile still work, but without the cache, so they're slower.
    public func configure(rules: CleanupRules) async throws {
        guard rules != self.rules else { return }
        self.rules = rules
        guard container != nil else { return }
        prefixCache = nil
        prefixTokens = []
        try await buildPrefixCache()
    }

    /// Returns the cleaned text, or the raw transcript if the model output fails validation.
    public func clean(_ raw: String, style: DictationStyle, vocabulary: [String]) async throws -> CleanResult {
        guard container != nil else { throw CleanerError.notLoaded }
        // The actor is reentrant across awaits, so use one set of rules for the whole request.
        let rules = self.rules
        let messages = CleanupPrompt.messages(raw: raw, style: style, vocabulary: vocabulary, rules: rules)
        let maxTokens = CleanupPrompt.wordCount(raw) * 3 + 64
        let (output, stats) = try await generate(messages, maxTokens: maxTokens)
        if let valid = CleanupPrompt.validate(output: output, raw: raw, style: style) {
            if CleanupPrompt.breaksRules(output: valid, raw: raw, rules: rules, vocabulary: vocabulary) {
                return CleanResult(text: CleanupPrompt.basicCleanup(raw), usedLLM: false, rejectedOutput: output, stats: stats)
            }
            // The model occasionally forgets the opening capital; casual and code text may want lowercase.
            var text = valid
            if style == .standard || style == .formal, let first = text.first, first.isLowercase {
                text = first.uppercased() + text.dropFirst()
            }
            return CleanResult(text: text, usedLLM: true, rejectedOutput: nil, stats: stats)
        }
        return CleanResult(text: raw, usedLLM: false, rejectedOutput: output, stats: stats)
    }

    /// After a couple of idle minutes the first cleanup is 3–6× slower (cold GPU, weights paged
    /// out). Call this when recording starts: one cheap token through the cached path, done while
    /// the user is still talking. Skipped if a warm-up is already running.
    public func warmUp() async {
        guard container != nil, !warming else { return }
        warming = true
        defer { warming = false }
        _ = try? await generate(CleanupPrompt.messages(raw: "ok", style: .standard, vocabulary: [], rules: rules),
                                maxTokens: 1)
    }
    private var warming = false

    // MARK: - Prompt prefix cache

    private func tokens(for messages: [CleanupPrompt.Message]) async throws -> [Int] {
        guard let container else { throw CleanerError.notLoaded }
        let input = try await container.prepare(input: UserInput(chat: messages.map(\.chat)))
        return input.text.tokens.asArray(Int32.self).map(Int.init)
    }

    /// Finds the token prefix shared by every request (system prompt + examples + the start of the
    /// final user turn) by tokenizing two different requests, then prefills it into a KV cache.
    private func buildPrefixCache() async throws {
        guard let container else { return }
        // Two rebuilds can interleave at the awaits below when rules change twice in quick
        // succession; only the one for the current rules may store its cache.
        let rules = self.rules
        let a = try await tokens(for: CleanupPrompt.messages(raw: "alpha", style: .standard, vocabulary: [], rules: rules))
        let b = try await tokens(for: CleanupPrompt.messages(raw: "zulu yankee", style: .code, vocabulary: ["Xylo"], rules: rules))
        var common = 0
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        // Back off a couple of tokens so BPE merges at the boundary can't differ between requests.
        let length = common - 2
        guard length > 16 else { return }
        let prefix = Array(a[..<length])

        let cache: [KVCache] = try await container.perform { context in
            let cache = context.model.newCache(parameters: nil)
            let input = LMInput(tokens: MLXArray(prefix))
            // Creating the iterator runs the prefill, which writes the prefix into `cache`.
            _ = try TokenIterator(input: input, model: context.model, cache: cache,
                                  parameters: GenerateParameters(maxTokens: 1, temperature: 0))
            eval(cache.flatMap(\.state))
            return cache
        }
        guard rules == self.rules else { return }
        prefixTokens = prefix
        prefixCache = cache
    }

    // MARK: - Generation

    private func generate(_ messages: [CleanupPrompt.Message], maxTokens: Int) async throws -> (String, Stats) {
        guard let container else { throw CleanerError.notLoaded }
        let all = try await tokens(for: messages)
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)

        // Reuse the cached prefix when this request starts with it; otherwise prefill everything.
        let canReuse = usePromptCache && prefixCache != nil
            && all.count > prefixTokens.count && all.starts(with: prefixTokens)
        let cache: [KVCache]? = canReuse ? prefixCache?.map { $0.copy() } : nil
        let feed = canReuse ? Array(all[prefixTokens.count...]) : all
        let input = LMInput(tokens: MLXArray(feed))

        let text: String = try await container.perform { context in
            var text = ""
            for await event in try MLXLMCommon.generate(input: input, cache: cache, parameters: params, context: context) {
                if case .chunk(let s) = event { text += s }
            }
            return text
        }
        return (text, Stats(usedPrefixCache: canReuse, promptTokens: feed.count))
    }

    public struct CleanResult: Sendable {
        public let text: String
        public let usedLLM: Bool
        /// The model output that failed validation, for debugging.
        public let rejectedOutput: String?
        public let stats: Stats?
    }

    /// What one cleanup cost, for the log: whether the cached prompt prefix was reused, and how many
    /// prompt tokens still had to be processed.
    public struct Stats: Sendable {
        public let usedPrefixCache: Bool
        public let promptTokens: Int
    }

    public enum CleanerError: LocalizedError {
        case notLoaded
        public var errorDescription: String? { "Language model is not loaded yet." }
    }
}

private extension CleanupPrompt.Message {
    var chat: Chat.Message {
        switch role {
        case .system: return .system(content)
        case .user: return .user(content)
        case .assistant: return .assistant(content)
        }
    }
}
