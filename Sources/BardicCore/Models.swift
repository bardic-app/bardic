import Foundation

/// Speech-to-text model choices (WhisperKit Core ML variants from `argmaxinc/whisperkit-coreml`).
public enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case smallEnglish = "openai_whisper-small.en_217MB"
    case baseEnglish = "openai_whisper-base.en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .largeV3Turbo: return "Whisper Large v3 Turbo (best, ~630 MB)"
        case .smallEnglish: return "Whisper Small, English (faster, ~220 MB)"
        case .baseEnglish: return "Whisper Base, English (fastest, ~150 MB)"
        }
    }

    /// Approximate download size, for the free-space check.
    public var approxBytes: Int64 {
        switch self {
        case .largeV3Turbo: return 630_000_000
        case .smallEnglish: return 220_000_000
        case .baseEnglish: return 150_000_000
        }
    }
}

/// Local LLM choices for the cleanup pass (MLX 4-bit models from `mlx-community`).
public enum CleanupModel: String, CaseIterable, Identifiable, Sendable {
    case qwen3_4B = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case qwen25_1_5B = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    case llama32_3B = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    case qwen25_7B = "mlx-community/Qwen2.5-7B-Instruct-4bit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3_4B: return "Qwen3 4B (recommended, ~2.3 GB)"
        case .qwen25_1_5B: return "Qwen 2.5 1.5B (fastest, ~0.9 GB)"
        case .llama32_3B: return "Llama 3.2 3B (~1.8 GB)"
        case .qwen25_7B: return "Qwen 2.5 7B (best quality, ~4.3 GB, slower)"
        }
    }

    /// Hugging Face commit the model is pinned to, so a later upload to the repo can't change what
    /// Bardic downloads or loads (commits are immutable). nil follows the repo's `main` branch.
    public var revision: String? {
        switch self {
        case .qwen3_4B: return "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
        case .qwen25_1_5B: return "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"
        case .llama32_3B: return "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
        case .qwen25_7B: return "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed"
        }
    }

    /// Approximate download size, for the free-space check.
    public var approxBytes: Int64 {
        switch self {
        case .qwen3_4B: return 2_300_000_000
        case .llama32_3B: return 1_800_000_000
        case .qwen25_1_5B: return 900_000_000
        case .qwen25_7B: return 4_300_000_000
        }
    }
}

/// True for errors caused by the network (offline, timeouts, DNS…), including ones wrapped by a library.
/// Those say nothing about whether the files on disk are damaged.
public func isNetworkError(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    while let e = current {
        if e.domain == NSURLErrorDomain { return true }
        current = e.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

public enum Paths {
    /// ~/Library/Application Support/Bardic
    public static let appSupport: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Bardic", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static var speechModels: URL {
        let dir = appSupport.appendingPathComponent("SpeechModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where mlx-swift-lm's Hugging Face client keeps a cleanup model: ~/Library/Caches/models/<repo id>.
    public static func cleanupModel(_ model: CleanupModel) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/\(model.rawValue)", isDirectory: true)
    }

    /// Free space on the home volume that macOS will make available for important downloads.
    public static var freeDiskBytes: Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
