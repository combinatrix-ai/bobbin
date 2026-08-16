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
