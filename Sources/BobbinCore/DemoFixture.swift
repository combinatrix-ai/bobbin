import Foundation

/// A tool call plus the output that the live app normally keeps only in
/// memory. The output deliberately lives beside the persisted model rather
/// than on `ToolCall`, so state.json remains the app's one stable format.
public struct DemoToolCall: Sendable {
    public let toolCall: ToolCall
    public let output: String?

    public init(toolCall: ToolCall, output: String? = nil) {
        self.toolCall = toolCall
        self.output = output
    }
}

public enum DemoDataError: LocalizedError, Equatable, Sendable {
    case missingPath
    case fileNotFound(String)
    case unreadable(String, String)
    case decodeFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingPath:
            "No demo data file was supplied."
        case .fileNotFound(let path):
            "Demo data file not found: \(path)"
        case .unreadable(let path, let detail):
            "Could not read demo data at \(path): \(detail)"
        case .decodeFailed(let path, let detail):
            "Could not decode demo data at \(path): \(detail)"
        }
    }
}

/// State and memory-only output for one demo session.
public struct DemoFixture: Sendable {
    public let state: PersistedState
    public let toolCalls: [DemoToolCall]

    public init(state: PersistedState, toolCalls: [DemoToolCall] = []) {
        self.state = state
        self.toolCalls = toolCalls
    }

    /// Output is indexed the same way `HarnessController` indexes live tool
    /// output, while the optional field remains absent from persisted JSON.
    public var toolOutputs: [String: String] {
        Dictionary(
            uniqueKeysWithValues: toolCalls.compactMap { seed in
                guard let output = seed.output, !output.isEmpty else { return nil }
                return (seed.toolCall.itemID, output)
            }
        )
    }

    /// The catalog is local and deterministic in demo mode. Unknown models in
    /// a supplied state are added with the efforts found in that state so an
    /// arbitrary state file still renders its controls instead of failing
    /// model verification.
    public var modelOptions: [HarnessModelOption] {
        var options = Self.modelCatalogue
        let knownEfforts = Set(["low", "medium", "high", "xhigh", "max"])
        let usedModels = [state.defaultModel] + state.threads.map(\.model)

        for model in usedModels where !options.contains(where: { $0.id == model }) {
            let efforts = state.threads
                .filter { $0.model == model }
                .map(\.reasoningEffort)
                .filter { knownEfforts.contains($0) }
            let uniqueEfforts = efforts.reduce(into: [String]()) { result, effort in
                if !result.contains(effort) { result.append(effort) }
            }
            options.append(
                HarnessModelOption(
                    id: model,
                    displayName: model,
                    supportedReasoningEfforts: uniqueEfforts.isEmpty ? ["high", "xhigh"] : uniqueEfforts
                )
            )
        }
        return options
    }

    /// Encodes with exactly the same date and formatting configuration as
    /// `ThreadStore` before installing the state in the throwaway root.
    public func encodedState() throws -> Data {
        try PersistedStateCoding.encoder().encode(state)
    }

    /// Copies this state into a root before `ThreadStore` opens it. The store
    /// then owns the file and persists future edits just like a normal run.
    public func install(to paths: HarnessPaths) throws {
        try paths.prepare()
        try encodedState().write(to: paths.stateFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.stateFile.path
        )
    }

    /// Loads the app's own state.json format. There is intentionally no demo
    /// wrapper schema and no fallback when this operation fails.
    public static func load(from url: URL) throws -> DemoFixture {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DemoDataError.fileNotFound(url.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DemoDataError.unreadable(url.path, error.localizedDescription)
        }

        do {
            let state = try PersistedStateCoding.decoder().decode(PersistedState.self, from: data)
            return DemoFixture(state: state)
        } catch {
            throw DemoDataError.decodeFailed(url.path, error.localizedDescription)
        }
    }

    /// Deterministic product-looking content for screenshots. Dates are
    /// relative to the supplied anchor so the age fade remains useful whether
    /// the fixture is captured today or in a later build.
    public static func builtIn(now: Date = Date()) -> DemoFixture {
        let systemPrompt = """
        You are Bobbin's concise editorial partner.

        Keep replies calm, specific, and easy to scan in a narrow menu-bar popover. When a tool is useful, explain the result in one sentence before moving on.
        """

        let showcaseID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
        let userMessage = ChatMessage(
            id: UUID(uuidString: "A0000000-0000-4000-8000-000000000101")!,
            role: .user,
            text: "Can you tighten the launch story and show me what changed?",
            createdAt: now.addingTimeInterval(-3_300)
        )
        let assistantMessage = ChatMessage(
            id: UUID(uuidString: "A0000000-0000-4000-8000-000000000102")!,
            role: .assistant,
            text: "The story now opens with the user outcome, then makes the quiet automation visible. I left the final review running so we can inspect its progress.",
            createdAt: now.addingTimeInterval(-2_920)
        )

        let command = DemoToolCall(
            toolCall: ToolCall(
                id: UUID(uuidString: "A0000000-0000-4000-8000-000000000201")!,
                itemID: "demo-command",
                kind: .command,
                label: "swift test --filter LaunchNarrativeTests",
                status: .succeeded,
                durationMs: 1_840,
                createdAt: now.addingTimeInterval(-3_220)
            ),
            output: "Build complete.\nTests: 18 passed\nElapsed: 1.84s"
        )
        let fileChange = DemoToolCall(
            toolCall: ToolCall(
                id: UUID(uuidString: "A0000000-0000-4000-8000-000000000202")!,
                itemID: "demo-file-change",
                kind: .fileChange,
                label: "3 files changed",
                status: .failed,
                exitCode: 2,
                durationMs: 620,
                createdAt: now.addingTimeInterval(-3_120)
            ),
            output: "Validation stopped at a missing copy block.\nSee the highlighted draft."
        )
        let mcpTool = DemoToolCall(
            toolCall: ToolCall(
                id: UUID(uuidString: "A0000000-0000-4000-8000-000000000203")!,
                itemID: "demo-mcp-tool",
                kind: .mcpTool,
                label: "notebook / summarize",
                status: .running,
                createdAt: now.addingTimeInterval(-3_020)
            ),
            output: "Waiting for the design pass to finish…"
        )
        let webSearch = DemoToolCall(
            toolCall: ToolCall(
                id: UUID(uuidString: "A0000000-0000-4000-8000-000000000204")!,
                itemID: "demo-web-search",
                kind: .webSearch,
                label: "quiet interfaces for focused work",
                status: .stopped,
                durationMs: 1_120,
                createdAt: now.addingTimeInterval(-2_980)
            ),
            output: "Stopped after the workspace was closed."
        )
        let showcaseTools = [command, fileChange, mcpTool, webSearch]

        let showcase = HarnessThread(
            id: showcaseID,
            codexThreadID: "demo-thread-showcase",
            activeTurnID: "demo-turn-active",
            title: "Tighten the launch story",
            workingDirectory: "/demo/orbit",
            model: "gpt-5.6-luna",
            reasoningEffort: "xhigh",
            reviewMode: .autoReview,
            systemPrompt: systemPrompt,
            lastConversationAt: now.addingTimeInterval(-2_700),
            status: .running,
            messages: [userMessage, assistantMessage],
            toolCalls: showcaseTools.map(\.toolCall)
        )

        let quietEdges = HarnessThread(
            id: UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!,
            codexThreadID: "demo-thread-quiet-edges",
            title: "Map the quiet edges",
            workingDirectory: "/demo/harbor",
            model: "gpt-5.6-terra",
            reasoningEffort: "high",
            reviewMode: .allowAll,
            systemPrompt: systemPrompt,
            lastConversationAt: now.addingTimeInterval(-3 * 60 * 60),
            status: .done,
            messages: [
                ChatMessage(
                    role: .user,
                    text: "Find the moments where the interface should get out of the way.",
                    createdAt: now.addingTimeInterval(-3 * 60 * 60 - 90)
                ),
                ChatMessage(
                    role: .assistant,
                    text: "The strongest moments are the handoff, the quiet completion state, and the return to the thread list.",
                    createdAt: now.addingTimeInterval(-3 * 60 * 60)
                )
            ]
        )

        let onboarding = HarnessThread(
            id: UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!,
            codexThreadID: "demo-thread-onboarding",
            title: "Triage the onboarding flow",
            workingDirectory: "/demo/atlas",
            model: "gpt-5.6-sol",
            reasoningEffort: "max",
            reviewMode: .denyAll,
            systemPrompt: systemPrompt,
            lastConversationAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
            status: .done,
            messages: [
                ChatMessage(
                    role: .user,
                    text: "Turn the first-run notes into three crisp steps.",
                    createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60 - 180)
                ),
                ChatMessage(
                    role: .assistant,
                    text: "Start with the outcome, show one useful example, and make the next action unmistakable.",
                    createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
                )
            ]
        )

        let later = HarnessThread(
            id: UUID(uuidString: "A0000000-0000-4000-8000-000000000004")!,
            codexThreadID: "demo-thread-later",
            title: "A note for later",
            workingDirectory: "/demo/cinder",
            model: "gpt-5.6-luna",
            reasoningEffort: "medium",
            reviewMode: .autoReview,
            systemPrompt: systemPrompt,
            lastConversationAt: now.addingTimeInterval(-5 * 24 * 60 * 60),
            status: .idle,
            messages: [
                ChatMessage(
                    role: .user,
                    text: "Keep the smallest useful version of this idea.",
                    createdAt: now.addingTimeInterval(-5 * 24 * 60 * 60)
                )
            ]
        )

        let saved = HarnessThread(
            id: UUID(uuidString: "A0000000-0000-4000-8000-000000000005")!,
            codexThreadID: "demo-thread-saved",
            title: "Keep: the small details",
            workingDirectory: "/demo/orbit",
            model: "gpt-5.6-terra",
            reasoningEffort: "xhigh",
            reviewMode: .allowAll,
            systemPrompt: systemPrompt,
            lastConversationAt: now.addingTimeInterval(-9 * 24 * 60 * 60),
            savedAt: now.addingTimeInterval(-45 * 60),
            status: .done,
            messages: [
                ChatMessage(
                    role: .user,
                    text: "Save the details that make the experience feel considered.",
                    createdAt: now.addingTimeInterval(-9 * 24 * 60 * 60)
                ),
                ChatMessage(
                    role: .assistant,
                    text: "The useful details are the calm defaults, the honest status language, and the easy way back.",
                    createdAt: now.addingTimeInterval(-9 * 24 * 60 * 60 + 80)
                )
            ]
        )

        return DemoFixture(
            state: PersistedState(
                threads: [showcase, quietEdges, onboarding, later, saved],
                selectedThreadID: showcaseID,
                defaultModel: "gpt-5.6-luna",
                defaultReasoningEffort: "xhigh",
                defaultSystemPrompt: systemPrompt
            ),
            toolCalls: showcaseTools
        )
    }

    public static let modelCatalogue: [HarnessModelOption] = [
        HarnessModelOption(
            id: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            supportedReasoningEfforts: ["medium", "high", "xhigh"]
        ),
        HarnessModelOption(
            id: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]
        ),
        HarnessModelOption(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            supportedReasoningEfforts: ["high", "max"]
        )
    ]
}
