import XCTest
@testable import BobbinCore

@MainActor
final class ToolCallTests: XCTestCase {
    func testItemStartedCommandCreatesRunningToolCall() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let threadID = try configureThread(fixture.controller)
        let startedAt = Date(timeIntervalSince1970: 2_000_000)

        fixture.controller.handleNotification(notification(
            method: "item/started",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "startedAtMs": startedAt.timeIntervalSince1970 * 1_000,
                "item": [
                    "type": "commandExecution",
                    "id": "item-1",
                    "command": "swift build"
                ]
            ]
        ))

        let thread = try XCTUnwrap(fixture.controller.store.state.threads.first { $0.id == threadID })
        let toolCall = try XCTUnwrap(thread.toolCalls.first)
        XCTAssertEqual(toolCall.itemID, "item-1")
        XCTAssertEqual(toolCall.kind, .command)
        XCTAssertEqual(toolCall.label, "swift build")
        XCTAssertEqual(toolCall.status, .running)
        XCTAssertEqual(toolCall.turnID, "turn-1")
        XCTAssertEqual(toolCall.createdAt, startedAt)
    }

    func testItemStartedIgnoresReasoning() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let threadID = try configureThread(fixture.controller)

        fixture.controller.handleNotification(notification(
            method: "item/started",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "startedAtMs": 2_000_000_000,
                "item": [
                    "type": "reasoning",
                    "id": "reasoning-1",
                    "summary": ["internal"]
                ]
            ]
        ))

        let thread = try XCTUnwrap(fixture.controller.store.state.threads.first { $0.id == threadID })
        XCTAssertTrue(thread.toolCalls.isEmpty)
    }

    func testItemCompletedMatchesByItemIDAndNonZeroExitFails() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let threadID = try configureThread(fixture.controller)

        sendCommandStarted(to: fixture.controller, itemID: "item-1", command: "swift test")
        fixture.controller.handleNotification(notification(
            method: "item/completed",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "completedAtMs": 2_000_000_100,
                "item": [
                    "type": "commandExecution",
                    "id": "item-1",
                    "command": "swift test",
                    "status": "completed",
                    "exitCode": 2,
                    "durationMs": 4_100,
                    "aggregatedOutput": "failed"
                ]
            ]
        ))

        let thread = try XCTUnwrap(fixture.controller.store.state.threads.first { $0.id == threadID })
        let toolCall = try XCTUnwrap(thread.toolCalls.first)
        XCTAssertEqual(toolCall.itemID, "item-1")
        XCTAssertEqual(toolCall.status, .failed)
        XCTAssertEqual(toolCall.exitCode, 2)
        XCTAssertEqual(toolCall.durationMs, 4_100)
        XCTAssertEqual(fixture.controller.toolOutput(for: "item-1"), "failed")
    }

    func testCompletedItemWithoutStartStillProducesARow() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let threadID = try configureThread(fixture.controller)

        fixture.controller.handleNotification(notification(
            method: "item/completed",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "completedAtMs": 2_000_000_000,
                "item": [
                    "type": "webSearch",
                    "id": "search-1",
                    "query": "Swift concurrency"
                ]
            ]
        ))

        let thread = try XCTUnwrap(fixture.controller.store.state.threads.first { $0.id == threadID })
        let toolCall = try XCTUnwrap(thread.toolCalls.first)
        XCTAssertEqual(toolCall.kind, .webSearch)
        XCTAssertEqual(toolCall.label, "Swift concurrency")
        XCTAssertEqual(toolCall.status, .succeeded)
        XCTAssertEqual(toolCall.turnID, "turn-1")
        XCTAssertEqual(toolCall.createdAt, Date(timeIntervalSince1970: 2_000_000))
    }

    func testFileChangeLabelPluralizes() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let threadID = try configureThread(fixture.controller)

        sendFileChangeStarted(to: fixture.controller, itemID: "file-1", count: 1)
        sendFileChangeStarted(to: fixture.controller, itemID: "file-3", count: 3)

        let thread = try XCTUnwrap(fixture.controller.store.state.threads.first { $0.id == threadID })
        XCTAssertEqual(thread.toolCalls.map(\.label), ["1 file changed", "3 files changed"])
    }

    func testToolCallOutputIsNotPersisted() throws {
        let output = "this output must stay in memory"
        let call = ToolCall(
            itemID: "item-1",
            kind: .command,
            label: "swift build",
            status: .succeeded,
            durationMs: 200,
            createdAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let thread = HarnessThread(
            workingDirectory: "/tmp/project",
            toolCalls: [call]
        )

        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(HarnessThread.self, from: data)
        let rawJSON = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded.toolCalls, [call])
        XCTAssertFalse(rawJSON.contains(output))
        XCTAssertFalse(rawJSON.contains("aggregatedOutput"))
    }

    func testTranscriptTurnIDsRoundTripAndRemainOptionalForLegacyState() throws {
        let message = ChatMessage(role: .user, text: "hello", turnID: "turn-1")
        let call = ToolCall(
            itemID: "item-1",
            kind: .command,
            label: "swift test",
            status: .succeeded,
            turnID: "turn-1"
        )
        let thread = HarnessThread(
            workingDirectory: "/tmp/project",
            messages: [message],
            toolCalls: [call]
        )

        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(HarnessThread.self, from: data)

        XCTAssertEqual(decoded.messages.first?.turnID, "turn-1")
        XCTAssertEqual(decoded.toolCalls.first?.turnID, "turn-1")

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var legacyMessages = try XCTUnwrap(legacyObject["messages"] as? [[String: Any]])
        legacyMessages[0].removeValue(forKey: "turnID")
        legacyObject["messages"] = legacyMessages
        var legacyCalls = try XCTUnwrap(legacyObject["toolCalls"] as? [[String: Any]])
        legacyCalls[0].removeValue(forKey: "turnID")
        legacyObject["toolCalls"] = legacyCalls

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(HarnessThread.self, from: legacyData)
        XCTAssertNil(legacy.messages.first?.turnID)
        XCTAssertNil(legacy.toolCalls.first?.turnID)
    }

    func testToolOutputKeepsOnlyTheLastTwoHundredLinesAndThirtyTwoKilobytes() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        _ = try configureThread(fixture.controller)
        let output = (0..<250)
            .map { "line-\($0) " + String(repeating: "x", count: 300) }
            .joined(separator: "\n")

        fixture.controller.handleNotification(notification(
            method: "item/completed",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "completedAtMs": 2_000_000_000,
                "item": [
                    "type": "commandExecution",
                    "id": "item-1",
                    "command": "swift build",
                    "status": "completed",
                    "aggregatedOutput": output
                ]
            ]
        ))

        let stored = try XCTUnwrap(fixture.controller.toolOutput(for: "item-1"))
        XCTAssertLessThanOrEqual(stored.utf8.count, 32 * 1024)
        XCTAssertFalse(stored.contains("line-0 "))
        XCTAssertTrue(stored.contains("line-249 "))
    }

    func testRunningToolCallIsNormalizedToStoppedOnLoad() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let thread = try fixture.store.createThread(workingDirectory: "/tmp/project")
        let runningCall = ToolCall(
            itemID: "item-1",
            kind: .mcpTool,
            label: "server / tool",
            status: .running
        )
        try fixture.store.update(thread.id) { $0.toolCalls = [runningCall] }

        let reloaded = try ThreadStore(paths: fixture.paths)
        XCTAssertEqual(reloaded.state.threads.first?.toolCalls.first?.status, .stopped)
    }

    func testTranscriptEntriesMergeByCreatedAtWithStableTies() {
        let base = Date(timeIntervalSince1970: 2_000_000)
        let firstMessage = ChatMessage(role: .user, text: "first", createdAt: base.addingTimeInterval(2))
        let secondMessage = ChatMessage(role: .assistant, text: "second", createdAt: base.addingTimeInterval(4))
        let firstToolCall = ToolCall(
            itemID: "tool-1",
            kind: .command,
            label: "swift build",
            status: .succeeded,
            createdAt: base.addingTimeInterval(1)
        )
        let secondToolCall = ToolCall(
            itemID: "tool-2",
            kind: .fileChange,
            label: "1 file changed",
            status: .succeeded,
            createdAt: base.addingTimeInterval(4)
        )
        let thread = HarnessThread(
            workingDirectory: "/tmp/project",
            messages: [firstMessage, secondMessage],
            toolCalls: [firstToolCall, secondToolCall]
        )

        XCTAssertEqual(
            thread.transcriptEntries.map(\.id),
            [
                "toolCall:\(firstToolCall.id.uuidString)",
                "message:\(firstMessage.id.uuidString)",
                "message:\(secondMessage.id.uuidString)",
                "toolCall:\(secondToolCall.id.uuidString)"
            ]
        )
    }

    func testAgentMessageStillBecomesMessageWithoutToolCall() throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let threadID = try configureThread(fixture.controller)

        fixture.controller.handleNotification(notification(
            method: "item/completed",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "completedAtMs": 2_000_000_000,
                "item": [
                    "type": "agentMessage",
                    "id": "message-1",
                    "text": "Done."
                ]
            ]
        ))

        let thread = try XCTUnwrap(fixture.controller.store.state.threads.first { $0.id == threadID })
        XCTAssertEqual(thread.messages.map(\.text), ["Done."])
        XCTAssertEqual(thread.messages.first?.turnID, "turn-1")
        XCTAssertTrue(thread.toolCalls.isEmpty)
    }

    private func configureThread(_ controller: HarnessController) throws -> UUID {
        let threadID = try XCTUnwrap(controller.store.state.threads.first?.id)
        try controller.store.update(threadID) { $0.codexThreadID = "codex-thread" }
        return threadID
    }

    private func sendCommandStarted(
        to controller: HarnessController,
        itemID: String,
        command: String
    ) {
        controller.handleNotification(notification(
            method: "item/started",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "startedAtMs": 2_000_000_000,
                "item": [
                    "type": "commandExecution",
                    "id": itemID,
                    "command": command
                ]
            ]
        ))
    }

    private func sendFileChangeStarted(
        to controller: HarnessController,
        itemID: String,
        count: Int
    ) {
        controller.handleNotification(notification(
            method: "item/started",
            params: [
                "threadId": "codex-thread",
                "turnId": "turn-1",
                "startedAtMs": 2_000_000_000,
                "item": [
                    "type": "fileChange",
                    "id": itemID,
                    "changes": Array(repeating: ["path": "file.swift"], count: count)
                ]
            ]
        ))
    }
}

private func notification(method: String, params: [String: Any]) -> [String: Any] {
    ["method": method, "params": params]
}

@MainActor
private struct ControllerFixture {
    let root: URL
    let paths: HarnessPaths
    let controller: HarnessController

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BobbinToolCallTests-\(UUID().uuidString)", isDirectory: true)
        paths = try HarnessPaths(root: root)
        controller = try HarnessController(paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private struct StoreFixture {
    let root: URL
    let paths: HarnessPaths
    let store: ThreadStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BobbinToolCallStoreTests-\(UUID().uuidString)", isDirectory: true)
        paths = try HarnessPaths(root: root)
        store = try ThreadStore(paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
