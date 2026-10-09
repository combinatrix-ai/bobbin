import Foundation
import XCTest
@testable import BobbinCore

private struct FixtureSignatureInspector: ComputerUseSignatureInspecting {
    func inspect(_ bundle: URL, identifier: String?) throws -> SignedBundleIdentity {
        let signature = try String(contentsOf: bundle.appendingPathComponent("signature"), encoding: .utf8)
        guard signature.hasPrefix("signed-") else { throw ComputerUseError("Invalid fixture signature") }
        return SignedBundleIdentity(codeHash: signature, version: "1", build: "1")
    }
}

private struct StageRejectingInspector: ComputerUseSignatureInspecting {
    func inspect(_ bundle: URL, identifier: String?) throws -> SignedBundleIdentity {
        if bundle.path.contains("-stage-") { throw ComputerUseError("Invalid staged signature") }
        return try FixtureSignatureInspector().inspect(bundle, identifier: identifier)
    }
}

private final class PausingStageInspector: ComputerUseSignatureInspecting, @unchecked Sendable {
    let reachedStage: XCTestExpectation
    let resume = DispatchSemaphore(value: 0)

    init(reachedStage: XCTestExpectation) { self.reachedStage = reachedStage }

    func inspect(_ bundle: URL, identifier: String?) throws -> SignedBundleIdentity {
        if bundle.path.contains("-stage-") && identifier == "com.openai.sky.CUAService" {
            reachedStage.fulfill()
            guard resume.wait(timeout: .now() + 5) == .success else { throw ComputerUseError("Stage test timed out") }
        }
        return try FixtureSignatureInspector().inspect(bundle, identifier: identifier)
    }
}

private final class RuntimeFixture {
    let root = URL(fileURLWithPath: "/private/tmp/Bobbin-CU-runtime-" + UUID().uuidString)
    let service = ComputerUseService(inspector: FixtureSignatureInspector())
    var home: URL { root.appendingPathComponent("home") }
    var resources: URL { root.appendingPathComponent("Desktop.app/Contents/Resources") }
    var serviceURL: URL { resources.appendingPathComponent("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app") }
    var marketplace: URL { home.appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled") }

    init() throws {
        _ = try OwnedComputerUseDirectory(home, create: true)
        try file("cua_node/bin/node", "node")
        try file("cua_node/bin/node_repl", "repl")
        try file("codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex")
        try file("cua_node/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs", "launcher")
        try file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-1")
        try file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/signature", "signed-client-1")
        try file("../Info.plist", "desktop")
        try file("plugins/openai-bundled/.agents/plugins/marketplace.json", """
        {"name":"openai-bundled","plugins":[{"name":"unified-computer-use","source":"./plugins/unified-computer-use"},{"name":"other","source":"./plugins/other"}]}
        """)
        try file("plugins/openai-bundled/plugins/unified-computer-use/.codex-plugin/plugin.json", """
        {"name":"unified-computer-use","mcpServers":"./.mcp.json","hooks":{"Stop":[]}}
        """)
        try file("plugins/openai-bundled/plugins/unified-computer-use/.mcp.json", """
        {"mcpServers":{"cua_repl":{"command":"node","enabled":false,"enabled_tools":["js","js_reset","turn_ended"]}}}
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: resources.appendingPathComponent("plugins/openai-bundled/plugins/unified-computer-use/.mcp.json").path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ relative: String, _ content: String) throws {
        let url = resources.appendingPathComponent(relative).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func source() throws -> DesktopComputerUseSource {
        try DesktopComputerUseSource(resources: resources, fingerprint: DesktopComputerUseSource.fingerprint(resources), serviceIdentity: service.inspector.inspect(serviceURL, identifier: nil), clientIdentity: service.inspector.inspect(serviceURL.appendingPathComponent(ComputerUseService.clientPath), identifier: nil))
    }
}

final class ComputerUseRuntimeTests: XCTestCase {
    func testEffectivePolicyVetoesDoNotWriteOrEnableAnything() async throws {
        let fixture = try RuntimeFixture()
        let runtime = try ComputerUseRuntime(source: fixture.source(), initialState: .ready, service: fixture.service)
        let policies: [[String: Any]] = [
            ["features": ["plugins": false]],
            ["plugins": ["computer-use@openai-bundled": ["enabled": false]]],
            ["plugins": ["unified-computer-use@openai-bundled": ["enabled": false]]],
            ["plugins": ["unified-computer-use@openai-bundled": ["mcp_servers": ["cua_repl": ["disabled_tools": ["js"]]]]]],
            ["mcp_servers": ["computer-use": ["enabled": true]]],
            ["mcp_servers": ["cua_repl": ["enabled": false]]],
            ["mcp_servers": ["cua_repl": ["enabled_tools": ["js_reset"]]]]
        ]
        for policy in policies {
            let client = ComputerUseRecordingClient()
            client.reply = { _, _ in ["config": policy] }
            let result = await runtime.prepare(using: client, home: fixture.home)
            guard case .disabled = result else { return XCTFail("Expected disabled, got \(result)") }
            XCTAssertEqual(client.requests.map(\.0), ["config/read"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), [])
        }
    }

    func testSinglePluginTemplateNoopAndSignedUpdate() throws {
        let fixture = try RuntimeFixture()
        let source = try fixture.source()
        let installation = try fixture.service.prepare(source: source, home: fixture.home)
        let marketplace = installation.marketplace
        try installation.commit()
        let manifest = try ComputerUseService.object(marketplace.appendingPathComponent(".agents/plugins/marketplace.json"))
        XCTAssertEqual((manifest["plugins"] as? [[String: Any]])?.count, 1)
        let plugin = marketplace.appendingPathComponent("plugins/unified-computer-use")
        let mcp = try ComputerUseService.object(plugin.appendingPathComponent(".mcp.json"))
        let server = try XCTUnwrap((mcp["mcpServers"] as? [String: [String: Any]])?["cua_repl"])
        XCTAssertEqual(server["enabled_tools"] as? [String], ["js", "js_reset", "turn_ended"])
        let env = try XCTUnwrap(server["env"] as? [String: String])
        XCTAssertEqual(env["CUA_REPL_ENABLED_SURFACES"], "computer")
        XCTAssertEqual(env["CODEX_HOME"], fixture.home.path)
        XCTAssertNil(env["CUA_BROWSER_BRIDGE_URL"])
        let mode = try FileManager.default.attributesOfItem(atPath: plugin.appendingPathComponent(".mcp.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let target = fixture.home.appendingPathComponent("computer-use")
        let oldInode = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? UInt64
        try fixture.service.prepare(source: source, home: fixture.home).commit()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? UInt64, oldInode)
        try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-2")
        try fixture.service.prepare(source: fixture.source(), home: fixture.home).commit()
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Codex Computer Use.app/signature")), "signed-service-2")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).contains { $0.contains("stage-") })
    }

    func testStageSignatureFailureAndConcurrentPreparationDoNotPublish() throws {
        let fixture = try RuntimeFixture()
        let service = ComputerUseService(inspector: StageRejectingInspector())
        XCTAssertThrowsError(try service.prepare(source: fixture.source(), home: fixture.home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("computer-use").path))
        let lock = try ComputerUsePreparationLock(home: fixture.home)
        defer { withExtendedLifetime(lock) {} }
        XCTAssertThrowsError(try fixture.service.prepare(source: fixture.source(), home: fixture.home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("computer-use").path))
    }

    func testCancelledProvisioningCannotPublishLate() async throws {
        let fixture = try RuntimeFixture()
        let reachedStage = expectation(description: "source copied to staging")
        let inspector = PausingStageInspector(reachedStage: reachedStage)
        let service = ComputerUseService(inspector: inspector)
        let source = try fixture.source()
        let home = fixture.home
        let task = Task.detached { try service.prepare(source: source, home: home) }
        await fulfillment(of: [reachedStage], timeout: 3)
        task.cancel()
        inspector.resume.signal()
        do { _ = try await task.value; XCTFail("Cancelled preparation must fail") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("computer-use").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: home.path).contains { $0.contains("stage-") })
    }

    func testWrapperFailureRestoresPreviousNativeService() throws {
        let fixture = try RuntimeFixture()
        try fixture.service.prepare(source: fixture.source(), home: fixture.home).commit()
        try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-2")
        try fixture.file("plugins/openai-bundled/plugins/unified-computer-use/.codex-plugin/plugin.json", "{\"name\":\"unexpected-plugin\"}")
        XCTAssertThrowsError(try fixture.service.prepare(source: fixture.source(), home: fixture.home))
        XCTAssertEqual(try String(contentsOf: fixture.home.appendingPathComponent("computer-use/Codex Computer Use.app/signature")), "signed-service-1")
        let manifest = try ComputerUseService.object(fixture.marketplace.appendingPathComponent("plugins/unified-computer-use/.codex-plugin/plugin.json"))
        XCTAssertEqual(manifest["name"] as? String, "unified-computer-use")
    }

    func testSourceChangeInvalidSignatureAndUnownedTargetAreRejected() throws {
        let fixture = try RuntimeFixture()
        let old = try fixture.source()
        try fixture.file("cua_node/bin/node", "updated node")
        XCTAssertThrowsError(try fixture.service.prepare(source: old, home: fixture.home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("computer-use").path))
        try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "unsigned")
        XCTAssertThrowsError(try fixture.source())
        try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-1")
        let unowned = fixture.home.appendingPathComponent("computer-use")
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: unowned.appendingPathComponent("user-file"))
        XCTAssertThrowsError(try fixture.service.prepare(source: fixture.source(), home: fixture.home))
        XCTAssertEqual(try String(contentsOf: unowned.appendingPathComponent("user-file")), "untouched")
    }

    func testAtomicPublicationRollsBackWhenFinalVerificationFails() throws {
        let fixture = try RuntimeFixture()
        let parent = try OwnedComputerUseDirectory(fixture.home)
        func build(_ value: String) -> (URL) throws -> Void {
            { try Data(value.utf8).write(to: $0.appendingPathComponent("payload")) }
        }
        try fixture.service.publish(parent: parent, name: "sample", fingerprint: "old", build: build("old"), validate: { _ in }, current: {}).commit()
        XCTAssertThrowsError(try fixture.service.publish(parent: parent, name: "sample", fingerprint: "new", build: build("new"), validate: { url in
            if url.lastPathComponent == "sample" { throw ComputerUseError("Final signature mismatch") }
        }, current: {}))
        XCTAssertEqual(try String(contentsOf: fixture.home.appendingPathComponent("sample/payload")), "old")
    }

    func testDestinationEditedDuringStagingIsPreserved() throws {
        let fixture = try RuntimeFixture()
        let parent = try OwnedComputerUseDirectory(fixture.home)
        let targetFile = fixture.home.appendingPathComponent("sample/payload")
        try fixture.service.publish(parent: parent, name: "sample", fingerprint: "old", build: {
            try Data("original".utf8).write(to: $0.appendingPathComponent("payload"))
        }, validate: { _ in }, current: {}).commit()
        XCTAssertThrowsError(try fixture.service.publish(parent: parent, name: "sample", fingerprint: "new", build: {
            try Data("new".utf8).write(to: $0.appendingPathComponent("payload"))
            try Data("user edit".utf8).write(to: targetFile)
        }, validate: { _ in }, current: {}))
        XCTAssertEqual(try String(contentsOf: targetFile), "user edit")
    }

    func testSymlinkedHomeConfigAndOwnedAncestorNeverWriteOutside() throws {
        let fixture = try RuntimeFixture()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let redirected = fixture.root.appendingPathComponent("redirected")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: outside)
        XCTAssertThrowsError(try HarnessPaths(root: redirected.appendingPathComponent("Bobbin")).prepare())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent("config.toml"), withDestinationURL: outside.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try fixture.service.prepare(source: fixture.source(), home: fixture.home))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("config.toml"))
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent(".tmp"), withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.service.prepare(source: fixture.source(), home: fixture.home))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testOwnedMarketplaceManifestRPCAndStatusPagination() async throws {
        let fixture = try RuntimeFixture()
        let client = ComputerUseRecordingClient()
        let manifest = fixture.marketplace.appendingPathComponent(".agents/plugins/marketplace.json").path
        client.reply = { method, params in
            switch method {
            case "config/read": return ["config": [:]]
            case "plugin/list": return ["marketplaces": [["name": "openai-bundled", "path": manifest, "plugins": [["name": "unified-computer-use"]]]]]
            case "mcpServerStatus/list":
                if params?["cursor"] as? String == "next" { return ["data": [["name": "cua_repl", "tools": ["js": [:]]]]] }
                return ["data": [["name": "other", "tools": [:]]], "nextCursor": "next"]
            default: return [:]
            }
        }
        let runtime = try ComputerUseRuntime(source: fixture.source(), initialState: .ready, service: fixture.service)
        let state = await runtime.prepare(using: client, home: fixture.home)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(client.requests.first { $0.0 == "marketplace/add" }?.1?["source"] as? String, fixture.marketplace.path)
        for method in ["plugin/read", "plugin/install"] {
            XCTAssertEqual(client.requests.first { $0.0 == method }?.1?["marketplacePath"] as? String, manifest)
        }
        XCTAssertEqual(client.requests.filter { $0.0 == "mcpServerStatus/list" }.count, 2)
    }

    private func successfulReply(fixture: RuntimeFixture, method: String) -> [String: Any] {
        switch method {
        case "config/read": return ["config": [:]]
        case "plugin/list":
            return ["marketplaces": [[
                "name": "openai-bundled",
                "path": fixture.marketplace.appendingPathComponent(".agents/plugins/marketplace.json").path,
                "plugins": [["name": "unified-computer-use"]]
            ]]]
        case "mcpServerStatus/list": return ["data": [["name": "cua_repl", "tools": ["js": [:]]]]]
        default: return [:]
        }
    }

    private func installationDigest(_ fixture: RuntimeFixture) throws -> String {
        try ComputerUseService.digest([fixture.home.appendingPathComponent("computer-use"), fixture.marketplace])
    }

    func testInstallAndReadinessFailuresRestorePriorGeneration() async throws {
        for failure in ["plugin/install", "config/mcpServer/reload", "mcpServerStatus/list"] {
            let fixture = try RuntimeFixture()
            try fixture.service.prepare(source: fixture.source(), home: fixture.home).commit()
            let original = try installationDigest(fixture)
            try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-2")
            let client = ComputerUseRecordingClient()
            var observedNewService = false
            client.reply = { method, _ in
                if method == failure {
                    observedNewService = try String(contentsOf: fixture.home.appendingPathComponent("computer-use/Codex Computer Use.app/signature")) == "signed-service-2"
                    if failure == "mcpServerStatus/list" { return ["data": []] }
                    throw ComputerUseError("Injected " + failure + " failure")
                }
                return self.successfulReply(fixture: fixture, method: method)
            }
            let runtime = try ComputerUseRuntime(source: fixture.source(), initialState: .ready, service: fixture.service)
            let state = await runtime.prepare(using: client, home: fixture.home)
            guard case .failed = state else { return XCTFail("Expected failure for " + failure) }
            XCTAssertTrue(observedNewService, failure)
            XCTAssertEqual(try installationDigest(fixture), original, failure)
        }
    }

    func testSourceChangeDuringRPCPreparationRestoresPriorGeneration() async throws {
        for changeAt in ["plugin/read", "mcpServerStatus/list"] {
            let fixture = try RuntimeFixture()
            try fixture.service.prepare(source: fixture.source(), home: fixture.home).commit()
            let original = try installationDigest(fixture)
            try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-2")
            let client = ComputerUseRecordingClient()
            client.reply = { method, _ in
                if method == changeAt { try fixture.file("cua_node/bin/node", "Desktop updated during RPC preparation") }
                return self.successfulReply(fixture: fixture, method: method)
            }
            let runtime = try ComputerUseRuntime(source: fixture.source(), initialState: .ready, service: fixture.service)
            let state = await runtime.prepare(using: client, home: fixture.home)
            guard case .failed = state else { return XCTFail("Expected source-change failure") }
            XCTAssertEqual(try installationDigest(fixture), original, changeAt)
        }
    }

    func testFinalPolicyVetoAndCancellationRestorePriorGeneration() async throws {
        for reason in ["policy", "cancellation"] {
            let fixture = try RuntimeFixture()
            try fixture.service.prepare(source: fixture.source(), home: fixture.home).commit()
            let original = try installationDigest(fixture)
            try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-2")
            let client = ComputerUseRecordingClient()
            var reads = 0
            client.reply = { method, _ in
                if method == "config/read" {
                    reads += 1
                    if reason == "policy" && reads == 4 { return ["config": ["features": ["plugins": false]]] }
                }
                if reason == "cancellation" && method == "mcpServerStatus/list" {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return self.successfulReply(fixture: fixture, method: method)
            }
            let runtime = try ComputerUseRuntime(source: fixture.source(), initialState: .ready, service: fixture.service)
            let task = Task { await runtime.prepare(using: client, home: fixture.home) }
            let state = await task.value
            if reason == "policy" {
                guard case .disabled = state else { return XCTFail("Expected final policy veto") }
            } else {
                guard case .failed = state else { return XCTFail("Expected cancellation") }
            }
            XCTAssertEqual(try installationDigest(fixture), original, reason)
        }
    }

    func testPublicationCleanupRefusesEditedOrReplacedDestinationAndBackup() throws {
        for changedSide in ["destination", "backup"] {
            for change in ["payload", "receipt", "receipt-content", "replacement", "symlink"] {
                let fixture = try RuntimeFixture()
                let parent = try OwnedComputerUseDirectory(fixture.home)
                let old = try fixture.service.publish(parent: parent, name: "sample", fingerprint: "old", build: {
                    try Data("old".utf8).write(to: $0.appendingPathComponent("payload"))
                }, validate: { _ in }, current: {})
                try old.commit()
                let pending = try fixture.service.publish(parent: parent, name: "sample", fingerprint: "new", build: {
                    try Data("new".utf8).write(to: $0.appendingPathComponent("payload"))
                }, validate: { _ in }, current: {})
                let backupName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.home.path).first { $0.hasPrefix(".sample-stage-") })
                let changed = fixture.home.appendingPathComponent(changedSide == "destination" ? "sample" : backupName)
                switch change {
                case "payload":
                    try Data("external edit".utf8).write(to: changed.appendingPathComponent("payload"))
                case "receipt":
                    let receipt = changed.appendingPathComponent(ComputerUseService.ownerFile)
                    let data = try Data(contentsOf: receipt)
                    try data.write(to: receipt, options: .atomic)
                case "receipt-content":
                    let receipt = changed.appendingPathComponent(ComputerUseService.ownerFile)
                    let handle = try FileHandle(forWritingTo: receipt)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0x0A]))
                    try handle.close()
                case "replacement", "symlink":
                    let parked = fixture.home.appendingPathComponent("external-original")
                    try FileManager.default.moveItem(at: changed, to: parked)
                    if change == "replacement" { try FileManager.default.copyItem(at: parked, to: changed) }
                    else { try FileManager.default.createSymbolicLink(at: changed, withDestinationURL: parked) }
                default: XCTFail("Unexpected mutation")
                }
                let edited = try ComputerUseService.digest([fixture.home])
                XCTAssertThrowsError(try pending.rollback(), changedSide + " " + change)
                XCTAssertEqual(try ComputerUseService.digest([fixture.home]), edited)
                XCTAssertThrowsError(try pending.commit(), changedSide + " " + change)
                XCTAssertEqual(try ComputerUseService.digest([fixture.home]), edited)
            }
        }
    }

    func testGroupedRollbackAndCommitPreflightBothPublicationsBeforeTouchingEither() throws {
        for action in ["rollback", "commit"] {
            let fixture = try RuntimeFixture()
            try fixture.service.prepare(source: fixture.source(), home: fixture.home).commit()
            try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-2")
            let pending = try fixture.service.prepare(source: fixture.source(), home: fixture.home)
            let parent = fixture.marketplace.deletingLastPathComponent()
            let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: parent.path).first { $0.hasPrefix(".openai-bundled-stage-") })
            try Data("external edit".utf8).write(to: parent.appendingPathComponent(backup).appendingPathComponent("external-file"))
            let edited = try ComputerUseService.digest([fixture.home])
            if action == "rollback" { XCTAssertThrowsError(try pending.rollback()) }
            else { XCTAssertThrowsError(try pending.commit()) }
            XCTAssertEqual(try ComputerUseService.digest([fixture.home]), edited, action)
        }
    }

    func testFailureOrChangeBetweenBackupCleanupsKeepsNewGenerationActive() throws {
        for change in ["failure", "edit", "replacement"] {
            let fixture = try RuntimeFixture()
            try fixture.service.prepare(source: fixture.source(), home: fixture.home).commit()
            try fixture.file("cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/signature", "signed-service-2")
            let pending = try fixture.service.prepare(source: fixture.source(), home: fixture.home)
            let newGeneration = try installationDigest(fixture)
            let serviceBackupName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.home.path).first { $0.hasPrefix(".computer-use-stage-") })
            let serviceBackup = fixture.home.appendingPathComponent(serviceBackupName)
            let marketplaceParent = fixture.marketplace.deletingLastPathComponent()
            let marketplaceBackupName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: marketplaceParent.path).first { $0.hasPrefix(".openai-bundled-stage-") })
            let marketplaceBackup = marketplaceParent.appendingPathComponent(marketplaceBackupName)
            let parked = marketplaceParent.appendingPathComponent("external-original")
            var reachedSecondCleanup = false
            XCTAssertNoThrow(try pending.commit { index in
                guard index == 1 else { return }
                reachedSecondCleanup = true
                XCTAssertFalse(FileManager.default.fileExists(atPath: serviceBackup.path))
                switch change {
                case "failure": throw ComputerUseError("Injected cleanup failure after the first backup was removed")
                case "edit": try Data("external edit".utf8).write(to: marketplaceBackup.appendingPathComponent("external-file"))
                case "replacement":
                    try FileManager.default.moveItem(at: marketplaceBackup, to: parked)
                    try FileManager.default.copyItem(at: parked, to: marketplaceBackup)
                default: XCTFail("Unexpected cleanup mutation")
                }
            }, change)
            XCTAssertTrue(reachedSecondCleanup, change)
            XCTAssertFalse(FileManager.default.fileExists(atPath: serviceBackup.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marketplaceBackup.path))
            XCTAssertEqual(try installationDigest(fixture), newGeneration, change)
            try pending.rollback()
            XCTAssertEqual(try installationDigest(fixture), newGeneration, change)
            if change == "edit" {
                XCTAssertEqual(try String(contentsOf: marketplaceBackup.appendingPathComponent("external-file")), "external edit")
            }
            if change == "replacement" { XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path)) }
        }
    }

    func testPolicyChangedAfterProvisioningPreventsInstall() async throws {
        let fixture = try RuntimeFixture()
        let client = ComputerUseRecordingClient()
        var reads = 0
        client.reply = { method, _ in
            if method == "config/read" { reads += 1; return ["config": reads == 1 ? [:] : ["features": ["plugins": false]]] }
            return [:]
        }
        let runtime = try ComputerUseRuntime(source: fixture.source(), initialState: .ready, service: fixture.service)
        let state = await runtime.prepare(using: client, home: fixture.home)
        guard case .disabled = state else { return XCTFail("Expected policy veto") }
        XCTAssertEqual(client.requests.map(\.0), ["config/read", "config/read"])
    }
}
