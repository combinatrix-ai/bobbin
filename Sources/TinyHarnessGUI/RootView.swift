import AppKit
import SwiftUI
import TinyHarnessCore

struct RootView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject private var store: ThreadStore

    init(controller: HarnessController) {
        self.controller = controller
        self.store = controller.store
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(controller: controller)
            Group {
                switch controller.serverState {
                case .starting:
                    LoadingView(title: "Starting Tiny Harness", detail: "Codex app-serverを準備しています")
                case .stopped(let detail):
                    ServerErrorView(detail: detail, restart: controller.restart)
                case .ready:
                    contentForAuthentication
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .task { controller.boot() }
    }

    @ViewBuilder
    private var contentForAuthentication: some View {
        switch controller.authState {
        case .authenticated:
            HarnessView(controller: controller, store: store)
        case .checking:
            LoadingView(title: "Checking authentication", detail: "認証状態を確認しています")
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
            AuthErrorView(message: message, retryDeviceAuth: controller.chooseDeviceAuth)
        }
    }
}

private struct AppHeader: View {
    @ObservedObject var controller: HarnessController

    var body: some View {
        HStack(spacing: 9) {
            Text("ti")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(-0.6)
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 25, height: 25)
                .background(.primary, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 0) {
                Text("Tiny Harness").font(.system(size: 13, weight: .semibold))
                Text("Disposable Codex workspace")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Label(controller.serverState.label, systemImage: statusSymbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(statusColor)
                .labelStyle(.titleAndIcon)

            Menu {
                Text("Authentication: \(authenticationLabel)")
                Text("Default: Luna / xhigh")
                Divider()
                Button("Restart app server") { controller.restart() }
                Divider()
                Button("Quit Tiny Harness") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusSymbol: String {
        switch controller.serverState {
        case .starting: "circle.dotted"
        case .ready: "circle.fill"
        case .stopped: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.serverState {
        case .starting: .secondary
        case .ready: .green
        case .stopped: .red
        }
    }

    private var authenticationLabel: String {
        if case .authenticated(let mode) = controller.authState { return mode.rawValue }
        return "Not connected"
    }
}

private struct LoadingView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct ServerErrorView: View {
    let detail: String
    let restart: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.square.fill")
                .font(.system(size: 34))
                .foregroundStyle(.red)
            Text("App server stopped").font(.system(size: 17, weight: .semibold))
            Text("スレッドは専用領域に残っています。再起動すると続けられます。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(10)
                .frame(maxWidth: 330, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            Button("Restart server", action: restart).buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
