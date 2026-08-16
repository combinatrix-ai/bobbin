import XCTest
@testable import TinyHarnessCore

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
        object["threads"] = threads
        object.removeValue(forKey: "defaultModel")
        object.removeValue(forKey: "defaultReasoningEffort")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try legacyData.write(to: fixture.paths.stateFile, options: .atomic)

        let reloaded = try ThreadStore(paths: fixture.paths)
        let selected = try XCTUnwrap(reloaded.state.threads.first)
        XCTAssertEqual(selected.model, HarnessThread.defaultModel)
        XCTAssertEqual(selected.reasoningEffort, HarnessThread.defaultReasoningEffort)
        XCTAssertEqual(reloaded.state.defaultModel, HarnessThread.defaultModel)
        XCTAssertEqual(reloaded.state.defaultReasoningEffort, HarnessThread.defaultReasoningEffort)
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
}

private struct Fixture {
    let root: URL
    let paths: HarnessPaths
    @MainActor let store: ThreadStore

    @MainActor
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyHarnessTests-\(UUID().uuidString)", isDirectory: true)
        paths = try HarnessPaths(root: root)
        store = try ThreadStore(paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
