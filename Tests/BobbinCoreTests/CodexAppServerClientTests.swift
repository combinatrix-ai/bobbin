import Foundation
import XCTest
@testable import BobbinCore

@MainActor
final class CodexAppServerClientTests: XCTestCase {
    private func client(approval fixture: [String: Any]? = nil) throws -> CodexAppServerClient {
        let root = URL(fileURLWithPath: "/private/tmp/Bobbin-RPC-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server")
        let fixture = try fixture ?? nativeApprovalParameters()
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: fixture), as: UTF8.self)
        let source = """
        #!/usr/bin/python3
        import sys, json
        approval = json.loads(\(String(reflecting: payload)))
        waiting = None
        def emit(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get('method')
            if method == 'initialize':
                waiting = ('initialize', message['id'])
                emit({'id': message['id'], 'method': 'unsupported/request', 'params': {}})
            elif method == 'approval':
                waiting = ('approval', message['id'])
                emit({'id': str(message['id']), 'result': {'wrong': True}})
                emit({'id': message['id'], 'method': 'mcpServer/elicitation/request', 'params': approval})
            elif method == 'hang':
                emit({'method': 'hanging', 'params': {}})
            elif method == 'ping':
                emit({'id': message['id'], 'result': {'pong': True}})
            elif method is None and waiting:
                kind, ident = waiting
                waiting = None
                if kind == 'initialize':
                    emit({'id': ident, 'result': {'initialized': True}})
                else:
                    emit({'id': ident, 'result': message.get('result', {})})
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return try CodexAppServerClient(codexHome: root, executableURL: script)
    }

    func testMethodBearingIntegerCollisionAndStringResponseCannotStealContinuation() async throws {
        let client = try client()
        defer { client.stop() }
        client.onComputerUseApproval = { token, approval in
            XCTAssertEqual(approval.target, .nativeApp(identifier: "com.apple.calculator", name: "Calculator"))
            client.respond(to: token, decision: .allowForChat)
        }
        try await client.start()
        let response = try await client.request(method: "approval")
        XCTAssertEqual(response["action"] as? String, "accept")
        XCTAssertEqual(response["_meta"] as? [String: String], ["persist": "session"])
        XCTAssertNil(response["wrong"])
    }

    func testCapturedToolApprovalDispatchesAndReturnsSessionOnlyAllow() async throws {
        let parameters = try toolApprovalParameters()
        let code = ((parameters["_meta"] as! [String: Any])["tool_params"] as! [String: Any])["code"] as! String
        let client = try client(approval: parameters)
        defer { client.stop() }
        var received = false
        client.onComputerUseApproval = { token, approval in
            received = true
            XCTAssertEqual(approval.target, .toolExecution(code: code))
            client.respond(to: token, decision: .allowForChat)
        }
        try await client.start()
        let response = try await client.request(method: "approval")
        XCTAssertTrue(received)
        XCTAssertEqual(response["action"] as? String, "accept")
        XCTAssertEqual(response["_meta"] as? [String: String], ["persist": "session"])
        XCTAssertTrue((response["content"] as? [String: String])?.isEmpty == true)
    }

    func testStopSettlesOutstandingRequestAndRestartFencesLateApprovalResponse() async throws {
        let client = try client()
        defer { client.stop() }
        try await client.start()
        let waiting = expectation(description: "server has pending request")
        client.onNotification = { message in if message["method"] as? String == "hanging" { waiting.fulfill() } }
        let pending = Task { try await client.request(method: "hang") }
        await fulfillment(of: [waiting], timeout: 3)
        client.stop()
        do { _ = try await pending.value; XCTFail("Stopped requests must fail") } catch {}
        try await client.start()
        let stale = expectation(description: "native request pending")
        var oldToken: ServerRequestToken?
        client.onComputerUseApproval = { token, _ in oldToken = token; stale.fulfill() }
        let approval = Task { try await client.request(method: "approval") }
        await fulfillment(of: [stale], timeout: 3)
        client.stop()
        do { _ = try await approval.value; XCTFail("Stopped approvals must fail") } catch {}
        try await client.start()
        client.respond(to: try XCTUnwrap(oldToken), decision: .allowForChat)
        let response = try await client.request(method: "ping")
        XCTAssertEqual(response["pong"] as? Bool, true)
    }
}
