import Foundation
import XCTest
@testable import BobbinCore

@MainActor
final class ComputerUseNativeSmokeTests: XCTestCase {
    func testInstalledDesktopWithoutModelOrCopiedCredentials() async throws {
        guard ProcessInfo.processInfo.environment["BOBBIN_NATIVE_COMPUTER_USE_SMOKE"] == "1" else {
            throw XCTSkip("Opt in with BOBBIN_NATIVE_COMPUTER_USE_SMOKE=1 on a Mac with the OpenAI desktop app installed.")
        }
        let paths = try HarnessPaths(root: URL(fileURLWithPath: "/private/tmp/Bobbin-Native-Smoke-" + UUID().uuidString))
        try paths.prepare()
        let runtime = await ComputerUseRuntime.discover()
        let source = try XCTUnwrap(runtime.source, runtime.initialState.settingsLabel)
        try source.assertCurrent()
        let client = try CodexAppServerClient(codexHome: paths.codexHome, executableURL: source.executable)
        defer { client.stop() }
        try await client.start()
        let state = await runtime.prepare(using: client, home: paths.codexHome)
        XCTAssertEqual(state, .ready)
        guard state == .ready else { return }
        let thread = try await client.request(method: "thread/start", params: ["ephemeral": true, "developerInstructions": "Bobbin native connection check. No model turn is requested."])
        let threadID = try XCTUnwrap((thread["thread"] as? [String: Any])?["id"] as? String)
        let list = try await client.request(method: "mcpServer/tool/call", params: ["threadId": threadID, "server": "cua_repl", "tool": "js", "arguments": ["code": "await cua.listApps();"]])
        XCTAssertNotEqual(list["isError"] as? Bool, true)
        let declined = expectation(description: "native Calculator prompt explicitly declined")
        client.onComputerUseApproval = { token, approval in
            XCTAssertEqual(approval.threadID, threadID)
            XCTAssertEqual(approval.appIdentifier, "com.apple.calculator")
            client.respond(to: token, decision: .decline)
            declined.fulfill()
        }
        let app = try await client.request(method: "mcpServer/tool/call", params: ["threadId": threadID, "server": "cua_repl", "tool": "js", "arguments": ["code": "let smokeApp = await cua.getApp(\"/System/Applications/Calculator.app\");"]])
        await fulfillment(of: [declined], timeout: 5)
        XCTAssertEqual(app["isError"] as? Bool, true)
        let text = (app["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        XCTAssertTrue(text.contains("not approved"))
        _ = try await client.request(method: "thread/unsubscribe", params: ["threadId": threadID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexHome.appendingPathComponent("auth.json").path))
        print("Native smoke passed. Isolated home: \(paths.codexHome.path). No model turn or credential copy.")
    }
}
