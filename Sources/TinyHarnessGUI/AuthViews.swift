import AppKit
import SwiftUI

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

            Text("OPENAI_API_KEY を検出")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 8) {
                Button("このキーを使う", action: useDetected)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Device auth", action: useDeviceAuth)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            DisclosureGroup("別のキーを入力", isExpanded: $showManualEntry) {
                HStack(spacing: 6) {
                    SecureField("sk-…", text: $enteredKey)
                        .textFieldStyle(.roundedBorder)
                    Button("使用") {
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
            .help("検出元: \(source)")
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
            Text("ti")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 42, height: 42)
                .background(.primary, in: RoundedRectangle(cornerRadius: 11))

            Text("Codexに接続")
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
                .help("コードをコピー")
                .accessibilityLabel("コードをコピー")
            }

            Button("ブラウザで開く") {
                if let url = URL(string: verificationURL) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Label("承認を待っています", systemImage: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AuthErrorView: View {
    let message: String
    let retryDeviceAuth: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(.red)
            Text("認証できませんでした")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 300)
            Button("Device authを再試行", action: retryDeviceAuth)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
