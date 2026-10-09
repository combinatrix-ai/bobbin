import Foundation
import XCTest
@testable import BobbinCore

func nativeApprovalParameters() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "native-app-approval", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return try XCTUnwrap(fixture["params"] as? [String: Any])
}

final class ComputerUseApprovalTests: XCTestCase {
    func testExactNativeFixtureAndSessionOnlyResponse() throws {
        let approval = try XCTUnwrap(ComputerUseApproval(method: "mcpServer/elicitation/request", params: nativeApprovalParameters()))
        XCTAssertEqual(approval.appIdentifier, "com.apple.calculator")
        XCTAssertEqual(approval.appName, "Calculator")
        XCTAssertNil(approval.turnID)
        let accepted = ComputerUseDecision.allowForChat.result
        XCTAssertEqual(accepted["action"] as? String, "accept")
        XCTAssertEqual(accepted["_meta"] as? [String: String], ["persist": "session"])
        XCTAssertTrue((accepted["content"] as? [String: String])?.isEmpty == true)
        XCTAssertEqual(ComputerUseDecision.decline.result["action"] as? String, "decline")
        XCTAssertEqual(ComputerUseDecision.cancel.result["action"] as? String, "cancel")
    }

    func testUnsupportedRequestsCannotBecomeAppApproval() throws {
        let original = try nativeApprovalParameters()
        for field in ["serverName", "mode", "requestedSchema", "_meta", "threadId"] {
            var invalid = original
            invalid[field] = NSNull()
            XCTAssertNil(ComputerUseApproval(method: "mcpServer/elicitation/request", params: invalid), field)
        }
        for schema: [String: Any] in [
            ["type": "object", "properties": ["choice": ["type": "string"]]],
            ["type": "object", "properties": [:], "required": ["app"]],
            ["type": "object", "properties": [:], "additionalProperties": true],
            ["type": "object", "properties": [:], "anyOf": []]
        ] {
            var invalid = original; invalid["requestedSchema"] = schema
            XCTAssertNil(ComputerUseApproval(method: "mcpServer/elicitation/request", params: invalid))
        }
        var audio = original
        var meta = audio["_meta"] as! [String: Any]
        meta["tool_params"] = [String: Any]()
        audio["_meta"] = meta
        XCTAssertNil(ComputerUseApproval(method: "mcpServer/elicitation/request", params: audio))
        var warning = original; warning["mode"] = "openai/form"
        meta = original["_meta"] as! [String: Any]; meta["subtitle"] = "This app can access private files."
        warning["_meta"] = meta
        XCTAssertEqual(ComputerUseApproval(method: "mcpServer/elicitation/request", params: warning)?.subtitle, "This app can access private files.")
    }

    func testRPCIDsKeepKindsAndRejectInvalidJSONTypes() throws {
        let values = try JSONSerialization.jsonObject(with: Data("[1,\"1\",true,1.5,null]".utf8)) as! [Any]
        XCTAssertEqual(RPCID(values[0]), .integer(1))
        XCTAssertEqual(RPCID(values[1]), .string("1"))
        for value in values.dropFirst(2) { XCTAssertNil(RPCID(value)) }
        XCTAssertNotEqual(RPCID(values[0]), RPCID(values[1]))
    }
}

final class ComputerUseRecordingClient: HarnessAppServerClient {
    var onNotification: CodexAppServerClient.NotificationHandler?
    var onTermination: CodexAppServerClient.TerminationHandler?
    var onComputerUseApproval: CodexAppServerClient.ApprovalHandler?
    var decisions: [(ServerRequestToken, ComputerUseDecision)] = []
    var requests: [(String, [String: Any]?)] = []
    var reply: (String, [String: Any]?) throws -> [String: Any] = { _, _ in [:] }
    func start() async throws {}
    func stop() {}
    func sendNotification(method: String, params: [String: Any]?) throws {}
    func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
        requests.append((method, params))
        return try reply(method, params)
    }
    func respond(to token: ServerRequestToken, decision: ComputerUseDecision) { decisions.append((token, decision)) }
}

@MainActor
final class ComputerUseControllerTests: XCTestCase {
    private func setupController() throws -> (HarnessController, ComputerUseRecordingClient) {
        let paths = try HarnessPaths(root: URL(fileURLWithPath: "/private/tmp/Bobbin-CU-test-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        let client = ComputerUseRecordingClient()
        let controller = try HarnessController(testPaths: paths, appServerClient: client)
        let id = try XCTUnwrap(controller.selectedThread?.id)
        try controller.store.update(id) { $0.codexThreadID = "server-thread"; $0.activeTurnID = "turn-1"; $0.status = .running }
        return (controller, client)
    }

    private func approval(thread: String = "server-thread", turn: String? = nil) throws -> ComputerUseApproval {
        var params = try nativeApprovalParameters()
        params["threadId"] = thread
        params["turnId"] = turn as Any? ?? NSNull()
        return try XCTUnwrap(ComputerUseApproval(method: "mcpServer/elicitation/request", params: params))
    }

    private func token(_ id: Int64 = 0) -> ServerRequestToken {
        ServerRequestToken(generation: UUID(), id: .integer(id), nonce: UUID())
    }

    func testApprovalBelongsToRunningChatAndDoesNotFollowSelection() throws {
        let (controller, client) = try setupController()
        let owner = try XCTUnwrap(controller.selectedThread?.id)
        let request = token()
        controller.receiveComputerUseApproval(request, approval: try approval())
        controller.createThread()
        XCTAssertNil(controller.pendingComputerUseApproval(for: try XCTUnwrap(controller.selectedThread?.id)))
        let pending = try XCTUnwrap(controller.pendingComputerUseApproval(for: owner))
        controller.resolveComputerUseApproval(pending.id, decision: .allowForChat)
        controller.resolveComputerUseApproval(pending.id, decision: .allowForChat)
        XCTAssertEqual(client.decisions.count, 1)
        XCTAssertEqual(client.decisions.first?.1, .allowForChat)
        XCTAssertEqual(client.decisions.first?.0, request)
    }

    func testUnknownThreadAndMismatchedTurnDecline() throws {
        let (controller, client) = try setupController()
        controller.receiveComputerUseApproval(token(), approval: try approval(thread: "other"))
        controller.receiveComputerUseApproval(token(), approval: try approval(turn: "old-turn"))
        XCTAssertEqual(client.decisions.map(\.1), [.decline, .decline])
        XCTAssertTrue(controller.computerUseApprovals.isEmpty)
    }

    func testCompletionStopResolvedAndExpirySettleOnce() throws {
        for event in ["complete", "stop", "resolved", "expire", "terminate", "delete"] {
            let (controller, client) = try setupController()
            let request = token()
            controller.receiveComputerUseApproval(request, approval: try approval())
            let pending = try XCTUnwrap(controller.computerUseApprovals.first)
            switch event {
            case "complete": controller.handleNotification(["method": "turn/completed", "params": ["threadId": "server-thread", "turn": ["id": "turn-1", "status": "completed"]]])
            case "stop": controller.stopThread(pending.localThreadID)
            case "resolved": controller.handleNotification(["method": "serverRequest/resolved", "params": ["threadId": "server-thread", "requestId": 0]])
            case "expire": controller.resolveComputerUseApproval(pending.id, decision: .allowForChat, now: Date().addingTimeInterval(301))
            case "terminate": client.onTermination?(ComputerUseError("Exited"))
            case "delete": controller.deleteThread(pending.localThreadID)
            default: XCTFail()
            }
            controller.resolveComputerUseApproval(pending.id, decision: .allowForChat)
            XCTAssertTrue(controller.computerUseApprovals.isEmpty, event)
            XCTAssertEqual(client.decisions.map(\.1), event == "resolved" ? [] : [.cancel], event)
        }
    }

    func testTurnReplacementCancelsLateAllowAndReusedRPCIDCannotUseOldUIAnswer() throws {
        let (controller, client) = try setupController()
        controller.receiveComputerUseApproval(token(), approval: try approval())
        let old = try XCTUnwrap(controller.computerUseApprovals.first)
        try controller.store.update(old.localThreadID) { $0.activeTurnID = "turn-2" }
        controller.resolveComputerUseApproval(old.id, decision: .allowForChat)
        controller.receiveComputerUseApproval(token(), approval: try approval(turn: "turn-2"))
        controller.resolveComputerUseApproval(old.id, decision: .allowForChat)
        XCTAssertEqual(client.decisions.map(\.1), [.cancel])
        XCTAssertEqual(controller.computerUseApprovals.count, 1)
    }

    func testDemoApprovalNeverOwnsProductionClient() throws {
        let paths = try HarnessPaths.demo()
        defer { paths.removeDemoRoot() }
        let store = try ThreadStore(paths: paths)
        _ = try store.createThread(workingDirectory: "/demo")
        let controller = try HarnessController(demoPaths: paths, fixture: nil)
        controller.showDemoComputerUseApproval()
        controller.boot()
        controller.restart()
        XCTAssertEqual(controller.computerUseApprovals.count, 1)
        controller.resolveComputerUseApproval(try XCTUnwrap(controller.computerUseApprovals.first?.id), decision: .decline)
        XCTAssertTrue(controller.computerUseApprovals.isEmpty)
        XCTAssertTrue(RuntimeOptions.fromProcess(arguments: ["Bobbin", "--demo-computer-use"], environment: [:]).demoMode)
    }
}
