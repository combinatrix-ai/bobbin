import XCTest
@testable import BobbinCore

final class ThreadStoreTests: XCTestCase {
    @MainActor
    func testActiveThreadsSortNewestFirstAndFadeWithAge() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000_000)

        let older = try fixture.store.createThread(
            workingDirectory: "/tmp/older",
            now: now.addingTimeInterval(-6 * 24 * 60 * 60)
        )
        let newer = try fixture.store.createThread(
            workingDirectory: "/tmp/newer",
            now: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )

        XCTAssertEqual(fixture.store.activeThreads.map(\.id), [newer.id, older.id])
        XCTAssertGreaterThan(
            fixture.store.opacity(for: newer, now: now),
            fixture.store.opacity(for: older, now: now)
        )
        XCTAssertEqual(fixture.store.opacity(for: older, now: now), 1 - (0.58 * 6 / 7), accuracy: 0.001)
    }

    @MainActor
    func testSavedThreadsAppendAtBottomAndDoNotExpire() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000_000)

        let first = try fixture.store.createThread(
            workingDirectory: "/tmp/first",
            now: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let second = try fixture.store.createThread(
            workingDirectory: "/tmp/second",
            now: now.addingTimeInterval(-9 * 24 * 60 * 60)
        )

        try fixture.store.saveThread(first.id, now: now.addingTimeInterval(-60))
        try fixture.store.saveThread(second.id, now: now)

        XCTAssertEqual(fixture.store.savedThreads.map(\.id), [first.id, second.id])
        XCTAssertTrue(fixture.store.expiredThreads(now: now).isEmpty)
    }

    @MainActor
    func testUnsavedThreadExpiresAfterSevenDays() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000_000)

        let fresh = try fixture.store.createThread(
            workingDirectory: "/tmp/fresh",
            now: now.addingTimeInterval(-6.9 * 24 * 60 * 60)
        )
        let expired = try fixture.store.createThread(
            workingDirectory: "/tmp/expired",
            now: now.addingTimeInterval(-7 * 24 * 60 * 60)
        )

        XCTAssertEqual(fixture.store.expiredThreads(now: now).map(\.id), [expired.id])
        XCTAssertTrue(fixture.store.activeThreads.contains(where: { $0.id == fresh.id }))
    }

    @MainActor
    func testStateRoundTripsWithoutSecrets() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let thread = try fixture.store.createThread(workingDirectory: "/tmp/project")
        try fixture.store.update(thread.id) {
            $0.messages.append(ChatMessage(role: .user, text: "hello"))
        }

        let reloaded = try ThreadStore(paths: fixture.paths)
        XCTAssertEqual(reloaded.state.threads.first?.messages.first?.text, "hello")
        let rawState = try String(contentsOf: fixture.paths.stateFile, encoding: .utf8)
        XCTAssertFalse(rawState.contains("OPENAI_API_KEY"))
        XCTAssertFalse(rawState.contains("sk-"))
    }

    @MainActor
    func testThreadModelDefaultsAndSelectionPersist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let thread = try fixture.store.createThread(workingDirectory: "/tmp/project")
        XCTAssertEqual(thread.model, HarnessThread.defaultModel)
        XCTAssertEqual(thread.reasoningEffort, HarnessThread.defaultReasoningEffort)

        try fixture.store.update(thread.id) {
            $0.model = "gpt-5.6-terra"
            $0.reasoningEffort = "high"
        }

        let reloaded = try ThreadStore(paths: fixture.paths)
        let selected = try XCTUnwrap(reloaded.state.threads.first)
        XCTAssertEqual(selected.model, "gpt-5.6-terra")
        XCTAssertEqual(selected.reasoningEffort, "high")
    }

    @MainActor
    func testDefaultSelectionPersistsAndAppliesToNewThreads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.store.updateDefaults(model: "gpt-5.6-terra", reasoningEffort: "max")
        let thread = try fixture.store.createThread(workingDirectory: "/tmp/project")
        XCTAssertEqual(thread.model, "gpt-5.6-terra")
        XCTAssertEqual(thread.reasoningEffort, "max")

        let reloaded = try ThreadStore(paths: fixture.paths)
        XCTAssertEqual(reloaded.state.defaultModel, "gpt-5.6-terra")
        XCTAssertEqual(reloaded.state.defaultReasoningEffort, "max")
    }

    @MainActor
    func testDefaultSystemPromptIsPersistedAndCapturedByNewThreads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.store.updateSystemPrompt("Keep replies focused.")
        let thread = try fixture.store.createThread(workingDirectory: "/tmp/project")

        XCTAssertEqual(thread.systemPrompt, "Keep replies focused.")

        let reloaded = try ThreadStore(paths: fixture.paths)
        XCTAssertEqual(reloaded.state.defaultSystemPrompt, "Keep replies focused.")
    }

    @MainActor
    func testFreshPersistedStateCarriesTheDefaultSystemPrompt() {
        let state = PersistedState()
        let expected = """
        You are answering inside Bobbin, a macOS menu bar popover roughly 390 points wide.

        - Lead with the answer. Add context afterwards, and only when it changes what to do.
        - Keep replies short enough to read without scrolling — usually a few sentences.
        - Avoid wide tables and long code blocks; they wrap badly at this width. Show only the lines that changed.
        - Reply in the language the user writes in.

        Brevity applies to the reply, not to the work. Take as long as you need on tools, files and reasoning.
        """

        XCTAssertEqual(HarnessThread.defaultSystemPrompt, expected)
        XCTAssertEqual(state.defaultSystemPrompt, expected)
    }

    @MainActor
    func testNewThreadInheritsTheCurrentDefaultSystemPrompt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.store.updateSystemPrompt("The current default")
        let thread = try fixture.store.createThread(workingDirectory: "/tmp/project")

        XCTAssertEqual(thread.systemPrompt, "The current default")
    }

    @MainActor
    func testChangingDefaultSystemPromptDoesNotChangeExistingThreads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.store.updateSystemPrompt("First prompt")
        let existing = try fixture.store.createThread(workingDirectory: "/tmp/existing")

        try fixture.store.updateSystemPrompt("Second prompt")
        let fresh = try fixture.store.createThread(workingDirectory: "/tmp/fresh")

        let storedExisting = try XCTUnwrap(
            fixture.store.state.threads.first(where: { $0.id == existing.id })
        )
        XCTAssertEqual(storedExisting.systemPrompt, "First prompt")
        XCTAssertEqual(fresh.systemPrompt, "Second prompt")
    }

    @MainActor
    func testClearingSystemPromptPersistsAsEmptyAcrossReload() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.store.updateSystemPrompt("")
        let reloaded = try ThreadStore(paths: fixture.paths)

        XCTAssertEqual(reloaded.state.defaultSystemPrompt, "")
        let thread = try reloaded.createThread(workingDirectory: "/tmp/project")
        XCTAssertEqual(thread.systemPrompt, "")
    }

    @MainActor
    func testModelCatalogUsesAppServerModelsAndEfforts() {
        let options = HarnessController.modelOptions(from: [
            [
                "id": "gpt-5.6-luna",
                "displayName": "GPT-5.6 Luna",
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "high"],
                    ["reasoningEffort": "xhigh"],
                    ["reasoningEffort": "xhigh"]
                ]
            ],
            ["id": "no-efforts"]
        ])

        XCTAssertEqual(options, [
            HarnessModelOption(
                id: "gpt-5.6-luna",
                displayName: "GPT-5.6 Luna",
                supportedReasoningEfforts: ["high", "xhigh"]
            )
        ])
    }

    @MainActor
    func testLegacyThreadDefaultsMissingModelSelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        _ = try fixture.store.createThread(workingDirectory: "/tmp/project")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.stateFile)
            ) as? [String: Any]
        )
        var threads = try XCTUnwrap(object["threads"] as? [[String: Any]])
        threads[0].removeValue(forKey: "model")
        threads[0].removeValue(forKey: "reasoningEffort")
        threads[0].removeValue(forKey: "systemPrompt")
        object["threads"] = threads
        object.removeValue(forKey: "defaultModel")
        object.removeValue(forKey: "defaultReasoningEffort")
        object.removeValue(forKey: "defaultSystemPrompt")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try legacyData.write(to: fixture.paths.stateFile, options: .atomic)

        let reloaded = try ThreadStore(paths: fixture.paths)
        let selected = try XCTUnwrap(reloaded.state.threads.first)
        XCTAssertEqual(selected.model, HarnessThread.defaultModel)
        XCTAssertEqual(selected.reasoningEffort, HarnessThread.defaultReasoningEffort)
        XCTAssertEqual(selected.systemPrompt, HarnessThread.defaultSystemPrompt)
        XCTAssertEqual(reloaded.state.defaultModel, HarnessThread.defaultModel)
        XCTAssertEqual(reloaded.state.defaultReasoningEffort, HarnessThread.defaultReasoningEffort)
        XCTAssertEqual(reloaded.state.defaultSystemPrompt, HarnessThread.defaultSystemPrompt)
    }

    @MainActor
    func testNewThreadDefaultsToHomeUnlessDirectoryIsSupplied() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        XCTAssertEqual(HarnessThread.defaultWorkingDirectory, home)
        XCTAssertTrue(home.hasPrefix("/"))

        // No directory supplied: the home directory, never a remembered one.
        XCTAssertEqual(HarnessController.resolvedWorkingDirectory(nil), home)
        XCTAssertEqual(HarnessController.resolvedWorkingDirectory("  "), home)

        // An explicit directory always wins.
        XCTAssertEqual(HarnessController.resolvedWorkingDirectory("/tmp/project"), "/tmp/project")
    }

    @MainActor
    func testLegacyLastWorkingDirectoryIsDroppedAndDoesNotMoveThreads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let existing = try fixture.store.createThread(workingDirectory: "/tmp/project")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.stateFile)
            ) as? [String: Any]
        )
        object["lastWorkingDirectory"] = "/Users/legacy/Documents"
        try JSONSerialization.data(withJSONObject: object)
            .write(to: fixture.paths.stateFile, options: .atomic)

        let reloaded = try ThreadStore(paths: fixture.paths)
        // The old thread keeps its own directory.
        XCTAssertEqual(
            reloaded.state.threads.first(where: { $0.id == existing.id })?.workingDirectory,
            "/tmp/project"
        )

        // A new thread ignores the persisted value entirely...
        let fresh = try reloaded.createThread(
            workingDirectory: HarnessController.resolvedWorkingDirectory(nil)
        )
        XCTAssertEqual(fresh.workingDirectory, HarnessThread.defaultWorkingDirectory)

        // ...and the obsolete key is gone from the rewritten state file.
        let rawState = try String(contentsOf: fixture.paths.stateFile, encoding: .utf8)
        XCTAssertFalse(rawState.contains("lastWorkingDirectory"))
    }

    @MainActor
    func testModelSelectionIsForwardedToAppServerRequests() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var thread = try fixture.store.createThread(workingDirectory: "/tmp/project")
        thread.model = "gpt-5.6-sol"
        thread.reasoningEffort = "max"

        let start = HarnessController.threadStartParameters(for: thread)
        XCTAssertEqual(start["model"] as? String, "gpt-5.6-sol")

        let turn = HarnessController.turnStartParameters(
            threadID: "codex-thread",
            text: "hello",
            thread: thread
        )
        XCTAssertEqual(turn["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(turn["effort"] as? String, "max")
        XCTAssertEqual(turn["threadId"] as? String, "codex-thread")
    }

    @MainActor
    func testSystemPromptIsForwardedToThreadStartOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var thread = try fixture.store.createThread(workingDirectory: "/tmp/project")
        thread.systemPrompt = "Keep replies concise."

        let start = HarnessController.threadStartParameters(for: thread)
        XCTAssertEqual(start["developerInstructions"] as? String, thread.systemPrompt)

        let resume = HarnessController.threadResumeParameters(
            threadID: "codex-thread",
            thread: thread
        )
        XCTAssertNil(resume["developerInstructions"])

        let turn = HarnessController.turnStartParameters(
            threadID: "codex-thread",
            text: "hello",
            thread: thread
        )
        XCTAssertNil(turn["developerInstructions"])
    }

    @MainActor
    func testWhitespaceOnlySystemPromptIsOmittedFromStartAndResumeParameters() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var thread = try fixture.store.createThread(workingDirectory: "/tmp/project")

        for prompt in ["", " \n\t "] {
            thread.systemPrompt = prompt
            let start = HarnessController.threadStartParameters(for: thread)
            XCTAssertNil(start["developerInstructions"])

            let resume = HarnessController.threadResumeParameters(
                threadID: "codex-thread",
                thread: thread
            )
            XCTAssertNil(resume["developerInstructions"])
        }
    }

    @MainActor
    func testReviewModeDefaultsToAutoReviewAndPersistsPerThread() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let thread = try fixture.store.createThread(workingDirectory: "/tmp/project")
        XCTAssertEqual(thread.reviewMode, .autoReview)
        XCTAssertEqual(HarnessThread.defaultReviewMode, .autoReview)

        let other = try fixture.store.createThread(workingDirectory: "/tmp/other")
        try fixture.store.update(thread.id) { $0.reviewMode = .allowAll }

        let reloaded = try ThreadStore(paths: fixture.paths)
        XCTAssertEqual(reloaded.state.threads.first(where: { $0.id == thread.id })?.reviewMode, .allowAll)
        // The mode is per thread: the sibling keeps the default.
        XCTAssertEqual(reloaded.state.threads.first(where: { $0.id == other.id })?.reviewMode, .autoReview)
    }

    @MainActor
    func testStoredThreadsWithoutOrWithUnknownReviewModeDecodeAsAutoReview() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let legacy = try fixture.store.createThread(workingDirectory: "/tmp/legacy")
        let unknown = try fixture.store.createThread(workingDirectory: "/tmp/unknown")
        try fixture.store.update(unknown.id) { $0.reviewMode = .denyAll }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.stateFile)
            ) as? [String: Any]
        )
        var threads = try XCTUnwrap(object["threads"] as? [[String: Any]])
        let legacyIndex = try XCTUnwrap(
            threads.firstIndex { $0["id"] as? String == legacy.id.uuidString }
        )
        let unknownIndex = try XCTUnwrap(
            threads.firstIndex { $0["id"] as? String == unknown.id.uuidString }
        )
        threads[legacyIndex].removeValue(forKey: "reviewMode")
        threads[unknownIndex]["reviewMode"] = "someFutureMode"
        object["threads"] = threads
        try JSONSerialization.data(withJSONObject: object)
            .write(to: fixture.paths.stateFile, options: .atomic)

        let reloaded = try ThreadStore(paths: fixture.paths)
        XCTAssertEqual(reloaded.state.threads.first(where: { $0.id == legacy.id })?.reviewMode, .autoReview)
        XCTAssertEqual(reloaded.state.threads.first(where: { $0.id == unknown.id })?.reviewMode, .autoReview)
    }

    @MainActor
    func testReviewModeMapsToAppServerParameters() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var thread = try fixture.store.createThread(workingDirectory: "/tmp/project")

        let expected: [HarnessReviewMode: (policy: String, reviewer: String, sandbox: String)] = [
            .autoReview: ("on-request", "auto_review", "workspace-write"),
            .allowAll: ("never", "user", "danger-full-access"),
            .denyAll: ("never", "user", "workspace-write")
        ]

        for mode in HarnessReviewMode.allCases {
            let want = try XCTUnwrap(expected[mode])
            thread.reviewMode = mode

            let start = HarnessController.threadStartParameters(for: thread)
            XCTAssertEqual(start["approvalPolicy"] as? String, want.policy, "\(mode) thread/start")
            XCTAssertEqual(start["approvalsReviewer"] as? String, want.reviewer, "\(mode) thread/start")
            XCTAssertEqual(start["sandbox"] as? String, want.sandbox, "\(mode) thread/start")

            // Resume carries a changed mode into every turn after the first.
            let resume = HarnessController.threadResumeParameters(
                threadID: "codex-thread",
                thread: thread
            )
            XCTAssertEqual(resume["threadId"] as? String, "codex-thread")
            XCTAssertEqual(resume["approvalPolicy"] as? String, want.policy, "\(mode) thread/resume")
            XCTAssertEqual(resume["approvalsReviewer"] as? String, want.reviewer, "\(mode) thread/resume")
            XCTAssertEqual(resume["sandbox"] as? String, want.sandbox, "\(mode) thread/resume")

            let turn = HarnessController.turnStartParameters(
                threadID: "codex-thread",
                text: "hello",
                thread: thread
            )
            XCTAssertEqual(turn["approvalPolicy"] as? String, want.policy, "\(mode) turn/start")
            XCTAssertEqual(turn["approvalsReviewer"] as? String, want.reviewer, "\(mode) turn/start")
            // turn/start has no SandboxMode field; thread/start and
            // thread/resume own the sandbox.
            XCTAssertNil(turn["sandbox"])
        }

        // Only Auto review routes approvals to the review subagent.
        XCTAssertEqual(
            HarnessReviewMode.allCases.filter { $0.approvalsReviewer == "auto_review" },
            [.autoReview]
        )
    }

    // MARK: - Server state presentation

    @MainActor
    func testHealthyServerSaysNothingOnTheMainSurface() {
        // The whole point of the simplified popover: no standing "everything
        // is fine" indicator.
        XCTAssertEqual(HarnessController.ServerState.ready.notice, .none)
        XCTAssertTrue(HarnessController.ServerState.ready.notice.isSilent)
        XCTAssertTrue(HarnessController.ServerState.ready.isHealthy)

        // First boot is covered by the full-pane loading view, so it must not
        // also raise a banner.
        XCTAssertEqual(HarnessController.ServerState.starting.notice, .none)
    }

    @MainActor
    func testOnlyActionableServerStatesRaiseANotice() {
        XCTAssertEqual(HarnessController.ServerState.restarting.notice, .restarting)
        XCTAssertEqual(
            HarnessController.ServerState.stopped("exit status 1").notice,
            .stopped(detail: "exit status 1")
        )

        // The detail travels with the notice so the banner can offer Details.
        guard case .stopped(let detail) = HarnessController.ServerState.stopped("boom").notice else {
            return XCTFail("a stopped server must carry its detail")
        }
        XCTAssertEqual(detail, "boom")

        for state in [
            HarnessController.ServerState.restarting,
            .stopped(""),
            .stopped("detail")
        ] {
            XCTAssertFalse(state.notice.isSilent, "\(state) must be surfaced")
            XCTAssertFalse(state.isHealthy, "\(state) is not healthy")
        }
    }

    @MainActor
    func testSettingsExposesServerStatusOnDemand() {
        XCTAssertEqual(HarnessController.ServerState.ready.settingsLabel, "Healthy")
        XCTAssertEqual(HarnessController.ServerState.restarting.settingsLabel, "Restarting…")
        XCTAssertEqual(HarnessController.ServerState.stopped("x").settingsLabel, "Stopped")
        XCTAssertEqual(HarnessController.ServerState.starting.settingsLabel, "Starting…")
    }

    @MainActor
    func testRestartingIsDistinctFromFirstBoot() {
        // They must not collapse: first boot replaces the whole surface, a
        // restart keeps it and shows an inline notice instead.
        XCTAssertNotEqual(HarnessController.ServerState.restarting, .starting)
        XCTAssertNotEqual(
            HarnessController.ServerState.restarting.notice,
            HarnessController.ServerState.starting.notice
        )
    }
}

private struct Fixture {
    let root: URL
    let paths: HarnessPaths
    @MainActor let store: ThreadStore

    @MainActor
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BobbinTests-\(UUID().uuidString)", isDirectory: true)
        paths = try HarnessPaths(root: root)
        store = try ThreadStore(paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
