import XCTest
@testable import BobbinCore

final class ComposerInputTests: XCTestCase {
    func testMarkedTextUsesReturnToCommitInsteadOfSending() {
        XCTAssertEqual(
            ComposerReturnPolicy.action(isShiftPressed: false, hasMarkedText: true),
            .commitMarkedText
        )
    }

    func testPlainReturnSendsAfterCompositionHasFinished() {
        XCTAssertEqual(
            ComposerReturnPolicy.action(isShiftPressed: false, hasMarkedText: false),
            .send
        )
    }

    func testShiftReturnAlwaysInsertsANewline() {
        XCTAssertEqual(
            ComposerReturnPolicy.action(isShiftPressed: true, hasMarkedText: false),
            .insertNewline
        )
        XCTAssertEqual(
            ComposerReturnPolicy.action(isShiftPressed: true, hasMarkedText: true),
            .insertNewline
        )
    }
}
