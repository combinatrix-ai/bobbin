import Foundation
import XCTest
@testable import BobbinCore

@MainActor
final class HarnessControllerTests: XCTestCase {
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
}

private final class RecordingAppServerClient: HarnessAppServerClient {
    private struct Request {
        let method: String
        let params: CodexAppServerClient.JSONObject?
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var turnStartHandler: (() -> Void)?

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

    func start() async throws {}

    func stop() {}

    func request(
        method: String,
        params: CodexAppServerClient.JSONObject?
    ) async throws -> CodexAppServerClient.JSONObject {
        let callback: (() -> Void)? = lock.withLock {
            recordedRequests.append(Request(method: method, params: params))
            return method == "turn/start" ? turnStartHandler : nil
        }

        callback?()

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
