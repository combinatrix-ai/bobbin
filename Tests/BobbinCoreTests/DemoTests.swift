import XCTest
@testable import BobbinCore

final class RuntimeOptionsTests: XCTestCase {
    func testDemoFlagIsExactAndDataFlagImpliesDemoMode() {
        let flag = RuntimeOptions.fromProcess(
            arguments: ["Bobbin", "--demo-mode"],
            environment: [:]
        )
        XCTAssertTrue(flag.demoMode)
        XCTAssertNil(flag.demoDataPath)

        let data = RuntimeOptions.fromProcess(
            arguments: ["Bobbin", "--demo-data", "fixtures/state.json"],
            environment: [:]
        )
        XCTAssertTrue(data.demoMode)
        XCTAssertEqual(data.demoDataPath, "fixtures/state.json")
        XCTAssertNil(data.demoDataError)

        let nearMiss = RuntimeOptions.fromProcess(
            arguments: ["Bobbin", "--demo-mode-notes"],
            environment: [:]
        )
        XCTAssertFalse(nearMiss.demoMode)
    }

    func testTruthyDemoEnvironmentValuesEnableDemoMode() {
        for value in ["1", "true", "TRUE", " yes ", "on"] {
            let options = RuntimeOptions.fromProcess(
                arguments: ["Bobbin"],
                environment: [RuntimeOptions.demoEnvironmentKey: value]
            )
            XCTAssertTrue(options.demoMode, "Expected \(value) to enable demo mode")
        }
    }

    func testDemoDataEnvironmentEnablesDemoMode() {
        let options = RuntimeOptions.fromProcess(
            arguments: ["Bobbin"],
            environment: [RuntimeOptions.demoDataEnvironmentKey: "/tmp/fixture.json"]
        )

        XCTAssertTrue(options.demoMode)
        XCTAssertEqual(options.demoDataPath, "/tmp/fixture.json")
    }

    func testOrdinaryProcessAndExecutablePathDoNotEnableDemoMode() {
        let ordinary = RuntimeOptions.fromProcess(
            arguments: ["/Applications/Bobbin.app/Contents/MacOS/Bobbin"],
            environment: [:]
        )
        XCTAssertFalse(ordinary.demoMode)

        let flagInExecutablePath = RuntimeOptions.fromProcess(
            arguments: ["/tmp/Bobbin--demo-mode-capture/Bobbin"],
            environment: [:]
        )
        XCTAssertFalse(flagInExecutablePath.demoMode)

        for value in ["0", "false", "no", "off", ""] {
            let options = RuntimeOptions.fromProcess(
                arguments: ["Bobbin"],
                environment: [RuntimeOptions.demoEnvironmentKey: value]
            )
            XCTAssertFalse(options.demoMode, "Expected \(value) not to enable demo mode")
        }
    }

    func testMissingDemoDataArgumentIsAnErrorAndDoesNotSelectFixture() {
        let options = RuntimeOptions.fromProcess(
            arguments: ["Bobbin", "--demo-data"],
            environment: [:]
        )

        XCTAssertTrue(options.demoMode)
        XCTAssertNil(options.demoDataPath)
        XCTAssertNotNil(options.demoDataError)
    }
}

final class DemoFixtureTests: XCTestCase {
    func testDemoRootIsTemporaryAndNormalRootsAreProtected() throws {
        let demoPaths = try HarnessPaths.demo()
        XCTAssertTrue(demoPaths.isDemoRoot)
        XCTAssertTrue(
            demoPaths.root.standardizedFileURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path
            )
        )
        demoPaths.removeDemoRoot()

        let normalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bobbin-Normal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: normalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: normalRoot) }

        let normalPaths = try HarnessPaths(root: normalRoot)
        XCTAssertFalse(normalPaths.isDemoRoot)
        normalPaths.removeDemoRoot()
        XCTAssertTrue(FileManager.default.fileExists(atPath: normalRoot.path))
    }

    @MainActor
    func testLoadingStateFileUsesThePersistedStateSchemaAndThreadStore() throws {
        let sourceThread = HarnessThread(
            id: UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!,
            title: "Imported screenshot thread",
            workingDirectory: "/demo/import",
            model: "gpt-5.6-terra",
            reasoningEffort: "high",
            reviewMode: .allowAll,
            systemPrompt: "Keep the imported preview concise.",
            lastConversationAt: Date(timeIntervalSince1970: 2_000_000),
            status: .done,
            messages: [ChatMessage(role: .assistant, text: "Loaded from state.json.")]
        )
        let state = PersistedState(
            threads: [sourceThread],
            selectedThreadID: sourceThread.id,
            defaultModel: "gpt-5.6-terra",
            defaultReasoningEffort: "high",
            defaultSystemPrompt: "Keep the imported preview concise."
        )

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bobbin-Demo-Input-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try PersistedStateCoding.encoder().encode(state).write(to: sourceURL)

        let fixture = try DemoFixture.load(from: sourceURL)
        XCTAssertEqual(fixture.state.threads.map(\.title), ["Imported screenshot thread"])
        XCTAssertEqual(fixture.state.defaultSystemPrompt, state.defaultSystemPrompt)

        let paths = try HarnessPaths.demo()
        defer { paths.removeDemoRoot() }
        try fixture.install(to: paths)
        let store = try ThreadStore(paths: paths, normalizeInterruptedRuns: false)
        XCTAssertEqual(store.state.threads.map(\.title), ["Imported screenshot thread"])
        XCTAssertEqual(store.state.threads.first?.workingDirectory, "/demo/import")
    }

    func testMalformedOrMissingDemoDataProducesAnError() throws {
        let malformedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bobbin-Demo-Malformed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: malformedURL) }
        try Data("{ not state json".utf8).write(to: malformedURL)

        XCTAssertThrowsError(try DemoFixture.load(from: malformedURL)) { error in
            guard case .decodeFailed = error as? DemoDataError else {
                return XCTFail("Expected a decode error, got \(error)")
            }
        }

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bobbin-Demo-Missing-\(UUID().uuidString).json")
        XCTAssertThrowsError(try DemoFixture.load(from: missingURL)) { error in
            guard case .fileNotFound = error as? DemoDataError else {
                return XCTFail("Expected a missing-file error, got \(error)")
            }
        }
    }

    func testBuiltInFixtureCoversScreenshotStatesAndRoundTrips() throws {
        let fixture = DemoFixture.builtIn(now: Date(timeIntervalSince1970: 2_000_000))
        let decoded = try PersistedStateCoding.decoder().decode(
            PersistedState.self,
            from: fixture.encodedState()
        )

        XCTAssertEqual(decoded.threads.count, fixture.state.threads.count)
        XCTAssertTrue(fixture.state.threads.contains(where: \.isSaved))

        let showcaseCalls = try XCTUnwrap(
            fixture.state.threads.first(where: { $0.title == "Tighten the launch story" })?.toolCalls
        )
        for kind in [ToolCallKind.command, .fileChange, .mcpTool, .webSearch] {
            XCTAssertTrue(showcaseCalls.contains(where: { $0.kind == kind }), "Missing \(kind)")
        }
        for status in [ToolCallStatus.succeeded, .failed, .running, .stopped] {
            XCTAssertTrue(showcaseCalls.contains(where: { $0.status == status }), "Missing \(status)")
        }

        let succeeded = try XCTUnwrap(showcaseCalls.first(where: { $0.status == .succeeded }))
        XCTAssertNotNil(succeeded.durationMs)
        let failed = try XCTUnwrap(showcaseCalls.first(where: { $0.status == .failed }))
        XCTAssertEqual(failed.exitCode, 2)
        XCTAssertEqual(fixture.toolOutputs["demo-command"], "Build complete.\nTests: 18 passed\nElapsed: 1.84s")
    }

    @MainActor
    func testDemoControllerIsReadyAuthenticatedAndKeepsFixtureOutputInMemory() throws {
        let paths = try HarnessPaths.demo()
        defer { paths.removeDemoRoot() }
        let fixture = DemoFixture.builtIn()
        try fixture.install(to: paths)

        let controller = try HarnessController(demoPaths: paths, fixture: fixture)
        XCTAssertTrue(controller.isDemoMode)
        XCTAssertEqual(controller.serverState, .ready)
        XCTAssertTrue(controller.authState.isAuthenticated)
        XCTAssertTrue(controller.modelVerified)
        XCTAssertEqual(controller.activeThreads.count, 4)
        XCTAssertEqual(controller.savedThreads.count, 1)
        XCTAssertEqual(controller.toolOutput(for: "demo-command"), fixture.toolOutputs["demo-command"])
        XCTAssertTrue(
            controller.activeThreads
                .flatMap(\.toolCalls)
                .contains(where: { $0.status == .running })
        )

        // This is a no-op for a demo controller; it cannot enter the
        // production client/app-server path.
        controller.boot()
        XCTAssertEqual(controller.serverState, .ready)
    }

    @MainActor
    func testDemoDataErrorIsRepresentedWithoutBuiltInFallback() throws {
        let paths = try HarnessPaths.demo()
        defer { paths.removeDemoRoot() }

        let controller = try HarnessController(
            demoPaths: paths,
            fixture: nil,
            error: "Could not decode demo data at fixture.json"
        )
        XCTAssertEqual(controller.serverState, .ready)
        XCTAssertFalse(controller.authState.isAuthenticated)
        XCTAssertEqual(controller.lastError, "Could not decode demo data at fixture.json")
        XCTAssertTrue(controller.store.state.threads.isEmpty)
    }
}
