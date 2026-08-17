import AppKit
import SwiftUI
import BobbinIcon

struct APIKeyChoiceView: View {
    let source: String
    let useDetected: () -> Void
    let useEntered: (String) -> Void
    let useDeviceAuth: () -> Void

    @State private var showManualEntry = false
    @State private var enteredKey = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))

            Text("OPENAI_API_KEY detected")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 8) {
                Button("Use this key", action: useDetected)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Device auth", action: useDeviceAuth)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            DisclosureGroup("Enter a different key", isExpanded: $showManualEntry) {
                HStack(spacing: 6) {
                    SecureField("sk-…", text: $enteredKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Use") {
                        useEntered(enteredKey)
                        enteredKey = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 10.5))
            .frame(maxWidth: 280)
            .help("Found in: \(source)")
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceAuthView: View {
    let verificationURL: String
    let userCode: String

    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            // The one place inside the app that shows the mark: an
            // unconfigured session has nothing else to identify itself with.
            ConnectMark()

            Text("Connect to Codex")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 6) {
                Text(userCode)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .frame(height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Copy code")
                .accessibilityLabel("Copy code")
            }

            Button("Open in browser") {
                if let url = URL(string: verificationURL) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Label("Waiting for approval", systemImage: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The app icon's own plate and mark, reused at popover scale so the Connect
/// pane matches what the user sees in the Dock.
private struct ConnectMark: View {
    var body: some View {
        Image(nsImage: IconRenderer.markImage(pointSize: 26))
            .frame(width: 48, height: 48)
            .background(plateColor, in: RoundedRectangle(cornerRadius: 13))
            .accessibilityHidden(true)
    }

    private var plateColor: Color {
        let plate = AppIconSpec.standard.plateColor
        return Color(red: plate.red, green: plate.green, blue: plate.blue)
    }
}

struct AuthErrorView: View {
    let title: String
    let message: String
    let retryDeviceAuth: (() -> Void)?

    init(
        title: String = "Could not sign in",
        message: String,
        retryDeviceAuth: (() -> Void)?
    ) {
        self.title = title
        self.message = message
        self.retryDeviceAuth = retryDeviceAuth
    }

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(.red)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 300)
            if let retryDeviceAuth {
                Button("Retry device auth", action: retryDeviceAuth)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
