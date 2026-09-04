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
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        normalizeInterruptedRuns: Bool = true
    ) throws {
        self.paths = paths
        self.retentionInterval = retentionInterval
        self.encoder = PersistedStateCoding.encoder()
        self.decoder = PersistedStateCoding.decoder()

        try paths.prepare()
        if FileManager.default.fileExists(atPath: paths.stateFile.path) {
            let data = try Data(contentsOf: paths.stateFile)
            self.state = try decoder.decode(PersistedState.self, from: data)
        } else {
            self.state = PersistedState()
        }

        if normalizeInterruptedRuns {
            self.normalizeInterruptedRuns()
        }
    }

    public var activeThreads: [HarnessThread] {
        state.threads
            .filter { !$0.isSaved }
            .sorted { $0.lastConversationAt > $1.lastConversationAt }
    }

    /// Whether at least one local turn is still in flight. Saved threads can
    /// be running too, so this intentionally considers every thread.
    public var hasRunningThread: Bool {
        state.threads.contains { $0.status == .running }
    }

    public var runningThreadCount: Int {
        state.threads.count(where: { $0.status == .running })
    }

    public var unseenResultThreadCount: Int {
        state.threads.count(where: { $0.hasUnseenResult })
    }

    public var hasUnseenResults: Bool {
        unseenResultThreadCount > 0
    }

    public var savedThreads: [HarnessThread] {
        state.threads
            .filter(\.isSaved)
            .sorted { ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast) }
    }

    public var automaticCleanupEnabled: Bool {
        state.automaticCleanupEnabled
    }

    public var deletionTombstones: [ThreadDeletionTombstone] {
        state.deletionTombstones
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
            systemPrompt: state.defaultSystemPrompt,
            lastConversationAt: now
        )
        state.threads.append(thread)
        state.selectedThreadID = thread.id
        try persist()
        return thread
    }

    public func updateDefaults(model: String, reasoningEffort: String) throws {
        state.defaultModel = model
        state.defaultReasoningEffort = reasoningEffort
        try persist()
    }

    public func updateSystemPrompt(_ text: String) throws {
        state.defaultSystemPrompt = text
        try persist()
    }

    public func setAutomaticCleanupEnabled(_ enabled: Bool) throws {
        state.automaticCleanupEnabled = enabled
        try persist()
    }

    public func select(_ id: UUID) throws {
        guard state.threads.contains(where: { $0.id == id }) else {
            throw HarnessError.threadNotFound
        }
        state.selectedThreadID = id
        try persist()
    }

    /// Applies a lifecycle status transition and records unseen output only
    /// for a real running -> done/failed transition. Stopped is intentionally
    /// not treated as new output because the user explicitly interrupted it.
    public func updateStatus(
        _ id: UUID,
        _ status: HarnessThreadStatus,
        conversationIsDisplayed: Bool = false,
        mutate: (inout HarnessThread) -> Void = { _ in }
    ) throws {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else {
            throw HarnessError.threadNotFound
        }
        let wasRunning = state.threads[index].status == .running
        state.threads[index].status = status
        if status == .running {
            state.threads[index].hasUnseenResult = false
        } else if wasRunning && (status == .done || status == .failed) {
            state.threads[index].hasUnseenResult = !conversationIsDisplayed
        }
        mutate(&state.threads[index])
        try persist()
    }

    /// Clears only the supplied conversation's notification. Opening the
    /// thread list must not call this method.
    public func clearUnseenResult(_ id: UUID) throws {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else {
            throw HarnessError.threadNotFound
        }
        guard state.threads[index].hasUnseenResult else { return }
        state.threads[index].hasUnseenResult = false
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
            state.selectedThreadID = nil
        }
        try persist()
    }

    /// Removes local content before any network work and records only the
    /// server identifiers needed to finish deletion. The tombstone is kept
    /// even when the server identifier is not known yet: a late
    /// `thread/start` response can then be attached safely.
    @discardableResult
    public func removeThreadAndRecordDeletion(
        _ id: UUID,
        codexThreadIDs: [String],
        reason: ThreadDeletionReason,
        now: Date = Date()
    ) throws -> ThreadDeletionTombstone {
        let uniqueIDs = codexThreadIDs.filter { !$0.isEmpty }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        if let index = state.deletionTombstones.firstIndex(where: { $0.localThreadID == id }) {
            state.deletionTombstones[index].codexThreadIDs = uniqueIDs.reduce(
                into: state.deletionTombstones[index].codexThreadIDs
            ) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            state.threads.removeAll { $0.id == id }
            if state.selectedThreadID == id { state.selectedThreadID = nil }
            try persist()
            return state.deletionTombstones[index]
        }

        let tombstone = ThreadDeletionTombstone(
            localThreadID: id,
            codexThreadIDs: uniqueIDs,
            reason: reason,
            requestedAt: now
        )
        state.deletionTombstones.append(tombstone)
        state.threads.removeAll { $0.id == id }
        if state.selectedThreadID == id { state.selectedThreadID = nil }
        try persist()
        return tombstone
    }

    @discardableResult
    public func recordServerDeletion(
        codexThreadIDs: [String],
        reason: ThreadDeletionReason,
        localThreadID: UUID? = nil,
        now: Date = Date()
    ) throws -> ThreadDeletionTombstone {
        let uniqueIDs = codexThreadIDs.filter { !$0.isEmpty }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        if let index = state.deletionTombstones.firstIndex(where: {
            $0.localThreadID == localThreadID && $0.reason == reason
        }) {
            state.deletionTombstones[index].codexThreadIDs = uniqueIDs.reduce(
                into: state.deletionTombstones[index].codexThreadIDs
            ) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            try persist()
            return state.deletionTombstones[index]
        }

        let tombstone = ThreadDeletionTombstone(
            localThreadID: localThreadID,
            codexThreadIDs: uniqueIDs,
            reason: reason,
            requestedAt: now
        )
        state.deletionTombstones.append(tombstone)
        try persist()
        return tombstone
    }

    public func updateDeletionTombstone(
        _ id: UUID,
        mutate: (inout ThreadDeletionTombstone) -> Void
    ) throws {
        guard let index = state.deletionTombstones.firstIndex(where: { $0.id == id }) else {
            throw HarnessError.threadNotFound
        }
        mutate(&state.deletionTombstones[index])
        try persist()
    }

    public func appendCodexThreadID(_ codexThreadID: String, toDeletionTombstone id: UUID) throws {
        guard !codexThreadID.isEmpty else { return }
        try updateDeletionTombstone(id) { tombstone in
            if !tombstone.codexThreadIDs.contains(codexThreadID) {
                tombstone.codexThreadIDs.append(codexThreadID)
            }
        }
    }

    public func removeDeletionTombstone(_ id: UUID) throws {
        state.deletionTombstones.removeAll { $0.id == id }
        try persist()
    }

    public func deletionTombstone(forLocalThreadID id: UUID) -> ThreadDeletionTombstone? {
        state.deletionTombstones.first { $0.localThreadID == id }
    }

    public func deletionTombstone(withID id: UUID) -> ThreadDeletionTombstone? {
        state.deletionTombstones.first { $0.id == id }
    }

    /// Removes server roots only after the app-server confirms deletion. This
    /// lets the active local thread keep every root in the known-ID set while
    /// a tombstone is waiting or retrying, then forgets superseded roots once
    /// their rollout has really been removed.
    public func removeCodexThreadIDs(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        var changed = false
        for index in state.threads.indices {
            let current = state.threads[index].codexThreadID
            let remaining = state.threads[index].codexThreadIDs.filter { !ids.contains($0) }
            if remaining != state.threads[index].codexThreadIDs {
                state.threads[index].codexThreadIDs = remaining
                if let current, ids.contains(current) {
                    state.threads[index].codexThreadID = nil
                }
                changed = true
            }
        }
        if changed { try persist() }
    }

    public func expiredThreads(now: Date = Date()) -> [HarnessThread] {
        guard automaticCleanupEnabled else { return [] }
        return expirationCandidates(now: now)
    }

    /// Count candidates independently of the switch state so the UI can warn
    /// before turning cleanup back on.
    public func expiredCandidateCount(now: Date = Date()) -> Int {
        expirationCandidates(now: now).count
    }

    private func expirationCandidates(now: Date) -> [HarnessThread] {
        state.threads.filter {
            !$0.isSaved && $0.status != .running
                && now.timeIntervalSince($0.lastConversationAt) >= retentionInterval
        }
    }

    public func opacity(for thread: HarnessThread, now: Date = Date()) -> Double {
        guard automaticCleanupEnabled, !thread.isSaved else { return 1 }
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
        for index in state.threads.indices {
            if state.threads[index].status == .running {
                state.threads[index].status = .stopped
                state.threads[index].activeTurnID = nil
                changed = true
            }

            for toolCallIndex in state.threads[index].toolCalls.indices
                where state.threads[index].toolCalls[toolCallIndex].status == .running {
                state.threads[index].toolCalls[toolCallIndex].status = .stopped
                changed = true
            }
        }
        if changed { try? persist() }
    }
}
