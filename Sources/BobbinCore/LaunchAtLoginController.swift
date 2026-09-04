import Combine
import Foundation

public enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
public protocol LaunchAtLoginService: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() throws
}

@MainActor
public protocol LaunchAtLoginDefaultStore: AnyObject {
    var hasInitializedDefault: Bool { get }

    func markDefaultInitialized()
}

/// Keeps the Settings toggle synchronized with the system login-item state.
///
/// ServiceManagement remains in the GUI target; this controller owns only the
/// state transition so success, failure and user-approval flows stay testable.
@MainActor
public final class LaunchAtLoginController: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var requiresApproval = false
    @Published public private(set) var errorMessage: String?

    private let service: any LaunchAtLoginService

    public init(service: any LaunchAtLoginService) {
        self.service = service
        refresh()
    }

    /// Enables Launch at Login once for a genuinely new Bobbin installation.
    ///
    /// Existing installations are marked as migrated without changing their
    /// login-item setting. The marker is written before registration so a
    /// persistent system error cannot trigger an automatic retry every launch;
    /// the Settings toggle remains the explicit recovery path.
    public func initializeDefaultIfNeeded(
        isFreshInstall: Bool,
        store: any LaunchAtLoginDefaultStore
    ) {
        guard !store.hasInitializedDefault else { return }
        store.markDefaultInitialized()
        guard isFreshInstall else { return }
        setEnabled(true)
    }

    public func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound:
                    try service.register()
                }
            } else {
                switch service.status {
                case .enabled, .requiresApproval:
                    try service.unregister()
                case .notRegistered, .notFound:
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }

    public func dismissError() {
        errorMessage = nil
    }
}
