import Foundation
import Combine

@MainActor
public final class HarnessController: ObservableObject {
    public static let defaultModel = "gpt-5.6-luna"
    public static let defaultEffort = "xhigh"

    public enum ServerState: Equatable {
        case starting
        case ready
        case stopped(String)

        public var label: String {
            switch self {
            case .starting: "Starting app server"
            case .ready: "App server ready"
            case .stopped: "App server stopped"
            }
        }
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
    @Published public private(set) var lastError: String?

    public let store: ThreadStore

    private let keyProvider: APIKeyProvider
    private var client: CodexAppServerClient?
    private var pendingAuthMode: AuthenticationMode?
    private var streamingMessages: [String: UUID] = [:]
    private var bootTask: Task<Void, Never>?

    public init(paths: HarnessPaths? = nil, keyProvider: APIKeyProvider = APIKeyProvider()) throws {
        let paths = try paths ?? HarnessPaths()
        self.store = try ThreadStore(paths: paths)
        self.keyProvider = keyProvider

        if store.state.threads.isEmpty {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            _ = try store.createThread(workingDirectory: documents.path)
        }
    }

    public var selectedThread: HarnessThread? { store.selectedThread }
    public var activeThreads: [HarnessThread] { store.activeThreads }
    public var savedThreads: [HarnessThread] { store.savedThreads }

    public func boot() {
        guard client == nil else { return }
        bootTask?.cancel()
        bootTask = Task { await bootSequence() }
    }

    public func restart() {
        client?.stop()
        client = nil
        serverState = .starting
        authState = .checking
        modelVerified = false
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
            authState = .failed("API keyを入力してください。")
            return
        }
        Task { await loginWithAPIKey(trimmed) }
    }

    public func createThread(workingDirectory: String? = nil) {
        let cwd = workingDirectory
            ?? store.state.lastWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        do {
            _ = try store.createThread(workingDirectory: cwd)
            objectWillChange.send()
        } catch {
            report(error)
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
            lastError = "認証とapp-serverの準備が完了していません。"
            return
        }

        Task { await sendTurn(trimmed, localThreadID: localThreadID) }
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

            try await verifyDefaultModel(using: client)
            await cleanupExpiredThreads(using: client)
            try await resolveAuthentication(using: client)
        } catch {
            serverState = .stopped(error.localizedDescription)
            authState = .failed(error.localizedDescription)
            report(error)
        }
    }

    private func verifyDefaultModel(using client: CodexAppServerClient) async throws {
        let response = try await client.request(
            method: "model/list",
            params: ["limit": 100, "includeHidden": true]
        )
        guard let models = response["data"] as? [[String: Any]] else {
            throw HarnessError.malformedResponse("model/list.data")
        }
        guard let model = models.first(where: {
            ($0["id"] as? String) == Self.defaultModel || ($0["model"] as? String) == Self.defaultModel
        }) else {
            throw HarnessError.modelUnavailable(Self.defaultModel)
        }
        let efforts = model["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        guard efforts.contains(where: { ($0["reasoningEffort"] as? String) == Self.defaultEffort }) else {
            throw HarnessError.modelUnavailable(Self.defaultModel)
        }
        modelVerified = true
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

    private func sendTurn(_ text: String, localThreadID: UUID) async {
        guard let client else { return }
        do {
            guard var thread = store.state.threads.first(where: { $0.id == localThreadID }) else {
                throw HarnessError.threadNotFound
            }

            if thread.codexThreadID == nil {
                let response = try await client.request(
                    method: "thread/start",
                    params: [
                        "model": Self.defaultModel,
                        "cwd": thread.workingDirectory,
                        "approvalPolicy": "never",
                        "sandbox": "workspace-write",
                        "serviceName": "tiny_harness_gui"
                    ]
                )
                guard
                    let resultThread = response["thread"] as? [String: Any],
                    let codexID = resultThread["id"] as? String
                else {
                    throw HarnessError.malformedResponse("thread/start.thread.id")
                }
                try store.update(localThreadID) { $0.codexThreadID = codexID }
                thread.codexThreadID = codexID
            } else {
                guard let existingThreadID = thread.codexThreadID else {
                    throw HarnessError.threadNotFound
                }
                _ = try await client.request(
                    method: "thread/resume",
                    params: ["threadId": existingThreadID]
                )
            }

            guard let codexThreadID = thread.codexThreadID else {
                throw HarnessError.missingResult("thread/start")
            }
            let now = Date()
            try store.update(localThreadID) { current in
                current.messages.append(ChatMessage(role: .user, text: text, createdAt: now))
                current.lastConversationAt = now
                current.status = .running
                if current.messages.filter({ $0.role == .user }).count == 1 {
                    current.title = Self.title(from: text)
                }
            }
            objectWillChange.send()

            let response = try await client.request(
                method: "turn/start",
                params: [
                    "threadId": codexThreadID,
                    "input": [["type": "text", "text": text]],
                    "cwd": thread.workingDirectory,
                    "approvalPolicy": "never",
                    "model": Self.defaultModel,
                    "effort": Self.defaultEffort
                ]
            )
            guard
                let turn = response["turn"] as? [String: Any],
                let turnID = turn["id"] as? String
            else {
                throw HarnessError.malformedResponse("turn/start.turn.id")
            }
            try store.update(localThreadID) { $0.activeTurnID = turnID }
            objectWillChange.send()
        } catch {
            try? store.update(localThreadID) { thread in
                thread.status = .failed
                thread.activeTurnID = nil
                thread.messages.append(ChatMessage(role: .system, text: error.localizedDescription))
            }
            objectWillChange.send()
            report(error)
        }
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

    private func handleNotification(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "account/login/completed":
            let success = params["success"] as? Bool ?? false
            if success, let mode = pendingAuthMode {
                authState = .authenticated(mode)
                pendingAuthMode = nil
            } else if !success {
                authState = .failed(params["error"] as? String ?? "認証に失敗しました。")
            }

        case "account/updated":
            if let mode = params["authMode"] as? String {
                authState = .authenticated(mode == "apikey" ? .apiKey : .deviceAuth)
            }

        case "item/agentMessage/delta":
            handleAgentDelta(params)

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
        do {
            if let messageID = streamingMessages[key] {
                try store.update(localThread.id, persistImmediately: false) { thread in
                    guard let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
                    thread.messages[index].text += delta
                }
            } else {
                let message = ChatMessage(role: .assistant, text: delta)
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

    private func handleItemCompleted(_ params: [String: Any]) {
        guard
            let codexThreadID = params["threadId"] as? String,
            let item = params["item"] as? [String: Any],
            (item["type"] as? String) == "agentMessage",
            let itemID = item["id"] as? String,
            let text = item["text"] as? String,
            let localThread = store.state.threads.first(where: { $0.codexThreadID == codexThreadID })
        else { return }

        let key = "\(codexThreadID):\(itemID)"
        do {
            if let messageID = streamingMessages.removeValue(forKey: key) {
                try store.update(localThread.id) { thread in
                    guard let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
                    thread.messages[index].text = text
                }
            } else {
                try store.update(localThread.id) { $0.messages.append(ChatMessage(role: .assistant, text: text)) }
            }
            objectWillChange.send()
        } catch {
            report(error)
        }
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
