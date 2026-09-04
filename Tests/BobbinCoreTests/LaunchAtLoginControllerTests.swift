import Foundation
import XCTest
@testable import BobbinCore

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testInitialStateReflectsServiceStatus() {
        let enabled = LaunchAtLoginController(
            service: FakeLaunchAtLoginService(status: .enabled)
        )
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertFalse(enabled.requiresApproval)

        let approval = LaunchAtLoginController(
            service: FakeLaunchAtLoginService(status: .requiresApproval)
        )
        XCTAssertFalse(approval.isEnabled)
        XCTAssertTrue(approval.requiresApproval)
    }

    func testEnablingRegistersAndRefreshesState() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisablingUnregistersAndRefreshesState() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testFailureRollsBackToActualServiceStateAndReportsError() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = NSError(
            domain: "LaunchAtLoginControllerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Registration failed"]
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.errorMessage, "Registration failed")
    }

    func testUnregisterFailureKeepsEnabledStateAndReportsError() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = NSError(
            domain: "LaunchAtLoginControllerTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Unregistration failed"]
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.errorMessage, "Unregistration failed")
    }

    func testRequiresApprovalDoesNotAttemptDuplicateRegistration() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
    }

    func testFreshInstallEnablesLaunchAtLoginOnce() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let store = FakeLaunchAtLoginDefaultStore()
        let controller = LaunchAtLoginController(service: service)

        controller.initializeDefaultIfNeeded(isFreshInstall: true, store: store)
        controller.initializeDefaultIfNeeded(isFreshInstall: true, store: store)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(store.markCount, 1)
        XCTAssertTrue(controller.isEnabled)
    }

    func testExistingInstallIsMigratedWithoutChangingLoginItem() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let store = FakeLaunchAtLoginDefaultStore()
        let controller = LaunchAtLoginController(service: service)

        controller.initializeDefaultIfNeeded(isFreshInstall: false, store: store)

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(store.markCount, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testInitializedPreferenceDoesNotApplyFreshInstallDefaultAgain() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let store = FakeLaunchAtLoginDefaultStore(hasInitializedDefault: true)
        let controller = LaunchAtLoginController(service: service)

        controller.initializeDefaultIfNeeded(isFreshInstall: true, store: store)

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(store.markCount, 0)
        XCTAssertFalse(controller.isEnabled)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

@MainActor
private final class FakeLaunchAtLoginDefaultStore: LaunchAtLoginDefaultStore {
    var hasInitializedDefault: Bool
    private(set) var markCount = 0

    init(hasInitializedDefault: Bool = false) {
        self.hasInitializedDefault = hasInitializedDefault
    }

    func markDefaultInitialized() {
        hasInitializedDefault = true
        markCount += 1
    }
}
