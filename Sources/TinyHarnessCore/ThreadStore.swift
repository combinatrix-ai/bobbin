import Foundation
import Combine

@MainActor
public final class ThreadStore: ObservableObject {
    @Published public private(set) var state: PersistedState

    public let paths: HarnessPaths
    public let retentionInterval: TimeInterval

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        paths: HarnessPaths,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    ) throws {
        self.paths = paths
        self.retentionInterval = retentionInterval
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        try paths.prepare()
        if FileManager.default.fileExists(atPath: paths.stateFile.path) {
            let data = try Data(contentsOf: paths.stateFile)
            self.state = try decoder.decode(PersistedState.self, from: data)
        } else {
            self.state = PersistedState()
        }

        normalizeInterruptedRuns()
    }

    public var activeThreads: [HarnessThread] {
        state.threads
            .filter { !$0.isSaved }
            .sorted { $0.lastConversationAt > $1.lastConversationAt }
    }

    public var savedThreads: [HarnessThread] {
        state.threads
            .filter(\.isSaved)
            .sorted { ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast) }
    }

    public var selectedThread: HarnessThread? {
        guard let id = state.selectedThreadID else { return nil }
        return state.threads.first { $0.id == id }
    }

    @discardableResult
    public func createThread(workingDirectory: String, now: Date = Date()) throws -> HarnessThread {
        let thread = HarnessThread(
            workingDirectory: workingDirectory,
            model: state.defaultModel,
            reasoningEffort: state.defaultReasoningEffort,
            lastConversationAt: now
        )
        state.threads.append(thread)
        state.selectedThreadID = thread.id
        state.lastWorkingDirectory = workingDirectory
        try persist()
        return thread
    }

    public func updateDefaults(model: String, reasoningEffort: String) throws {
        state.defaultModel = model
        state.defaultReasoningEffort = reasoningEffort
        try persist()
    }

    public func select(_ id: UUID) throws {
        guard state.threads.contains(where: { $0.id == id }) else {
            throw HarnessError.threadNotFound
        }
        state.selectedThreadID = id
        try persist()
    }

    public func update(
        _ id: UUID,
        persistImmediately: Bool = true,
        mutate: (inout HarnessThread) -> Void
    ) throws {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else {
            throw HarnessError.threadNotFound
        }
        mutate(&state.threads[index])
        if persistImmediately { try persist() }
    }

    public func saveThread(_ id: UUID, now: Date = Date()) throws {
        try update(id) { thread in
            if thread.savedAt == nil { thread.savedAt = now }
        }
    }

    public func removeThread(_ id: UUID) throws {
        state.threads.removeAll { $0.id == id }
        if state.selectedThreadID == id {
            state.selectedThreadID = activeThreads.first?.id ?? savedThreads.first?.id
        }
        try persist()
    }

    public func expiredThreads(now: Date = Date()) -> [HarnessThread] {
        state.threads.filter {
            !$0.isSaved && now.timeIntervalSince($0.lastConversationAt) >= retentionInterval
        }
    }

    public func opacity(for thread: HarnessThread, now: Date = Date()) -> Double {
        guard !thread.isSaved else { return 1 }
        let age = max(0, now.timeIntervalSince(thread.lastConversationAt))
        let progress = min(1, age / retentionInterval)
        return 1 - (0.58 * progress)
    }

    public func persist() throws {
        let data = try encoder.encode(state)
        try data.write(to: paths.stateFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.stateFile.path
        )
    }

    private func normalizeInterruptedRuns() {
        var changed = false
        for index in state.threads.indices where state.threads[index].status == .running {
            state.threads[index].status = .stopped
            state.threads[index].activeTurnID = nil
            changed = true
        }
        if changed { try? persist() }
    }
}
