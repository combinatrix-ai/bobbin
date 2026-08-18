import SwiftUI
import BobbinCore

struct RootView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject private var store: ThreadStore
    @ObservedObject var session: PopoverSessionState

    init(controller: HarnessController, session: PopoverSessionState) {
        self.controller = controller
        self.store = controller.store
        self.session = session
    }

    var body: some View {
        Group {
            switch controller.serverState {
            case .starting:
                LoadingView()
            case .ready:
                authenticatedContent
            case .restarting:
                // A restart is progress, not a failure: the thread surface
                // stays up and HarnessView shows the quiet inline notice.
                if controller.authState.isAuthenticated {
                    HarnessView(controller: controller, store: store, session: session)
                } else {
                    LoadingView()
                }
            case .stopped:
                // Once authenticated, keep the thread index visible and
                // surface the failure as the compact inline banner owned by
                // HarnessView. A boot-time failure still gets a retry pane.
                if controller.authState.isAuthenticated {
                    HarnessView(controller: controller, store: store, session: session)
                } else {
                    ServerErrorView(restart: controller.restart)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task {
            // Demo controllers are already ready and authenticated. Keeping
            // this branch at the view boundary makes the production boot
            // sequence unreachable for a demo session.
            if !controller.isDemoMode {
                controller.boot()
            }
        }
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        switch controller.authState {
        case .authenticated:
            HarnessView(controller: controller, store: store, session: session)
        case .checking:
            LoadingView()
        case .chooseAPIKey(let source):
            APIKeyChoiceView(
                source: source,
                useDetected: controller.useDetectedAPIKey,
                useEntered: controller.useAPIKey,
                useDeviceAuth: controller.chooseDeviceAuth
            )
        case .deviceCode(let verificationURL, let userCode, _):
            DeviceAuthView(verificationURL: verificationURL, userCode: userCode)
        case .failed(let message):
            if controller.isDemoMode {
                AuthErrorView(
                    title: "Could not load demo data",
                    message: message,
                    retryDeviceAuth: nil
                )
            } else {
                AuthErrorView(message: message, retryDeviceAuth: controller.chooseDeviceAuth)
            }
        }
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Starting")
                .font(.system(size: 12.5, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ServerErrorView: View {
    let restart: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text("Server stopped")
                .font(.system(size: 13, weight: .semibold))
            Button("Restart", action: restart)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
