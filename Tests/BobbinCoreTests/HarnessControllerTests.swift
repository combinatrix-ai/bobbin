import Foundation
import XCTest
@testable import BobbinCore

@MainActor
final class HarnessControllerTests: XCTestCase {
    func testProductionControllerKeepsHomeAsComposerDefault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let controller = try HarnessController(
            testPaths: fixture.paths,
            appServerClient: RecordingAppServerClient()
        )
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        XCTAssertFalse(controller.isDemoMode)
        XCTAssertTrue(controller.shouldAutofocusNewThread)
        XCTAssertEqual(controller.newThreadWorkingDirectory, home)
        controller.createThread()
        XCTAssertEqual(controller.store.state.threads.last?.workingDirectory, home)
    }

    func testCreateThreadAndSendCreatesOneThreadInChosenDirectoryAndStartsTurn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        let controller = try HarnessController(
            testPaths: fixture.paths,
            appServerClient: client
        )
        let initialCount = controller.store.state.threads.count
        let turnStarted = expectation(description: "turn/start is requested")
        client.onTurnStart = { turnStarted.fulfill() }

        let text = "Inspect the launch flow"
        let workingDirectory = "/tmp/bobbin-project"
        let threadID = controller.createThreadAndSend(
            text: text,
            workingDirectory: workingDirectory
        )

        let createdID = try XCTUnwrap(threadID)
        XCTAssertEqual(controller.store.state.threads.count, initialCount + 1)
        XCTAssertEqual(
            controller.store.state.threads.filter { $0.id == createdID }.count,
            1
        )
        XCTAssertEqual(
            controller.store.state.threads.first(where: { $0.id == createdID })?.workingDirectory,
            workingDirectory
        )

        await fulfillment(of: [turnStarted], timeout: 2)

        let turnRequest = try XCTUnwrap(
            client.requests.last(where: { $0.method == "turn/start" })
        )
        let input = try XCTUnwrap(turnRequest.params?["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, text)
        XCTAssertEqual(
            controller.store.state.threads.first(where: { $0.id == createdID })?.messages.map(\.text),
            [text]
        )
    }

    func testCreateThreadAndSendInheritsCurrentDefaults() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        let controller = try HarnessController(
            testPaths: fixture.paths,
            appServerClient: client
        )
        try controller.store.updateDefaults(model: "gpt-5.6-terra", reasoningEffort: "high")
        try controller.store.updateSystemPrompt("Keep the first turn concise.")

        let turnStarted = expectation(description: "turn/start is requested")
        client.onTurnStart = { turnStarted.fulfill() }
        let threadID = try XCTUnwrap(
            controller.createThreadAndSend(
                text: "Use the current defaults",
                workingDirectory: "/tmp/defaults-project"
            )
        )

        await fulfillment(of: [turnStarted], timeout: 2)

        let created = try XCTUnwrap(
            controller.store.state.threads.first(where: { $0.id == threadID })
        )
        XCTAssertEqual(created.model, "gpt-5.6-terra")
        XCTAssertEqual(created.reasoningEffort, "high")
        XCTAssertEqual(created.systemPrompt, "Keep the first turn concise.")

        let startRequest = try XCTUnwrap(
            client.requests.first(where: { $0.method == "thread/start" })
        )
        XCTAssertEqual(startRequest.params?["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(startRequest.params?["cwd"] as? String, "/tmp/defaults-project")
        XCTAssertEqual(
            startRequest.params?["developerInstructions"] as? String,
            "Keep the first turn concise."
        )
    }

    func testCreateThreadAndSendIgnoresEmptyAndWhitespaceOnlyText() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        let controller = try HarnessController(
            testPaths: fixture.paths,
            appServerClient: client
        )
        let initialCount = controller.store.state.threads.count

        for text in ["", " \n\t "] {
            XCTAssertNil(
                controller.createThreadAndSend(
                    text: text,
                    workingDirectory: "/tmp/should-not-exist"
                )
            )
        }

        XCTAssertEqual(controller.store.state.threads.count, initialCount)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testDeleteThreadRemovesIdleStopsRunningAndClearsSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        let controller = try HarnessController(
            testPaths: fixture.paths,
            appServerClient: client
        )
        let idle = try controller.store.createThread(workingDirectory: "/tmp/idle")
        let running = try controller.store.createThread(workingDirectory: "/tmp/running")
        try controller.store.update(running.id) { thread in
            thread.codexThreadID = "server-thread"
            thread.activeTurnID = "server-turn"
            thread.status = .running
        }
        controller.selectThread(running.id)

        controller.deleteThread(idle.id)
        XCTAssertFalse(controller.store.state.threads.contains(where: { $0.id == idle.id }))
        XCTAssertEqual(controller.store.state.selectedThreadID, running.id)

        controller.deleteThread(running.id)
        await waitUntil("running thread interrupt is requested") {
            client.requests.contains(where: { $0.method == "turn/interrupt" })
        }
        await waitUntil("running thread server deletion is requested") {
            client.requests.contains(where: { $0.method == "thread/delete" })
        }

        XCTAssertFalse(controller.store.state.threads.contains(where: { $0.id == running.id }))
        XCTAssertNil(controller.store.state.selectedThreadID)
        XCTAssertEqual(
            client.requests.first(where: { $0.method == "turn/interrupt" })?.params?["threadId"] as? String,
            "server-thread"
        )
        XCTAssertEqual(
            client.requests.first(where: { $0.method == "turn/interrupt" })?.params?["turnId"] as? String,
            "server-turn"
        )
        let runningRequestMethods = client.requests.compactMap { request -> String? in
            guard request.method == "turn/interrupt" || request.method == "thread/delete" else {
                return nil
            }
            return request.method
        }
        XCTAssertEqual(runningRequestMethods, ["turn/interrupt", "thread/delete"])
    }

    func testModelChangesShareOneReasoningFallbackPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let controller = try HarnessController(
            testPaths: fixture.paths,
            appServerClient: RecordingAppServerClient()
        )

        XCTAssertEqual(
            controller.resolvedReasoningEffort(for: "gpt-5.6-luna", keeping: "high"),
            "high"
        )
        XCTAssertEqual(
            controller.resolvedReasoningEffort(for: "gpt-5.6-luna", keeping: "max"),
            HarnessController.defaultEffort
        )

        try controller.store.updateDefaults(model: "gpt-5.6-terra", reasoningEffort: "max")
        controller.updateDefaultModel("gpt-5.6-luna")
        XCTAssertEqual(controller.store.state.defaultReasoningEffort, HarnessController.defaultEffort)
    }

    func testEditReadsAndForksAtPriorTurnBeforeTruncatingSuffix() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        client.responseHandler = { method, _ in
            switch method {
            case "thread/read":
                return ["thread": ["turns": [["id": "turn-1"], ["id": "turn-2"]]]]
            case "thread/fork":
                return ["thread": ["id": "forked-thread"]]
            case "turn/start":
                return ["turn": ["id": "turn-replacement"]]
            default:
                return client.defaultResponse(for: method)
            }
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        let timestamps = (0..<5).map { Date(timeIntervalSince1970: 1_000 + Double($0)) }
        let firstUser = ChatMessage(
            role: .user,
            text: "first",
            turnID: "turn-1",
            createdAt: timestamps[0]
        )
        let firstAssistant = ChatMessage(
            role: .assistant,
            text: "first answer",
            turnID: "turn-1",
            createdAt: timestamps[1]
        )
        let secondUser = ChatMessage(
            role: .user,
            text: "second",
            turnID: "turn-2",
            createdAt: timestamps[2]
        )
        let secondAssistant = ChatMessage(
            role: .assistant,
            text: "second answer",
            turnID: "turn-2",
            createdAt: timestamps[3]
        )
        let keptCall = ToolCall(
            itemID: "tool-1",
            kind: .command,
            label: "kept",
            status: .succeeded,
            turnID: "turn-1",
            createdAt: timestamps[1]
        )
        let removedCall = ToolCall(
            itemID: "tool-2",
            kind: .command,
            label: "removed",
            status: .succeeded,
            turnID: "turn-2",
            createdAt: timestamps[3]
        )
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "original-thread"
            thread.status = .done
            thread.reviewMode = .allowAll
            thread.messages = [firstUser, firstAssistant, secondUser, secondAssistant]
            thread.toolCalls = [keptCall, removedCall]
        }
        controller.handleNotification([
            "method": "item/completed",
            "params": [
                "threadId": "original-thread",
                "turnId": "turn-2",
                "item": [
                    "id": "tool-2",
                    "type": "commandExecution",
                    "command": "removed",
                    "aggregatedOutput": "stale output"
                ]
            ]
        ])
        XCTAssertEqual(controller.toolOutput(for: "tool-2"), "stale output")

        let turnStarted = expectation(description: "replacement turn starts")
        client.onTurnStart = { turnStarted.fulfill() }
        XCTAssertTrue(controller.editMessage(secondUser.id, replacement: "replacement", in: threadID))
        // A header change made after the click belongs to the following turn;
        // fork and replacement turn must keep one frozen execution policy.
        controller.updateReviewMode(.denyAll, for: threadID)
        await fulfillment(of: [turnStarted], timeout: 2)
        await waitUntil("edit finishes") { !controller.isRewriting(threadID) }

        XCTAssertEqual(
            client.requests.map(\.method),
            ["thread/read", "thread/fork", "turn/start"]
        )
        let read = try XCTUnwrap(client.requests.first(where: { $0.method == "thread/read" }))
        XCTAssertEqual(read.params?["threadId"] as? String, "original-thread")
        XCTAssertEqual(read.params?["includeTurns"] as? Bool, true)
        let fork = try XCTUnwrap(client.requests.first(where: { $0.method == "thread/fork" }))
        XCTAssertEqual(fork.params?["threadId"] as? String, "original-thread")
        XCTAssertEqual(fork.params?["lastTurnId"] as? String, "turn-1")
        XCTAssertEqual(fork.params?["sandbox"] as? String, "danger-full-access")
        let turn = try XCTUnwrap(client.requests.first(where: { $0.method == "turn/start" }))
        let input = try XCTUnwrap(turn.params?["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, "replacement")
        XCTAssertNotNil(turn.params?["clientUserMessageId"] as? String)
        XCTAssertEqual(turn.params?["approvalPolicy"] as? String, "never")

        let rewritten = try XCTUnwrap(controller.store.state.threads.first(where: { $0.id == threadID }))
        XCTAssertEqual(rewritten.codexThreadID, "forked-thread")
        XCTAssertEqual(rewritten.codexThreadIDs, ["forked-thread", "original-thread"])
        XCTAssertEqual(rewritten.messages.map(\.text), ["first", "first answer", "replacement"])
        XCTAssertEqual(rewritten.messages.last?.turnID, "turn-replacement")
        XCTAssertEqual(rewritten.toolCalls.map(\.itemID), ["tool-1"])
        XCTAssertEqual(rewritten.reviewMode, .denyAll)
        XCTAssertNil(controller.toolOutput(for: "tool-2"))
    }

    func testFirstMessageEditStartsFreshThreadAndUpdatesTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        client.responseHandler = { method, _ in
            switch method {
            case "thread/start": return ["thread": ["id": "fresh-thread"]]
            case "turn/start": return ["turn": ["id": "fresh-turn"]]
            default: return client.defaultResponse(for: method)
            }
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        let original = ChatMessage(role: .user, text: "old title", turnID: "old-turn")
        let answer = ChatMessage(role: .assistant, text: "old answer", turnID: "old-turn")
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "old-thread"
            thread.status = .done
            thread.messages = [original, answer]
            thread.title = "old title"
        }

        let turnStarted = expectation(description: "fresh replacement turn starts")
        client.onTurnStart = { turnStarted.fulfill() }
        XCTAssertTrue(controller.editMessage(original.id, replacement: "new title", in: threadID))
        await fulfillment(of: [turnStarted], timeout: 2)
        await waitUntil("first-message edit finishes") { !controller.isRewriting(threadID) }
        await waitUntil("old server root is deleted") {
            client.requests.contains {
                $0.method == "thread/delete" && ($0.params?["threadId"] as? String) == "old-thread"
            }
        }

        XCTAssertEqual(client.requests.map(\.method), ["thread/start", "turn/start", "thread/delete"])
        let rewritten = try XCTUnwrap(controller.store.state.threads.first(where: { $0.id == threadID }))
        XCTAssertEqual(rewritten.codexThreadID, "fresh-thread")
        XCTAssertEqual(rewritten.title, "new title")
        XCTAssertEqual(rewritten.messages.map(\.text), ["new title"])
    }

    func testRegenerateUsesPrecedingUserPromptAndForksPriorTurn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        client.responseHandler = { method, _ in
            switch method {
            case "thread/read":
                return ["thread": ["turns": [["id": "turn-1"], ["id": "turn-2"]]]]
            case "thread/fork": return ["thread": ["id": "regenerated-thread"]]
            case "turn/start": return ["turn": ["id": "regenerated-turn"]]
            default: return client.defaultResponse(for: method)
            }
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        let firstUser = ChatMessage(role: .user, text: "first", turnID: "turn-1")
        let firstAnswer = ChatMessage(role: .assistant, text: "first answer", turnID: "turn-1")
        let secondUser = ChatMessage(role: .user, text: "second", turnID: "turn-2")
        let secondAnswer = ChatMessage(role: .assistant, text: "second answer", turnID: "turn-2")
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "original-thread"
            thread.status = .done
            thread.messages = [firstUser, firstAnswer, secondUser, secondAnswer]
        }

        let turnStarted = expectation(description: "regenerated turn starts")
        client.onTurnStart = { turnStarted.fulfill() }
        XCTAssertTrue(controller.regenerateResponse(secondAnswer.id, in: threadID))
        await fulfillment(of: [turnStarted], timeout: 2)
        await waitUntil("regenerate finishes") { !controller.isRewriting(threadID) }

        let turn = try XCTUnwrap(client.requests.first(where: { $0.method == "turn/start" }))
        let input = try XCTUnwrap(turn.params?["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, "second")
        let rewritten = try XCTUnwrap(controller.store.state.threads.first(where: { $0.id == threadID }))
        XCTAssertEqual(rewritten.messages.map(\.text), ["first", "first answer", "second"])
        XCTAssertEqual(rewritten.codexThreadIDs, ["regenerated-thread", "original-thread"])
    }

    func testRewriteRejectsEmptyWrongRoleMissingRunningAndUnreadyWithoutRequests() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        let user = ChatMessage(role: .user, text: "user", turnID: "turn-1")
        let assistant = ChatMessage(role: .assistant, text: "assistant", turnID: "turn-1")
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "thread"
            thread.status = .done
            thread.messages = [user, assistant]
        }
        let before = controller.store.state

        XCTAssertFalse(controller.editMessage(user.id, replacement: "   ", in: threadID))
        XCTAssertFalse(controller.editMessage(assistant.id, replacement: "changed", in: threadID))
        XCTAssertFalse(controller.regenerateResponse(user.id, in: threadID))
        XCTAssertFalse(controller.editMessage(UUID(), replacement: "changed", in: threadID))

        try controller.store.update(threadID) { $0.status = .running }
        XCTAssertFalse(controller.editMessage(user.id, replacement: "changed", in: threadID))
        try controller.store.update(threadID) { $0.status = .done }
        let unreadyController = try HarnessController(paths: fixture.paths)
        XCTAssertFalse(unreadyController.editMessage(user.id, replacement: "changed", in: threadID))

        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(controller.store.state.threads, before.threads)
    }

    func testForkFailureKeepsTranscriptAndBlocksConcurrentRewriteAndSend() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        client.responseHandler = { method, _ in
            if method == "thread/read" {
                throw HarnessError.serverError(code: -1, message: "fork preparation failed")
            }
            return client.defaultResponse(for: method)
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        let firstUser = ChatMessage(role: .user, text: "first", turnID: "turn-1")
        let firstAnswer = ChatMessage(role: .assistant, text: "first answer", turnID: "turn-1")
        let secondUser = ChatMessage(role: .user, text: "second", turnID: "turn-2")
        let secondAnswer = ChatMessage(role: .assistant, text: "second answer", turnID: "turn-2")
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "original-thread"
            thread.status = .done
            thread.messages = [firstUser, firstAnswer, secondUser, secondAnswer]
        }
        let before = controller.store.state

        XCTAssertTrue(controller.editMessage(secondUser.id, replacement: "replacement", in: threadID))
        XCTAssertTrue(controller.isRewriting(threadID))
        XCTAssertFalse(controller.regenerateResponse(secondAnswer.id, in: threadID))
        controller.send("must not race", in: threadID)

        await waitUntil("failed rewrite releases its guard") {
            !controller.isRewriting(threadID)
        }

        XCTAssertEqual(client.requests.map(\.method), ["thread/read"])
        XCTAssertEqual(controller.store.state, before)
        XCTAssertEqual(controller.lastError, "fork preparation failed")
    }

    func testTurnStartFailureAfterForkRestoresOriginalTranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        client.responseHandler = { method, _ in
            switch method {
            case "thread/read":
                return ["thread": ["turns": [["id": "turn-1"], ["id": "turn-2"]]]]
            case "thread/fork":
                return ["thread": ["id": "unused-fork"]]
            case "turn/start":
                throw HarnessError.serverError(code: -1, message: "replacement rejected")
            default:
                return client.defaultResponse(for: method)
            }
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        let firstUser = ChatMessage(role: .user, text: "first", turnID: "turn-1")
        let firstAnswer = ChatMessage(role: .assistant, text: "first answer", turnID: "turn-1")
        let secondUser = ChatMessage(role: .user, text: "second", turnID: "turn-2")
        let secondAnswer = ChatMessage(role: .assistant, text: "second answer", turnID: "turn-2")
        let removedCall = ToolCall(
            itemID: "tool-2",
            kind: .command,
            label: "removed",
            status: .succeeded,
            turnID: "turn-2"
        )
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "original-thread"
            thread.status = .done
            thread.messages = [firstUser, firstAnswer, secondUser, secondAnswer]
            thread.toolCalls = [removedCall]
        }
        controller.handleNotification([
            "method": "item/completed",
            "params": [
                "threadId": "original-thread",
                "turnId": "turn-2",
                "item": [
                    "id": "tool-2",
                    "type": "commandExecution",
                    "command": "removed",
                    "aggregatedOutput": "original output"
                ]
            ]
        ])
        let before = try XCTUnwrap(
            controller.store.state.threads.first(where: { $0.id == threadID })
        )

        XCTAssertTrue(controller.editMessage(secondUser.id, replacement: "replacement", in: threadID))
        await waitUntil("failed replacement restores its snapshot") {
            !controller.isRewriting(threadID)
        }
        await waitUntil("failed replacement server thread is deleted") {
            client.requests.contains(where: { $0.method == "thread/delete" })
        }

        let restored = try XCTUnwrap(
            controller.store.state.threads.first(where: { $0.id == threadID })
        )
        XCTAssertEqual(restored, before)
        XCTAssertEqual(controller.toolOutput(for: "tool-2"), "original output")
        XCTAssertEqual(
            client.requests.map(\.method),
            ["thread/read", "thread/fork", "turn/start", "thread/delete"]
        )
        XCTAssertEqual(controller.lastError, "replacement rejected")
    }

    func testSendClaimsThreadBeforeAsyncRequestsAndBlocksRewrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        let user = ChatMessage(role: .user, text: "existing", turnID: "turn-1")
        let answer = ChatMessage(role: .assistant, text: "answer", turnID: "turn-1")
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "original-thread"
            thread.status = .done
            thread.messages = [user, answer]
        }

        controller.send("first send", in: threadID)
        XCTAssertEqual(
            controller.store.state.threads.first(where: { $0.id == threadID })?.status,
            .running
        )

        // These calls happen before the Task scheduled by `send` can reach its
        // first request. Both must observe the synchronous running claim.
        controller.send("second send", in: threadID)
        XCTAssertFalse(controller.editMessage(user.id, replacement: "edited", in: threadID))

        await waitUntil("first send starts exactly one turn") {
            controller.store.state.threads
                .first(where: { $0.id == threadID })?.activeTurnID == "server-turn"
        }

        XCTAssertEqual(client.requests.map(\.method), ["thread/resume", "turn/start"])
        let thread = try XCTUnwrap(
            controller.store.state.threads.first(where: { $0.id == threadID })
        )
        XCTAssertEqual(thread.messages.map(\.text), ["existing", "answer", "first send"])
    }

    func testUnlinkedThreadScanPagesActiveAndArchivedAndSkipsRunningOrUnknown() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        client.responseHandler = { method, params in
            guard method == "thread/list" else { return client.defaultResponse(for: method) }
            let archived = params?["archived"] as? Bool ?? false
            if archived {
                return [
                    "data": [[
                        "id": "archived-old",
                        "updatedAt": NSNumber(value: 1),
                        "ephemeral": false,
                        "status": ["type": "idle"]
                    ]]
                ]
            }
            if params?["cursor"] as? String == "active-page-2" {
                return [
                    "data": [[
                        "id": "active-old-page-2",
                        "updatedAt": NSNumber(value: 1),
                        "ephemeral": false,
                        "status": ["type": "idle"]
                    ]]
                ]
            }
            return [
                "data": [
                    [
                        "id": "active-old",
                        "updatedAt": NSNumber(value: 1),
                        "ephemeral": false,
                        "status": ["type": "idle"]
                    ],
                    [
                        "id": "running-old",
                        "updatedAt": NSNumber(value: 1),
                        "ephemeral": false,
                        "status": ["type": "active"]
                    ],
                    [
                        "id": "unknown-old",
                        "updatedAt": NSNumber(value: 1),
                        "ephemeral": false
                    ],
                    [
                        "id": "linked-old",
                        "updatedAt": NSNumber(value: 1),
                        "ephemeral": false,
                        "status": ["type": "idle"]
                    ]
                ],
                "nextCursor": "active-page-2"
            ]
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let localThreadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        try controller.store.update(localThreadID) { $0.codexThreadID = "linked-old" }

        controller.scanUnlinkedCodexThreads()
        await waitUntil("unlinked scan finishes") {
            controller.unlinkedCodexThreadCount == 3
        }

        let listRequests = client.requests.filter { $0.method == "thread/list" }
        XCTAssertEqual(listRequests.count, 3)
        XCTAssertEqual(
            listRequests.compactMap { $0.params?["cursor"] as? String },
            ["active-page-2"]
        )
        XCTAssertTrue(listRequests.allSatisfy {
            ($0.params?["sourceKinds"] as? [String]) == ["appServer"]
        })
    }

    func testOrphanCleanupRechecksBothListsBeforeDeletingEligibleThreads() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let client = RecordingAppServerClient()
        client.responseHandler = { method, params in
            guard method == "thread/list" else { return client.defaultResponse(for: method) }
            let archived = params?["archived"] as? Bool ?? false
            return [
                "data": [[
                    "id": archived ? "archived-orphan" : "active-orphan",
                    "updatedAt": NSNumber(value: 1),
                    "ephemeral": false,
                    "status": ["type": "idle"]
                ]]
            ]
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)

        controller.scanUnlinkedCodexThreads()
        await waitUntil("orphan scan finishes") {
            controller.unlinkedCodexThreadCount == 2
        }
        controller.cleanupUnlinkedCodexThreads()
        await waitUntil("orphan deletion finishes") {
            controller.store.deletionTombstones.isEmpty
                && client.requests.filter { $0.method == "thread/delete" }.count == 2
        }

        XCTAssertEqual(client.requests.filter { $0.method == "thread/list" }.count, 4)
        XCTAssertEqual(
            Set(client.requests.filter { $0.method == "thread/delete" }
                .compactMap { $0.params?["threadId"] as? String }),
            ["active-orphan", "archived-orphan"]
        )
    }

    func testManualDeleteQueuesServerRootsAndClearsTombstoneOnSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let client = RecordingAppServerClient()
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        try controller.store.update(threadID) { thread in
            thread.codexThreadID = "root"
            thread.codexThreadID = "fork"
        }

        controller.deleteThread(threadID)
        await waitUntil("server roots are deleted") {
            client.requests.filter { $0.method == "thread/delete" }.count == 2
                && controller.store.deletionTombstones.isEmpty
        }

        XCTAssertFalse(controller.store.state.threads.contains(where: { $0.id == threadID }))
        XCTAssertEqual(
            client.requests.filter { $0.method == "thread/delete" }
                .compactMap { $0.params?["threadId"] as? String },
            ["fork", "root"]
        )
    }

    func testDeletionContinuesPastBlockedParentAndKeepsOnlyFailedRootForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let client = RecordingAppServerClient()
        client.responseHandler = { method, params in
            if method == "thread/delete", params?["threadId"] as? String == "parent" {
                throw HarnessError.serverError(
                    code: -32600,
                    message: "forked history still references it"
                )
            }
            return client.defaultResponse(for: method)
        }
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let threadID = try XCTUnwrap(controller.store.state.selectedThreadID)
        try controller.store.update(threadID) { thread in
            thread.codexThreadIDs = ["parent", "child"]
            thread.codexThreadID = "parent"
        }

        controller.deleteThread(threadID)
        await waitUntil("child is deleted while parent waits for retry") {
            client.requests.filter { $0.method == "thread/delete" }.count == 2
                && controller.store.deletionTombstones.first?.codexThreadIDs == ["parent"]
        }

        XCTAssertEqual(
            client.requests.filter { $0.method == "thread/delete" }
                .compactMap { $0.params?["threadId"] as? String },
            ["parent", "child"]
        )
        XCTAssertEqual(controller.store.deletionTombstones.first?.attemptCount, 1)
        XCTAssertNotNil(controller.store.deletionTombstones.first?.nextRetryAt)
    }

    func testReenablingCleanupRequiresConfirmationForExpiredConversations() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = try HarnessController(
            testPaths: fixture.paths,
            appServerClient: RecordingAppServerClient()
        )
        let now = Date()
        let thread = try controller.store.createThread(
            workingDirectory: "/tmp/expired",
            now: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        controller.setAutomaticCleanupEnabled(false)

        XCTAssertEqual(controller.expiredCandidateCount, 1)
        controller.requestAutomaticCleanupChange(true)
        XCTAssertFalse(controller.automaticCleanupEnabled)
        XCTAssertEqual(controller.pendingCleanupEnableCount, 1)

        controller.cancelAutomaticCleanupEnable()
        XCTAssertFalse(controller.automaticCleanupEnabled)
        controller.requestAutomaticCleanupChange(true)
        controller.confirmAutomaticCleanupEnable()
        await waitUntil("expired conversation is cleaned after confirmation") {
            !controller.store.state.threads.contains(where: { $0.id == thread.id })
        }
        XCTAssertTrue(controller.automaticCleanupEnabled)
        XCTAssertNil(controller.pendingCleanupEnableCount)
    }

    func testDeletingWhileThreadStartIsPendingDeletesLateServerRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let client = RecordingAppServerClient()
        client.deferThreadStart = true
        let controller = try HarnessController(testPaths: fixture.paths, appServerClient: client)
        let localID = try XCTUnwrap(controller.store.state.selectedThreadID)

        controller.send("will be deleted", in: localID)
        await waitUntil("thread/start is held") { client.threadStartPending }
        controller.deleteThread(localID)
        client.releaseThreadStart()

        await waitUntil("late server root is deleted") {
            controller.store.deletionTombstones.isEmpty && client.requests.contains {
                $0.method == "thread/delete"
                    && ($0.params?["threadId"] as? String) == "server-thread"
            }
        }
        XCTAssertTrue(controller.store.deletionTombstones.isEmpty)
        XCTAssertNil(controller.lastError)
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private final class RecordingAppServerClient: HarnessAppServerClient {
    typealias ResponseHandler = (
        _ method: String,
        _ params: CodexAppServerClient.JSONObject?
    ) throws -> CodexAppServerClient.JSONObject

    private struct Request {
        let method: String
        let params: CodexAppServerClient.JSONObject?
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var turnStartHandler: (() -> Void)?
    private var customResponseHandler: ResponseHandler?
    private var shouldDeferThreadStart = false
    private var deferredThreadStart: CheckedContinuation<CodexAppServerClient.JSONObject, Never>?
    private var isThreadStartPending = false

    var onNotification: CodexAppServerClient.NotificationHandler?
    var onTermination: CodexAppServerClient.TerminationHandler?

    var requests: [(method: String, params: CodexAppServerClient.JSONObject?)] {
        lock.withLock {
            recordedRequests.map { (method: $0.method, params: $0.params) }
        }
    }

    var onTurnStart: (() -> Void)? {
        get { lock.withLock { turnStartHandler } }
        set {
            lock.withLock {
                turnStartHandler = newValue
            }
        }
    }

    var responseHandler: ResponseHandler? {
        get { lock.withLock { customResponseHandler } }
        set { lock.withLock { customResponseHandler = newValue } }
    }

    var deferThreadStart: Bool {
        get { lock.withLock { shouldDeferThreadStart } }
        set { lock.withLock { shouldDeferThreadStart = newValue } }
    }

    var threadStartPending: Bool {
        lock.withLock { isThreadStartPending }
    }

    func releaseThreadStart() {
        let continuation = lock.withLock {
            isThreadStartPending = false
            let continuation = deferredThreadStart
            deferredThreadStart = nil
            return continuation
        }
        continuation?.resume(returning: ["thread": ["id": "server-thread"]])
    }

    func start() async throws {}

    func stop() {}

    func request(
        method: String,
        params: CodexAppServerClient.JSONObject?
    ) async throws -> CodexAppServerClient.JSONObject {
        let (callback, responseHandler): (() -> Void, ResponseHandler?) = lock.withLock {
            recordedRequests.append(Request(method: method, params: params))
            return (
                method == "turn/start" ? turnStartHandler ?? {} : {},
                customResponseHandler
            )
        }

        callback()
        if method == "thread/start", lock.withLock({ shouldDeferThreadStart }) {
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    isThreadStartPending = true
                    deferredThreadStart = continuation
                }
            }
        }
        if let responseHandler {
            return try responseHandler(method, params)
        }
        return defaultResponse(for: method)
    }

    func defaultResponse(for method: String) -> CodexAppServerClient.JSONObject {
        switch method {
        case "thread/start":
            return ["thread": ["id": "server-thread"]]
        case "turn/start":
            return ["turn": ["id": "server-turn"]]
        default:
            return [:]
        }
    }

    func sendNotification(
        method: String,
        params: CodexAppServerClient.JSONObject?
    ) throws {}
}

@MainActor
private struct Fixture {
    let root: URL
    let paths: HarnessPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BobbinHarnessControllerTests-\(UUID().uuidString)", isDirectory: true)
        paths = try HarnessPaths(root: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
