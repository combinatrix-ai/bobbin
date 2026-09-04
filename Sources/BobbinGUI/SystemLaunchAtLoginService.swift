import BobbinCore
import Foundation
import ServiceManagement

@MainActor
enum AppLaunchAtLogin {
    static let controller = LaunchAtLoginController(
        service: SystemLaunchAtLoginService()
    )
    static let defaultStore: any LaunchAtLoginDefaultStore =
        UserDefaultsLaunchAtLoginDefaultStore()
}

@MainActor
private final class UserDefaultsLaunchAtLoginDefaultStore: LaunchAtLoginDefaultStore {
    private static let key = "launchAtLoginDefaultInitialized"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasInitializedDefault: Bool {
        defaults.bool(forKey: Self.key)
    }

    func markDefaultInitialized() {
        defaults.set(true, forKey: Self.key)
    }
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginService {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
