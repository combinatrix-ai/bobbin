import Foundation
import Combine

protocol HarnessAppServerClient: AnyObject {
    var onNotification: CodexAppServerClient.NotificationHandler? { get set }
    var onTermination: CodexAppServerClient.TerminationHandler? { get set }

    func start() async throws
    func stop()
    func request(
        method: String,
        params: CodexAppServerClient.JSONObject?
    ) async throws -> CodexAppServerClient.JSONObject
    func sendNotification(
        method: String,
        params: CodexAppServerClient.JSONObject?
    ) throws
}

extension CodexAppServerClient: HarnessAppServerClient {}

@MainActor
public final class HarnessController: ObservableObject {
    public static let defaultModel = HarnessThread.defaultModel
    public static let defaultEffort = HarnessThread.defaultReasoningEffort
    public static func modelNickname(_ model: String) -> String {
        switch model {
        case "gpt-5.6-luna": "luna"
        case "gpt-5.6-terra": "terra"
        case "gpt-5.6-sol": "sol"
        default: model
        }
    }

    public enum ServerState: Equatable {
        /// First boot, before anything is on screen.
        case starting
        case ready
        /// An explicit restart of an already-running session. Distinct from
        /// `starting` because the thread surface stays up throughout.
        case restarting
        case stopped(String)

        /// What, if anything, the main surface should surface. Healthy is
        /// silent; only actionable states produce a notice.
        public var notice: ServerNotice {
            switch self {
            case .starting, .ready: .none
            case .restarting: .restarting
            case .stopped(let detail): .stopped(detail: detail)
            }
        }

        /// The on-demand reading shown inside Settings, where the user has
        /// asked for it.
        public var settingsLabel: String {
            switch self {
            case .starting: "Starting…"
            case .ready: "Healthy"
            case .restarting: "Restarting…"
            case .stopped: "Stopped"
            }
        }

        public var isHealthy: Bool { self == .ready }
    }

    public enum AuthState: Equatable {
        case checking
        case chooseAPIKey(source: String)
        case deviceCode(verificationURL: String, userCode: String, loginID: String)
        case authenticated(AuthenticationMode)
        case failed(String)

        public var isAuthenticated: Bool {
            if case .authenticated = self { return true }
            return false
        }
    }

    @Published public private(set) var serverState: ServerState = .starting
    @Published public private(set) var authState: AuthState = .checking
    @Published public private(set) var modelVerified = false
    @Published public private(set) var availableModels: [HarnessModelOption] = []
    @Published public private(set) var lastError: String?
    /// Local threads currently undergoing a server fork/start followed by a
    /// replacement turn. The UI uses this to disable duplicate actions.
    @Published public private(set) var rewritingThreadIDs: Set<UUID> = []

    public let store: ThreadStore
    /// Demo controllers are fully populated before the view appears and never
    /// own an app-server client.
    public let isDemoMode: Bool

    private let keyProvider: APIKeyProvider
    private var client: (any HarnessAppServerClient)?
    private var pendingAuthMode: AuthenticationMode?
    private var streamingMessages: [String: UUID] = [:]
    private var toolOutputs: [String: String] = [:]
    private var bootTask: Task<Void, Never>?

    public init(paths: HarnessPaths? = nil, keyProvider: APIKeyProvider = APIKeyProvider()) throws {
        let paths = try paths ?? HarnessPaths()
        self.isDemoMode = false
        self.store = try ThreadStore(paths: paths)
        self.keyProvider = keyProvider

        if store.state.threads.isEmpty {
            _ = try store.createThread(workingDirectory: Self.resolvedWorkingDirectory(nil))
        }
    }

    /// Constructs a populated, authenticated controller without entering the
    /// production boot sequence. The caller installs the fixture first so the
    /// store remains the owner of demo state and future edits.
    public init(
        demoPaths paths: HarnessPaths,
        fixture: DemoFixture?,
        error: String? = nil
    ) throws {
        self.isDemoMode = true
        self.store = try ThreadStore(paths: paths, normalizeInterruptedRuns: false)
        self.keyProvider = APIKeyProvider()

        if let fixture, error == nil {
            self.serverState = .ready
            self.authState = .authenticated(.deviceAuth)
            self.modelVerified = true
            self.availableModels = fixture.modelOptions
            self.toolOutputs = fixture.toolOutputs
        } else {
            let message = error ?? "Could not load demo data."
            self.serverState = .ready
            self.authState = .failed(message)
            self.modelVerified = false
            self.availableModels = DemoFixture.modelCatalogue
            self.lastError = message
            self.toolOutputs = [:]
        }
    }

    /// Test-only construction for exercising the live turn path without
    /// launching a real app-server process.
    init(
        testPaths paths: HarnessPaths,
        appServerClient: any HarnessAppServerClient
    ) throws {
        self.isDemoMode = false
        self.store = try ThreadStore(paths: paths)
        self.keyProvider = APIKeyProvider()
        self.client = appServerClient
        self.serverState = .ready
        self.authState = .authenticated(.deviceAuth)
        self.modelVerified = true
        self.availableModels = DemoFixture.modelCatalogue

        if store.state.threads.isEmpty {
            _ = try store.createThread(workingDirectory: Self.resolvedWorkingDirectory(nil))
        }
    }

    public var selectedThread: HarnessThread? { store.selectedThread }
    public var activeThreads: [HarnessThread] { store.activeThreads }
    public var savedThreads: [HarnessThread] { store.savedThreads }
    /// The list composer is ready for typing in production, but stays
    /// unfocused in demo mode so captures do not include a text caret.
    public var shouldAutofocusNewThread: Bool { !isDemoMode }

    /// The directory shown in the new-thread composer. Production keeps the
    /// user's home as the default, while a demo session borrows a directory
    /// from its fixture so the composer never reveals the real home path.
    public var newThreadWorkingDirectory: String {
        guard isDemoMode else { return HarnessThread.defaultWorkingDirectory }

        let fixtureThread = store.selectedThread
            ?? store.activeThreads.first
            ?? store.savedThreads.first
        if let directory = fixtureThread?.workingDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !directory.isEmpty
        {
            return directory
        }
        return "/demo"
    }

    public func isRewriting(_ localThreadID: UUID) -> Bool {
        rewritingThreadIDs.contains(localThreadID)
    }

    public func toolOutput(for itemID: String) -> String? {
        toolOutputs[itemID]
    }

    public func boot() {
        guard !isDemoMode else { return }
        guard client == nil else { return }
        bootTask?.cancel()
        bootTask = Task { await bootSequence() }
    }

    public func restart() {
        guard !isDemoMode else { return }
        client?.stop()
        client = nil
        serverState = .restarting
        // An authenticated session keeps its auth state so the thread surface
        // stays up behind the quiet restarting notice. Only an unresolved
        // session falls back to the full-pane checking view.
        if !authState.isAuthenticated { authState = .checking }
        modelVerified = false
        availableModels = []
        boot()
    }

    public func chooseDeviceAuth() {
        Task { await beginDeviceAuth() }
    }

    public func useDetectedAPIKey() {
        guard let key = keyProvider.readDetectedKey() else {
            authState = .failed(HarnessError.apiKeyUnavailable.localizedDescription)
            return
        }
        Task { await loginWithAPIKey(key) }
    }

    public func useAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            authState = .failed("Enter an API key.")
            return
        }
        Task { await loginWithAPIKey(trimmed) }
    }

    /// An explicitly supplied directory always wins; otherwise a new thread
    /// starts in the home directory. No previously used directory is consulted.
    public static func resolvedWorkingDirectory(_ requested: String?) -> String {
        guard let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty else {
            return HarnessThread.defaultWorkingDirectory
        }
        return requested
    }

    private func resolvedNewThreadWorkingDirectory(_ requested: String?) -> String {
        guard let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return newThreadWorkingDirectory
        }
        return requested
    }

    public func createThread(workingDirectory: String? = nil) {
        let cwd = resolvedNewThreadWorkingDirectory(workingDirectory)
        do {
            _ = try store.createThread(workingDirectory: cwd)
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    /// Creates the local thread before handing its first turn to the existing
    /// send path. The returned ID lets the caller open the conversation while
    /// the turn is already being started.
    @discardableResult
    public func createThreadAndSend(
        text: String,
        workingDirectory: String? = nil
    ) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let cwd = resolvedNewThreadWorkingDirectory(workingDirectory)
        do {
            let thread = try store.createThread(workingDirectory: cwd)
            objectWillChange.send()
            send(text, in: thread.id)
            return thread.id
        } catch {
            report(error)
            return nil
        }
    }

    public func selectThread(_ id: UUID) {
        do {
            try store.select(id)
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    public func updateWorkingDirectory(_ path: String, for id: UUID) {
        do {
            try store.update(id) { $0.workingDirectory = path }
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    public func updateModel(_ model: String, reasoningEffort: String, for id: UUID) {
        guard reasoningEfforts(for: model).contains(reasoningEffort) else {
            lastError = "That model or reasoning level is unavailable."
            return
        }
        do {
            try store.update(id) { thread in
                thread.model = model
                thread.reasoningEffort = reasoningEffort
            }
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    /// Takes effect on the next turn: the running turn keeps the policy it
    /// started with.
    public func updateReviewMode(_ mode: HarnessReviewMode, for id: UUID) {
        do {
            try store.update(id) { $0.reviewMode = mode }
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    public func updateDefaultModel(_ model: String) {
        guard availableModels.contains(where: { $0.id == model }) else { return }
        let effort = resolvedReasoningEffort(
            for: model,
            keeping: store.state.defaultReasoningEffort
        )
        updateDefaults(model: model, reasoningEffort: effort)
    }

    public func updateDefaultReasoningEffort(_ effort: String) {
        let model = store.state.defaultModel
        guard reasoningEfforts(for: model).contains(effort) else { return }
        updateDefaults(model: model, reasoningEffort: effort)
    }

    public func updateSystemPrompt(_ text: String) {
        do {
            try store.updateSystemPrompt(text)
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    public func reasoningEfforts(for model: String) -> [String] {
        availableModels.first(where: { $0.id == model })?.supportedReasoningEfforts ?? []
    }

    /// Keeps a valid current effort when changing models, otherwise applies
    /// Bobbin's one fallback policy for both defaults and existing threads.
    public func resolvedReasoningEffort(for model: String, keeping current: String) -> String {
        let efforts = reasoningEfforts(for: model)
        if efforts.contains(current) { return current }
        return preferredEffort(in: efforts)
    }

    public func saveThread(_ id: UUID) {
        do {
            try store.saveThread(id)
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    public func send(_ text: String, in localThreadID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard authState.isAuthenticated, serverState == .ready, modelVerified else {
            lastError = "Sign-in and the app-server are not ready yet."
            return
        }
        guard let thread = store.state.threads.first(where: { $0.id == localThreadID }) else {
            report(HarnessError.threadNotFound)
            return
        }
        guard !rewritingThreadIDs.contains(localThreadID) else {
            lastError = "A rewrite is already in progress."
            return
        }
        guard thread.status != .running, thread.activeTurnID == nil else {
            lastError = "Wait for the current response to finish first."
            return
        }

        // Claim the thread before yielding to the async request. Without this
        // synchronous transition, a second send or rewrite can slip in while
        // `thread/start` / `thread/resume` is still awaiting its response.
        do {
            try store.update(localThreadID) { $0.status = .running }
            objectWillChange.send()
        } catch {
            report(error)
            return
        }

        Task {
            do {
                try await sendTurn(trimmed, localThreadID: localThreadID)
            } catch {
                failTurn(error, localThreadID: localThreadID)
            }
        }
    }

    public func stopThread(_ localThreadID: UUID) {
        guard
            let thread = store.state.threads.first(where: { $0.id == localThreadID }),
            let codexThreadID = thread.codexThreadID,
            let turnID = thread.activeTurnID,
            let client
        else { return }

        Task {
            do {
                _ = try await client.request(
                    method: "turn/interrupt",
                    params: ["threadId": codexThreadID, "turnId": turnID]
                )
            } catch {
                report(error)
            }
        }
    }

    public func opacity(for thread: HarnessThread, now: Date = Date()) -> Double {
        store.opacity(for: thread, now: now)
    }

    static func threadStartParameters(for thread: HarnessThread) -> [String: Any] {
        var parameters: [String: Any] = [
            "model": thread.model,
            "cwd": thread.workingDirectory,
            "approvalPolicy": thread.reviewMode.approvalPolicy,
            "approvalsReviewer": thread.reviewMode.approvalsReviewer,
            "sandbox": thread.reviewMode.sandboxMode,
            "serviceName": "bobbin"
        ]
        addSystemPromptParameter(to: &parameters, for: thread)
        return parameters
    }

    /// Every turn after the first resumes the app-server thread, so resume is
    /// where a changed review mode reaches the sandbox: `thread/resume` takes a
    /// `SandboxMode` string, while `turn/start` only accepts the differently
    /// shaped `sandboxPolicy` object.
    static func threadResumeParameters(
        threadID: String,
        thread: HarnessThread
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "approvalPolicy": thread.reviewMode.approvalPolicy,
            "approvalsReviewer": thread.reviewMode.approvalsReviewer,
            "sandbox": thread.reviewMode.sandboxMode
        ]
    }

    private static func addSystemPromptParameter(
        to parameters: inout [String: Any],
        for thread: HarnessThread
    ) {
        guard !thread.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        parameters["developerInstructions"] = thread.systemPrompt
    }

    static func turnStartParameters(
        threadID: String,
        text: String,
        thread: HarnessThread,
        clientUserMessageID: UUID? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": text]],
            "cwd": thread.workingDirectory,
            "approvalPolicy": thread.reviewMode.approvalPolicy,
            "approvalsReviewer": thread.reviewMode.approvalsReviewer,
            "model": thread.model,
            "effort": thread.reasoningEffort
        ]
        if let clientUserMessageID {
            parameters["clientUserMessageId"] = clientUserMessageID.uuidString
        }
        return parameters
    }

    /// Replaces a user turn and every later local turn with a new prompt.
    ///
    /// Codex's stable overwrite path is a fork, rather than the deprecated
    /// `thread/rollback` marker. The app-server operation completes before
    /// Bobbin truncates its persisted transcript, so a failed fork leaves the
    /// visible log untouched.
    @discardableResult
    public func editMessage(
        _ messageID: UUID,
        replacement: String,
        in localThreadID: UUID
    ) -> Bool {
        guard !isDemoMode else { return false }
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else {
            rejectRewrite("Enter a replacement message.")
            return false
        }
        guard let plan = rewritePlan(
            messageID: messageID,
            expectedRole: .user,
            replacement: replacement,
            localThreadID: localThreadID
        ) else { return false }
        return scheduleRewrite(plan)
    }

    /// Regenerates an assistant response from its immediately preceding user
    /// turn, discarding that turn's response and all later turns locally.
    @discardableResult
    public func regenerateResponse(
        _ messageID: UUID,
        in localThreadID: UUID
    ) -> Bool {
        guard !isDemoMode else { return false }
        guard
            let thread = store.state.threads.first(where: { $0.id == localThreadID }),
            let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }),
            thread.messages[messageIndex].role == .assistant,
            let userIndex = thread.messages[..<messageIndex].lastIndex(where: { $0.role == .user })
        else {
            rejectRewrite("That response cannot be regenerated.")
            return false
        }

        let userMessage = thread.messages[userIndex]
        let plan = RewritePlan(
            localThreadID: localThreadID,
            messageIndex: userIndex,
            userOrdinal: thread.messages[..<userIndex].filter { $0.role == .user }.count,
            replacement: userMessage.text,
            targetTurnID: userMessage.turnID,
            targetCreatedAt: userMessage.createdAt,
            executionThread: thread
        )
        guard validateRewrite(plan, thread: thread) else { return false }
        return scheduleRewrite(plan)
    }

    private struct RewritePlan {
        let localThreadID: UUID
        let messageIndex: Int
        let userOrdinal: Int
        let replacement: String
        let targetTurnID: String?
        let targetCreatedAt: Date
        /// Freezes model, cwd, sandbox, and approval policy at the instant the
        /// user commits the rewrite. Header changes made while the network is
        /// pending apply to the following turn, never half of this one.
        let executionThread: HarnessThread
    }

    private struct ServerRewriteResult {
        let replacementThreadID: String
        let removedTurnIDs: Set<String>
    }

    /// The local half of a rewrite is optimistic so notifications for the
    /// replacement thread have somewhere to land while `turn/start` is in
    /// flight. This snapshot makes that optimistic mutation reversible if the
    /// app-server rejects the replacement turn after a successful fork/start.
    private struct LocalRewriteSnapshot {
        let thread: HarnessThread
        let removedMessageIDs: Set<UUID>
        let removedToolCallIDs: Set<UUID>
        let removedStreamingMessages: [String: UUID]
        let removedToolOutputs: [String: String]
    }

    private func rewritePlan(
        messageID: UUID,
        expectedRole: MessageRole,
        replacement: String,
        localThreadID: UUID
    ) -> RewritePlan? {
        guard
            let thread = store.state.threads.first(where: { $0.id == localThreadID }),
            let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }),
            thread.messages[messageIndex].role == expectedRole
        else {
            rejectRewrite("That message cannot be edited.")
            return nil
        }

        let message = thread.messages[messageIndex]
        let plan = RewritePlan(
            localThreadID: localThreadID,
            messageIndex: messageIndex,
            userOrdinal: thread.messages[..<messageIndex].filter { $0.role == .user }.count,
            replacement: replacement,
            targetTurnID: message.turnID,
            targetCreatedAt: message.createdAt,
            executionThread: thread
        )
        guard validateRewrite(plan, thread: thread) else { return nil }
        return plan
    }

    private func validateRewrite(_ plan: RewritePlan, thread: HarnessThread) -> Bool {
        guard !rewritingThreadIDs.contains(plan.localThreadID) else {
            rejectRewrite("A rewrite is already in progress.")
            return false
        }
        guard client != nil, authState.isAuthenticated, serverState == .ready, modelVerified else {
            rejectRewrite("Sign-in and the app-server are not ready yet.")
            return false
        }
        guard thread.codexThreadID != nil else {
            rejectRewrite("This thread is not ready for rewriting.")
            return false
        }
        guard thread.status != .running, thread.activeTurnID == nil else {
            rejectRewrite("Wait for the current response to finish first.")
            return false
        }
        return true
    }

    private func scheduleRewrite(_ plan: RewritePlan) -> Bool {
        guard rewritingThreadIDs.insert(plan.localThreadID).inserted else {
            rejectRewrite("A rewrite is already in progress.")
            return false
        }

        Task { [weak self] in
            guard let self else { return }
            defer { self.rewritingThreadIDs.remove(plan.localThreadID) }
            await self.performRewrite(plan)
        }
        return true
    }

    private func performRewrite(_ plan: RewritePlan) async {
        do {
            guard
                let client,
                let currentThread = store.state.threads.first(where: { $0.id == plan.localThreadID }),
                let oldCodexThreadID = currentThread.codexThreadID,
                oldCodexThreadID == plan.executionThread.codexThreadID
            else { throw HarnessError.threadNotFound }
            let executionThread = plan.executionThread

            // The server fork/start is intentionally complete before this
            // method touches Bobbin's transcript or thread ID.
            let result = try await serverRewrite(
                plan: plan,
                thread: executionThread,
                oldCodexThreadID: oldCodexThreadID,
                client: client
            )
            let snapshot = try localRewriteSnapshot(
                plan,
                removedTurnIDs: result.removedTurnIDs
            )
            try truncateForRewrite(
                plan,
                replacementThreadID: result.replacementThreadID,
                snapshot: snapshot
            )
            objectWillChange.send()
            // Both `thread/start` and `thread/fork` return a loaded, subscribed
            // replacement thread, so resuming it again would add a needless
            // failure point between truncation and the replacement turn.
            do {
                try await sendTurn(
                    plan.replacement,
                    localThreadID: plan.localThreadID,
                    resumeExistingThread: false,
                    requestConfiguration: executionThread
                )
            } catch let turnError {
                // The fork/start succeeded but the replacement turn did not.
                // Restore the exact visible transcript and best-effort discard
                // the unused replacement server thread.
                do {
                    try restoreRewrite(snapshot, localThreadID: plan.localThreadID)
                } catch {
                    report(error)
                }
                _ = try? await client.request(
                    method: "thread/delete",
                    params: ["threadId": result.replacementThreadID]
                )
                throw turnError
            }
        } catch {
            report(error)
        }
    }

    private func serverRewrite(
        plan: RewritePlan,
        thread: HarnessThread,
        oldCodexThreadID: String,
        client: any HarnessAppServerClient
    ) async throws -> ServerRewriteResult {
        if plan.userOrdinal == 0 {
            let response = try await client.request(
                method: "thread/start",
                params: Self.threadStartParameters(for: thread)
            )
            return ServerRewriteResult(
                replacementThreadID: try Self.threadID(from: response, method: "thread/start"),
                removedTurnIDs: Set(
                    thread.messages[plan.messageIndex...].compactMap(\.turnID)
                        + thread.toolCalls.compactMap(\.turnID)
                )
            )
        }

        let readResponse = try await client.request(
            method: "thread/read",
            params: ["threadId": oldCodexThreadID, "includeTurns": true]
        )
        let serverTurnIDs = try Self.turnIDs(from: readResponse)
        let localUserCount = thread.messages.filter { $0.role == .user }.count
        guard serverTurnIDs.count == localUserCount,
              plan.userOrdinal < serverTurnIDs.count
        else {
            throw HarnessError.malformedResponse("thread/read.turns")
        }
        if let targetTurnID = plan.targetTurnID,
           targetTurnID != serverTurnIDs[plan.userOrdinal] {
            throw HarnessError.malformedResponse("thread/read.turns")
        }

        let priorTurnID = serverTurnIDs[plan.userOrdinal - 1]
        var forkParameters = Self.threadResumeParameters(
            threadID: oldCodexThreadID,
            thread: thread
        )
        forkParameters["lastTurnId"] = priorTurnID
        let forkResponse = try await client.request(
            method: "thread/fork",
            params: forkParameters
        )
        return ServerRewriteResult(
            replacementThreadID: try Self.threadID(from: forkResponse, method: "thread/fork"),
            removedTurnIDs: Set(serverTurnIDs[plan.userOrdinal...])
        )
    }

    private func localRewriteSnapshot(
        _ plan: RewritePlan,
        removedTurnIDs: Set<String>
    ) throws -> LocalRewriteSnapshot {
        guard let thread = store.state.threads.first(where: { $0.id == plan.localThreadID }) else {
            throw HarnessError.threadNotFound
        }

        let removedMessages = Array(thread.messages.dropFirst(plan.messageIndex))
        let removedMessageIDs = Set(removedMessages.map(\.id))
        let removedToolCalls = thread.toolCalls.filter { toolCall in
            if let turnID = toolCall.turnID {
                return removedTurnIDs.contains(turnID)
            }
            // Messages/calls written before turn ownership was persisted do
            // not have a reliable boundary other than their event timestamp.
            return toolCall.createdAt >= plan.targetCreatedAt
        }
        let removedToolCallIDs = Set(removedToolCalls.map(\.id))
        let removedToolItemIDs = Set(removedToolCalls.map(\.itemID))

        return LocalRewriteSnapshot(
            thread: thread,
            removedMessageIDs: removedMessageIDs,
            removedToolCallIDs: removedToolCallIDs,
            removedStreamingMessages: streamingMessages.filter {
                removedMessageIDs.contains($0.value)
            },
            removedToolOutputs: toolOutputs.filter {
                removedToolItemIDs.contains($0.key)
            }
        )
    }

    private func truncateForRewrite(
        _ plan: RewritePlan,
        replacementThreadID: String,
        snapshot: LocalRewriteSnapshot
    ) throws {
        let removedToolItemIDs = Set(
            snapshot.thread.toolCalls
                .filter { snapshot.removedToolCallIDs.contains($0.id) }
                .map(\.itemID)
        )

        try store.update(plan.localThreadID) { current in
            current.messages.removeSubrange(plan.messageIndex..<current.messages.count)
            current.toolCalls.removeAll { snapshot.removedToolCallIDs.contains($0.id) }
            current.codexThreadID = replacementThreadID
            current.activeTurnID = nil
            current.status = .idle
        }

        streamingMessages = streamingMessages.filter {
            !snapshot.removedMessageIDs.contains($0.value)
        }
        for itemID in removedToolItemIDs {
            toolOutputs.removeValue(forKey: itemID)
        }
    }

    private func restoreRewrite(
        _ snapshot: LocalRewriteSnapshot,
        localThreadID: UUID
    ) throws {
        guard let current = store.state.threads.first(where: { $0.id == localThreadID }) else {
            throw HarnessError.threadNotFound
        }

        let originalMessageIDs = Set(snapshot.thread.messages.map(\.id))
        let failedMessageIDs = Set(current.messages.map(\.id)).subtracting(originalMessageIDs)
        let originalToolCallIDs = Set(snapshot.thread.toolCalls.map(\.id))
        let failedToolItemIDs = Set(
            current.toolCalls
                .filter { !originalToolCallIDs.contains($0.id) }
                .map(\.itemID)
        )

        var persistenceError: Error?
        do {
            try store.update(localThreadID) { thread in
                // Preserve settings and save-state changes made while the network
                // request was pending; only the conversational fields roll back.
                thread.codexThreadID = snapshot.thread.codexThreadID
                thread.activeTurnID = snapshot.thread.activeTurnID
                thread.title = snapshot.thread.title
                thread.lastConversationAt = snapshot.thread.lastConversationAt
                thread.status = snapshot.thread.status
                thread.messages = snapshot.thread.messages
                thread.toolCalls = snapshot.thread.toolCalls
            }
        } catch {
            // `ThreadStore.update` mutates memory before persistence, so finish
            // restoring controller-only state even if the disk write failed.
            persistenceError = error
        }

        streamingMessages = streamingMessages.filter {
            !failedMessageIDs.contains($0.value)
        }
        for (key, value) in snapshot.removedStreamingMessages {
            streamingMessages[key] = value
        }
        for itemID in failedToolItemIDs {
            toolOutputs.removeValue(forKey: itemID)
        }
        for (itemID, output) in snapshot.removedToolOutputs {
            toolOutputs[itemID] = output
        }
        objectWillChange.send()
        if let persistenceError { throw persistenceError }
    }

    private static func threadID(
        from response: CodexAppServerClient.JSONObject,
        method: String
    ) throws -> String {
        guard
            let thread = response["thread"] as? [String: Any],
            let id = thread["id"] as? String,
            !id.isEmpty
        else {
            throw HarnessError.malformedResponse("\(method).thread.id")
        }
        return id
    }

    private static func turnIDs(
        from response: CodexAppServerClient.JSONObject
    ) throws -> [String] {
        guard
            let thread = response["thread"] as? [String: Any],
            let rawTurns = thread["turns"] as? [Any]
        else {
            throw HarnessError.malformedResponse("thread/read.turns")
        }

        let ids = rawTurns.compactMap { ($0 as? [String: Any])?["id"] as? String }
        guard ids.count == rawTurns.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw HarnessError.malformedResponse("thread/read.turns")
        }
        return ids
    }

    private func rejectRewrite(_ message: String) {
        lastError = message
    }

    private func bootSequence() async {
        do {
            let client = try CodexAppServerClient(codexHome: store.paths.codexHome)
            client.onNotification = { [weak self] message in self?.handleNotification(message) }
            client.onTermination = { [weak self] error in
                guard let self else { return }
                self.serverState = .stopped(error.localizedDescription)
                self.lastError = error.localizedDescription
            }
            self.client = client
            try await client.start()
            serverState = .ready

            try await loadModelCatalog(using: client)
            await cleanupExpiredThreads(using: client)
            try await resolveAuthentication(using: client)
        } catch {
            serverState = .stopped(error.localizedDescription)
            authState = .failed(error.localizedDescription)
            report(error)
        }
    }

    private func loadModelCatalog(using client: CodexAppServerClient) async throws {
        let response = try await client.request(
            method: "model/list",
            params: ["limit": 100, "includeHidden": true]
        )
        guard let models = response["data"] as? [[String: Any]] else {
            throw HarnessError.malformedResponse("model/list.data")
        }
        let catalog = Self.modelOptions(from: models)
        guard !catalog.isEmpty else { throw HarnessError.malformedResponse("model/list.data") }
        availableModels = catalog

        let storedModel = store.state.defaultModel
        let selected = catalog.first(where: { $0.id == storedModel })
            ?? catalog.first(where: { $0.id == Self.defaultModel })
            ?? catalog[0]
        let storedEffort = store.state.defaultReasoningEffort
        let selectedEffort = selected.supportedReasoningEfforts.contains(storedEffort)
            ? storedEffort
            : preferredEffort(in: selected.supportedReasoningEfforts)
        if selected.id != storedModel || selectedEffort != storedEffort {
            try store.updateDefaults(model: selected.id, reasoningEffort: selectedEffort)
        }
        modelVerified = true
    }

    static func modelOptions(from values: [[String: Any]]) -> [HarnessModelOption] {
        values.compactMap(Self.modelOption(from:))
    }

    private static func modelOption(from value: [String: Any]) -> HarnessModelOption? {
        guard let id = (value["id"] as? String) ?? (value["model"] as? String) else { return nil }
        let objects = value["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        var efforts = objects.compactMap { $0["reasoningEffort"] as? String }
        if efforts.isEmpty {
            efforts = value["supportedReasoningEfforts"] as? [String] ?? []
        }
        guard !efforts.isEmpty else { return nil }
        let displayName = (value["displayName"] as? String) ?? id
        let uniqueEfforts = efforts.reduce(into: [String]()) { result, effort in
            if !result.contains(effort) { result.append(effort) }
        }
        return HarnessModelOption(
            id: id,
            displayName: displayName,
            supportedReasoningEfforts: uniqueEfforts
        )
    }

    private func preferredEffort(in efforts: [String]) -> String {
        if efforts.contains(Self.defaultEffort) { return Self.defaultEffort }
        return efforts.first ?? Self.defaultEffort
    }

    private func updateDefaults(model: String, reasoningEffort: String) {
        do {
            try store.updateDefaults(model: model, reasoningEffort: reasoningEffort)
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    private func resolveAuthentication(using client: CodexAppServerClient) async throws {
        let response = try await client.request(
            method: "account/read",
            params: ["refreshToken": false]
        )
        if let account = response["account"] as? [String: Any], let type = account["type"] as? String {
            authState = .authenticated(type == "apiKey" ? .apiKey : .deviceAuth)
            return
        }

        if let source = keyProvider.detectedSource() {
            authState = .chooseAPIKey(source: source.rawValue)
        } else {
            await beginDeviceAuth()
        }
    }

    private func beginDeviceAuth() async {
        guard let client else { return }
        authState = .checking
        pendingAuthMode = .deviceAuth
        do {
            let response = try await client.request(
                method: "account/login/start",
                params: ["type": "chatgptDeviceCode"]
            )
            guard
                let loginID = response["loginId"] as? String,
                let verificationURL = response["verificationUrl"] as? String,
                let userCode = response["userCode"] as? String
            else {
                throw HarnessError.malformedResponse("device auth response")
            }
            authState = .deviceCode(
                verificationURL: verificationURL,
                userCode: userCode,
                loginID: loginID
            )
        } catch {
            authState = .failed(error.localizedDescription)
            report(error)
        }
    }

    private func loginWithAPIKey(_ key: String) async {
        guard let client else { return }
        authState = .checking
        pendingAuthMode = .apiKey
        do {
            _ = try await client.request(
                method: "account/login/start",
                params: ["type": "apiKey", "apiKey": key]
            )
        } catch {
            authState = .failed(error.localizedDescription)
            report(error)
        }
    }

    private func sendTurn(
        _ text: String,
        localThreadID: UUID,
        resumeExistingThread: Bool = true,
        requestConfiguration: HarnessThread? = nil
    ) async throws {
        guard let client else { throw HarnessError.appServerStopped("") }
        guard var thread = store.state.threads.first(where: { $0.id == localThreadID }) else {
            throw HarnessError.threadNotFound
        }
        let requestThread = requestConfiguration ?? thread

        if thread.codexThreadID == nil {
            let response = try await client.request(
                method: "thread/start",
                params: Self.threadStartParameters(for: requestThread)
            )
            let codexID = try Self.threadID(from: response, method: "thread/start")
            // A rewrite cannot run while an ordinary send owns the thread, but
            // still verify the identity after every await before mutating the
            // persisted transcript.
            guard store.state.threads.first(where: { $0.id == localThreadID })?.codexThreadID == nil else {
                throw HarnessError.malformedResponse("thread identity changed during thread/start")
            }
            try store.update(localThreadID) { $0.codexThreadID = codexID }
            thread.codexThreadID = codexID
        } else if resumeExistingThread {
            guard let existingThreadID = thread.codexThreadID else {
                throw HarnessError.threadNotFound
            }
            _ = try await client.request(
                method: "thread/resume",
                params: Self.threadResumeParameters(
                    threadID: existingThreadID,
                    thread: requestThread
                )
            )
            guard store.state.threads.first(where: { $0.id == localThreadID })?.codexThreadID
                    == existingThreadID
            else {
                throw HarnessError.malformedResponse("thread identity changed during thread/resume")
            }
        }

        guard let codexThreadID = thread.codexThreadID else {
            throw HarnessError.missingResult("thread/start")
        }
        guard store.state.threads.first(where: { $0.id == localThreadID })?.codexThreadID
                == codexThreadID
        else {
            throw HarnessError.malformedResponse("thread identity changed before turn/start")
        }
        let now = Date()
        let userMessageID = UUID()
        try store.update(localThreadID) { current in
            current.messages.append(
                ChatMessage(
                    id: userMessageID,
                    role: .user,
                    text: text,
                    createdAt: now
                )
            )
            current.lastConversationAt = now
            current.status = .running
            if current.messages.filter({ $0.role == .user }).count == 1 {
                current.title = Self.title(from: text)
            }
        }
        objectWillChange.send()

        let response = try await client.request(
            method: "turn/start",
            params: Self.turnStartParameters(
                threadID: codexThreadID,
                text: text,
                thread: requestThread,
                clientUserMessageID: userMessageID
            )
        )
        guard
            let turn = response["turn"] as? [String: Any],
            let turnID = turn["id"] as? String
        else {
            throw HarnessError.malformedResponse("turn/start.turn.id")
        }
        guard
            let current = store.state.threads.first(where: { $0.id == localThreadID }),
            current.codexThreadID == codexThreadID,
            current.messages.contains(where: { $0.id == userMessageID })
        else {
            throw HarnessError.malformedResponse("thread identity changed during turn/start")
        }
        try store.update(localThreadID) { current in
            current.activeTurnID = turnID
            if let index = current.messages.firstIndex(where: { $0.id == userMessageID }) {
                current.messages[index].turnID = turnID
            }
        }
        objectWillChange.send()
    }

    private func failTurn(_ error: Error, localThreadID: UUID) {
        try? store.update(localThreadID) { thread in
            thread.status = .failed
            thread.activeTurnID = nil
            thread.messages.append(ChatMessage(role: .system, text: error.localizedDescription))
        }
        objectWillChange.send()
        report(error)
    }

    private func cleanupExpiredThreads(using client: CodexAppServerClient) async {
        for thread in store.expiredThreads() {
            do {
                if let codexThreadID = thread.codexThreadID {
                    _ = try await client.request(
                        method: "thread/delete",
                        params: ["threadId": codexThreadID]
                    )
                }
                try store.removeThread(thread.id)
            } catch {
                report(error)
            }
        }
        objectWillChange.send()
    }

    func handleNotification(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "account/login/completed":
            let success = params["success"] as? Bool ?? false
            if success, let mode = pendingAuthMode {
                authState = .authenticated(mode)
                pendingAuthMode = nil
            } else if !success {
                authState = .failed(params["error"] as? String ?? "Sign-in failed.")
            }

        case "account/updated":
            if let mode = params["authMode"] as? String {
                authState = .authenticated(mode == "apikey" ? .apiKey : .deviceAuth)
            }

        case "item/agentMessage/delta":
            handleAgentDelta(params)

        case "item/started":
            handleItemStarted(params)

        case "item/completed":
            handleItemCompleted(params)

        case "turn/completed":
            handleTurnCompleted(params)

        default:
            break
        }
    }

    private func handleAgentDelta(_ params: [String: Any]) {
        guard
            let codexThreadID = params["threadId"] as? String,
            let itemID = params["itemId"] as? String,
            let delta = params["delta"] as? String,
            let localThread = store.state.threads.first(where: { $0.codexThreadID == codexThreadID })
        else { return }

        let key = "\(codexThreadID):\(itemID)"
        let turnID = params["turnId"] as? String
        do {
            if let messageID = streamingMessages[key] {
                try store.update(localThread.id, persistImmediately: false) { thread in
                    guard let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
                    thread.messages[index].text += delta
                    if let turnID { thread.messages[index].turnID = turnID }
                }
            } else {
                let message = ChatMessage(role: .assistant, text: delta, turnID: turnID)
                streamingMessages[key] = message.id
                try store.update(localThread.id, persistImmediately: false) {
                    $0.messages.append(message)
                }
            }
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    private struct ToolCallInfo {
        let kind: ToolCallKind
        let label: String
    }

    private static func toolCallInfo(from item: [String: Any]) -> ToolCallInfo? {
        guard let type = item["type"] as? String else { return nil }

        switch type {
        case "commandExecution":
            guard let command = item["command"] as? String else { return nil }
            return ToolCallInfo(kind: .command, label: command)

        case "fileChange":
            let count = (item["changes"] as? [Any])?.count
                ?? (item["changes"] as? [[String: Any]])?.count
                ?? 0
            return ToolCallInfo(
                kind: .fileChange,
                label: count == 1 ? "1 file changed" : "\(count) files changed"
            )

        case "mcpToolCall":
            guard
                let server = item["server"] as? String,
                let tool = item["tool"] as? String
            else { return nil }
            return ToolCallInfo(kind: .mcpTool, label: "\(server) / \(tool)")

        case "webSearch":
            let query = item["query"] as? String
            return ToolCallInfo(
                kind: .webSearch,
                label: query?.isEmpty == false ? query! : "web search"
            )

        default:
            return nil
        }
    }

    private func handleItemStarted(_ params: [String: Any]) {
        guard
            let codexThreadID = params["threadId"] as? String,
            let item = params["item"] as? [String: Any],
            let itemID = item["id"] as? String,
            let info = Self.toolCallInfo(from: item),
            let localThread = store.state.threads.first(where: { $0.codexThreadID == codexThreadID })
        else { return }

        let turnID = params["turnId"] as? String
        if localThread.toolCalls.contains(where: { $0.itemID == itemID }) {
            if let turnID, localThread.toolCalls.first(where: { $0.itemID == itemID })?.turnID == nil {
                do {
                    try store.update(localThread.id) { thread in
                        guard let index = thread.toolCalls.firstIndex(where: { $0.itemID == itemID }) else { return }
                        thread.toolCalls[index].turnID = turnID
                    }
                } catch {
                    report(error)
                }
            }
            return
        }

        let toolCall = ToolCall(
            itemID: itemID,
            kind: info.kind,
            label: info.label,
            status: .running,
            turnID: turnID,
            createdAt: Self.date(fromMilliseconds: params["startedAtMs"]) ?? Date()
        )

        do {
            try store.update(localThread.id) { $0.toolCalls.append(toolCall) }
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    private func handleItemCompleted(_ params: [String: Any]) {
        guard
            let codexThreadID = params["threadId"] as? String,
            let item = params["item"] as? [String: Any],
            let itemID = item["id"] as? String,
            let localThread = store.state.threads.first(where: { $0.codexThreadID == codexThreadID })
        else { return }

        switch item["type"] as? String {
        case "agentMessage":
            guard let text = item["text"] as? String else { return }

            let key = "\(codexThreadID):\(itemID)"
            let turnID = params["turnId"] as? String
            do {
                if let messageID = streamingMessages.removeValue(forKey: key) {
                    try store.update(localThread.id) { thread in
                        guard let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
                        thread.messages[index].text = text
                        if let turnID { thread.messages[index].turnID = turnID }
                    }
                } else {
                    try store.update(localThread.id) {
                        $0.messages.append(ChatMessage(role: .assistant, text: text, turnID: turnID))
                    }
                }
                objectWillChange.send()
            } catch {
                report(error)
            }

        case "commandExecution", "fileChange", "mcpToolCall", "webSearch":
            guard let info = Self.toolCallInfo(from: item) else { return }

            let exitCode = Self.intValue(item["exitCode"])
            let durationMs = Self.intValue(item["durationMs"])
            let status = Self.toolCallStatus(for: item, exitCode: exitCode)
            let createdAt = Self.date(fromMilliseconds: params["completedAtMs"]) ?? Date()
            let turnID = params["turnId"] as? String

            if let output = item["aggregatedOutput"] as? String, !output.isEmpty {
                toolOutputs[itemID] = Self.truncatedToolOutput(output)
            } else {
                toolOutputs.removeValue(forKey: itemID)
            }

            do {
                try store.update(localThread.id) { thread in
                    if let index = thread.toolCalls.firstIndex(where: { $0.itemID == itemID }) {
                        thread.toolCalls[index].status = status
                        thread.toolCalls[index].exitCode = exitCode
                        thread.toolCalls[index].durationMs = durationMs
                        if let turnID { thread.toolCalls[index].turnID = turnID }
                    } else {
                        thread.toolCalls.append(
                            ToolCall(
                                itemID: itemID,
                                kind: info.kind,
                                label: info.label,
                                status: status,
                                exitCode: exitCode,
                                durationMs: durationMs,
                                turnID: turnID,
                                createdAt: createdAt
                            )
                        )
                    }
                }
                objectWillChange.send()
            } catch {
                report(error)
            }

        default:
            break
        }
    }

    private static func toolCallStatus(for item: [String: Any], exitCode: Int?) -> ToolCallStatus {
        if let exitCode, exitCode != 0 { return .failed }
        let status = (item["status"] as? String)?.lowercased()
        if status == "failed" || status == "error" || status == "declined" { return .failed }
        return .succeeded
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func date(fromMilliseconds value: Any?) -> Date? {
        guard let milliseconds = (value as? NSNumber)?.doubleValue
            ?? (value as? Double)
            ?? (value as? Int).map(Double.init)
        else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func truncatedToolOutput(_ output: String) -> String {
        let lastLines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(200)
            .joined(separator: "\n")
        let data = Data(lastLines.utf8)
        let maxBytes = 32 * 1024
        guard data.count > maxBytes else { return lastLines }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }

    private func handleTurnCompleted(_ params: [String: Any]) {
        guard
            let codexThreadID = params["threadId"] as? String,
            let turn = params["turn"] as? [String: Any],
            let localThread = store.state.threads.first(where: { $0.codexThreadID == codexThreadID })
        else { return }

        let status = turn["status"] as? String ?? "failed"
        do {
            try store.update(localThread.id) { thread in
                thread.activeTurnID = nil
                thread.lastConversationAt = Date()
                switch status {
                case "completed": thread.status = .done
                case "interrupted": thread.status = .stopped
                default: thread.status = .failed
                }
            }
            objectWillChange.send()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    private static func title(from prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? prompt
        if firstLine.count <= 34 { return firstLine }
        return String(firstLine.prefix(33)) + "…"
    }
}
