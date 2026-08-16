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
        reviewMode: HarnessReviewMode = Self.defaultReviewMode,
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
        self.reviewMode = reviewMode
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
        case reviewMode
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
        // `try?` covers both a thread stored before review modes existed and a
        // value this build no longer recognises: neither may fail the load.
        reviewMode = (try? container.decodeIfPresent(HarnessReviewMode.self, forKey: .reviewMode))
            ?? Self.defaultReviewMode
        lastConversationAt = try container.decode(Date.self, forKey: .lastConversationAt)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt)
        status = try container.decode(HarnessThreadStatus.self, forKey: .status)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
    }
}

public struct PersistedState: Codable, Equatable, Sendable {
    public var threads: [HarnessThread]
    public var selectedThreadID: UUID?
    public var defaultModel: String
    public var defaultReasoningEffort: String

    public init(
        threads: [HarnessThread] = [],
        selectedThreadID: UUID? = nil,
        defaultModel: String = HarnessThread.defaultModel,
        defaultReasoningEffort: String = HarnessThread.defaultReasoningEffort
    ) {
        self.threads = threads
        self.selectedThreadID = selectedThreadID
        self.defaultModel = defaultModel
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case threads
        case selectedThreadID
        case defaultModel
        case defaultReasoningEffort
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
