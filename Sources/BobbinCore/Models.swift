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

public enum ToolCallKind: String, Codable, Sendable {
    case command
    case fileChange
    case mcpTool
    case webSearch
    case other
}

public enum ToolCallStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case stopped
}

public struct ToolCall: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let itemID: String
    public let kind: ToolCallKind
    public let label: String
    public var status: ToolCallStatus
    public var exitCode: Int?
    public var durationMs: Int?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        itemID: String,
        kind: ToolCallKind,
        label: String,
        status: ToolCallStatus,
        exitCode: Int? = nil,
        durationMs: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.label = label
        self.status = status
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.createdAt = createdAt
    }
}

public enum HarnessTranscriptEntry: Identifiable, Equatable, Sendable {
    case message(ChatMessage)
    case toolCall(ToolCall)

    public var id: String {
        switch self {
        case .message(let message): "message:\(message.id.uuidString)"
        case .toolCall(let toolCall): "toolCall:\(toolCall.id.uuidString)"
        }
    }

    public var createdAt: Date {
        switch self {
        case .message(let message): message.createdAt
        case .toolCall(let toolCall): toolCall.createdAt
        }
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

/// How a thread handles approval escalations and how far the sandbox reaches.
///
/// The three cases are the only user-facing choices; each one maps to a fixed
/// combination of app-server `approvalPolicy`, `approvalsReviewer`, and
/// `sandbox`, so the user never has to reason about the wire protocol.
public enum HarnessReviewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Escalations are requested, then judged by the app-server review subagent.
    case autoReview
    /// Nothing is ever asked and nothing is fenced off.
    case allowAll
    /// Nothing is ever asked, so nothing can escape the workspace sandbox.
    case denyAll

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoReview: "Auto review"
        case .allowAll: "Allow all"
        case .denyAll: "Deny all"
        }
    }

    /// One short line that makes the choice understandable without a manual.
    public var summary: String {
        switch self {
        case .autoReview: "Escalations judged automatically"
        case .allowAll: "Never asks, sandbox off"
        case .denyAll: "Escalations always denied"
        }
    }

    /// app-server `AskForApproval`.
    public var approvalPolicy: String {
        switch self {
        case .autoReview: "on-request"
        case .allowAll, .denyAll: "never"
        }
    }

    /// app-server `ApprovalsReviewer`. Only `.autoReview` delegates to the
    /// review subagent; the other two pin the protocol default back to `user`
    /// so switching away from auto review takes effect on the next turn.
    public var approvalsReviewer: String {
        switch self {
        case .autoReview: "auto_review"
        case .allowAll, .denyAll: "user"
        }
    }

    /// app-server `SandboxMode`.
    public var sandboxMode: String {
        switch self {
        case .autoReview, .denyAll: "workspace-write"
        case .allowAll: "danger-full-access"
        }
    }
}

public struct HarnessModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let supportedReasoningEfforts: [String]

    public init(id: String, displayName: String, supportedReasoningEfforts: [String]) {
        self.id = id
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }
}

public struct HarnessThread: Codable, Identifiable, Equatable, Sendable {
    public static let defaultModel = "gpt-5.6-luna"
    public static let defaultReasoningEffort = "xhigh"
    public static let defaultReviewMode = HarnessReviewMode.autoReview
    public static let defaultSystemPrompt = """
    You are answering inside Bobbin, a macOS menu bar popover roughly 390 points wide.

    - Lead with the answer. Add context afterwards, and only when it changes what to do.
    - Keep replies short enough to read without scrolling — usually a few sentences.
    - Avoid wide tables and long code blocks; they wrap badly at this width. Show only the lines that changed.
    - Reply in the language the user writes in.

    Brevity applies to the reply, not to the work. Take as long as you need on tools, files and reasoning.
    """

    /// Working directory for a new thread when the caller does not supply one.
    /// Deliberately computed from the current user's home each time rather than
    /// persisted, so no stale default can survive in the state file.
    public static var defaultWorkingDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    public let id: UUID
    public var codexThreadID: String?
    public var activeTurnID: String?
    public var title: String
    public var workingDirectory: String
    public var model: String
    public var reasoningEffort: String
    public var reviewMode: HarnessReviewMode
    public var systemPrompt: String
    public var lastConversationAt: Date
    public var savedAt: Date?
    public var status: HarnessThreadStatus
    public var messages: [ChatMessage]
    public var toolCalls: [ToolCall]

    public init(
        id: UUID = UUID(),
        codexThreadID: String? = nil,
        activeTurnID: String? = nil,
        title: String = "New thread",
        workingDirectory: String,
        model: String = Self.defaultModel,
        reasoningEffort: String = Self.defaultReasoningEffort,
        reviewMode: HarnessReviewMode = Self.defaultReviewMode,
        systemPrompt: String = Self.defaultSystemPrompt,
        lastConversationAt: Date = Date(),
        savedAt: Date? = nil,
        status: HarnessThreadStatus = .idle,
        messages: [ChatMessage] = [],
        toolCalls: [ToolCall] = []
    ) {
        self.id = id
        self.codexThreadID = codexThreadID
        self.activeTurnID = activeTurnID
        self.title = title
        self.workingDirectory = workingDirectory
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.reviewMode = reviewMode
        self.systemPrompt = systemPrompt
        self.lastConversationAt = lastConversationAt
        self.savedAt = savedAt
        self.status = status
        self.messages = messages
        self.toolCalls = toolCalls
    }

    public var isSaved: Bool { savedAt != nil }

    /// The render-time transcript order. Stored messages and tool calls remain
    /// separate so existing persistence and message handling stay unchanged.
    /// The source-array index makes equal timestamps deterministic and stable.
    public var transcriptEntries: [HarnessTranscriptEntry] {
        let entries = messages.enumerated().map { index, message in
            (index: index, date: message.createdAt, entry: HarnessTranscriptEntry.message(message))
        } + toolCalls.enumerated().map { index, toolCall in
            (
                index: messages.count + index,
                date: toolCall.createdAt,
                entry: HarnessTranscriptEntry.toolCall(toolCall)
            )
        }

        return entries
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.index < $1.index
            }
            .map(\.entry)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case codexThreadID
        case activeTurnID
        case title
        case workingDirectory
        case model
        case reasoningEffort
        case reviewMode
        case systemPrompt
        case lastConversationAt
        case savedAt
        case status
        case messages
        case toolCalls
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
        // `try?` covers both a thread stored before review modes existed and a
        // value this build no longer recognises: neither may fail the load.
        reviewMode = (try? container.decodeIfPresent(HarnessReviewMode.self, forKey: .reviewMode))
            ?? Self.defaultReviewMode
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? Self.defaultSystemPrompt
        lastConversationAt = try container.decode(Date.self, forKey: .lastConversationAt)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt)
        status = try container.decode(HarnessThreadStatus.self, forKey: .status)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
    }
}

public struct PersistedState: Codable, Equatable, Sendable {
    public var threads: [HarnessThread]
    public var selectedThreadID: UUID?
    public var defaultModel: String
    public var defaultReasoningEffort: String
    public var defaultSystemPrompt: String

    public init(
        threads: [HarnessThread] = [],
        selectedThreadID: UUID? = nil,
        defaultModel: String = HarnessThread.defaultModel,
        defaultReasoningEffort: String = HarnessThread.defaultReasoningEffort,
        defaultSystemPrompt: String = HarnessThread.defaultSystemPrompt
    ) {
        self.threads = threads
        self.selectedThreadID = selectedThreadID
        self.defaultModel = defaultModel
        self.defaultReasoningEffort = defaultReasoningEffort
        self.defaultSystemPrompt = defaultSystemPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case threads
        case selectedThreadID
        case defaultModel
        case defaultReasoningEffort
        case defaultSystemPrompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threads = try container.decode([HarnessThread].self, forKey: .threads)
        selectedThreadID = try container.decodeIfPresent(UUID.self, forKey: .selectedThreadID)
        // A legacy `lastWorkingDirectory` key is ignored on decode and dropped
        // on the next write: new threads always start from the home directory.
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
            ?? HarnessThread.defaultModel
        defaultReasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .defaultReasoningEffort
        ) ?? HarnessThread.defaultReasoningEffort
        defaultSystemPrompt = try container.decodeIfPresent(
            String.self,
            forKey: .defaultSystemPrompt
        ) ?? HarnessThread.defaultSystemPrompt
    }
}

public enum AuthenticationMode: String, Codable, Sendable {
    case deviceAuth = "Device auth"
    case apiKey = "API key"
}

/// What the main surface should say about the app-server, if anything.
///
/// A healthy server is deliberately `none`: a permanent "everything is fine"
/// indicator is noise, so state is surfaced only when it is actionable.
public enum ServerNotice: Equatable, Sendable {
    case none
    case restarting
    case stopped(detail: String)

    public var isSilent: Bool { self == .none }
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
            "Codex CLI not found. Check ~/.local/bin/codex or your PATH."
        case .appServerStopped(let detail):
            detail.isEmpty ? "Codex app-server stopped." : "Codex app-server stopped: \(detail)"
        case .malformedResponse(let detail):
            "Malformed response from the app-server: \(detail)"
        case .serverError(_, let message):
            message
        case .missingResult(let method):
            "No result for \(method)."
        case .modelUnavailable(let model):
            "\(model) / xhigh is unavailable in this Codex environment."
        case .apiKeyUnavailable:
            "Could not read the detected API key."
        case .threadNotFound:
            "That thread no longer exists."
        }
    }
}
