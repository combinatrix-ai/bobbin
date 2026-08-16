import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public var text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public enum HarnessThreadStatus: String, Codable, Sendable {
    case idle
    case running
    case done
    case stopped
    case failed

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .done: "Done"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }
}

public struct HarnessThread: Codable, Identifiable, Equatable, Sendable {
    public static let defaultModel = "gpt-5.6-luna"
    public static let defaultReasoningEffort = "xhigh"

    public let id: UUID
    public var codexThreadID: String?
    public var activeTurnID: String?
    public var title: String
    public var workingDirectory: String
    public var model: String
    public var reasoningEffort: String
    public var lastConversationAt: Date
    public var savedAt: Date?
    public var status: HarnessThreadStatus
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        codexThreadID: String? = nil,
        activeTurnID: String? = nil,
        title: String = "New thread",
        workingDirectory: String,
        model: String = Self.defaultModel,
        reasoningEffort: String = Self.defaultReasoningEffort,
        lastConversationAt: Date = Date(),
        savedAt: Date? = nil,
        status: HarnessThreadStatus = .idle,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.codexThreadID = codexThreadID
        self.activeTurnID = activeTurnID
        self.title = title
        self.workingDirectory = workingDirectory
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.lastConversationAt = lastConversationAt
        self.savedAt = savedAt
        self.status = status
        self.messages = messages
    }

    public var isSaved: Bool { savedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case codexThreadID
        case activeTurnID
        case title
        case workingDirectory
        case model
        case reasoningEffort
        case lastConversationAt
        case savedAt
        case status
        case messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        codexThreadID = try container.decodeIfPresent(String.self, forKey: .codexThreadID)
        activeTurnID = try container.decodeIfPresent(String.self, forKey: .activeTurnID)
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
            ?? Self.defaultReasoningEffort
        lastConversationAt = try container.decode(Date.self, forKey: .lastConversationAt)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt)
        status = try container.decode(HarnessThreadStatus.self, forKey: .status)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
    }
}

public struct PersistedState: Codable, Equatable, Sendable {
    public var threads: [HarnessThread]
    public var selectedThreadID: UUID?
    public var lastWorkingDirectory: String?

    public init(
        threads: [HarnessThread] = [],
        selectedThreadID: UUID? = nil,
        lastWorkingDirectory: String? = nil
    ) {
        self.threads = threads
        self.selectedThreadID = selectedThreadID
        self.lastWorkingDirectory = lastWorkingDirectory
    }
}

public enum AuthenticationMode: String, Codable, Sendable {
    case deviceAuth = "Device auth"
    case apiKey = "API key"
}

public enum HarnessError: LocalizedError, Equatable {
    case codexNotFound
    case appServerStopped(String)
    case malformedResponse(String)
    case serverError(code: Int, message: String)
    case missingResult(String)
    case modelUnavailable(String)
    case apiKeyUnavailable
    case threadNotFound

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            "Codex CLIが見つかりません。~/.local/bin/codex またはPATHを確認してください。"
        case .appServerStopped(let detail):
            detail.isEmpty ? "Codex app-serverが停止しました。" : "Codex app-serverが停止しました: \(detail)"
        case .malformedResponse(let detail):
            "app-serverから不正な応答を受け取りました: \(detail)"
        case .serverError(_, let message):
            message
        case .missingResult(let method):
            "\(method) の結果がありません。"
        case .modelUnavailable(let model):
            "\(model) / xhigh はこのCodex環境で利用できません。"
        case .apiKeyUnavailable:
            "検出したAPI keyを読み出せませんでした。"
        case .threadNotFound:
            "対象のスレッドが見つかりません。"
        }
    }
}
