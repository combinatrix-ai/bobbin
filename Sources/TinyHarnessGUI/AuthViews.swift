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
        VStack(spacing: 15) {
            Image(systemName: "key.fill")
                .font(.system(size: 27))
                .frame(width: 48, height: 48)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
            Text("API keyが見つかりました")
                .font(.system(size: 18, weight: .semibold))
            Text("\(source) にOpenAI API keyがあります。今回のTiny Harnessで使いますか？")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)

            HStack(spacing: 8) {
                Button("API keyを使う", action: useDetected)
                    .buttonStyle(.borderedProminent)
                Button("Device authを使う", action: useDeviceAuth)
                    .buttonStyle(.bordered)
            }

            DisclosureGroup("別のAPI keyを入力", isExpanded: $showManualEntry) {
                HStack {
                    SecureField("sk-...", text: $enteredKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Use") {
                        useEntered(enteredKey)
                        enteredKey = ""
                    }
                    .disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11))
            .frame(maxWidth: 330)

            Text("keyの値はTiny Harnessの履歴には保存しません")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(36)
    }
}

struct DeviceAuthView: View {
    let verificationURL: String
    let userCode: String

    var body: some View {
        VStack(spacing: 15) {
            Text("ti")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 46, height: 46)
                .background(.primary, in: RoundedRectangle(cornerRadius: 12))
            Text("Connect to Codex")
                .font(.system(size: 18, weight: .semibold))
            Text("API keyは使いません。ブラウザでdevice authを完了してください。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(userCode)
                .font(.system(size: 21, weight: .semibold, design: .monospaced))
                .tracking(2)
                .textSelection(.enabled)
                .padding(.horizontal, 22)
                .frame(height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
            HStack(spacing: 8) {
                Button("Open browser") {
                    if let url = URL(string: verificationURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                }
                .buttonStyle(.bordered)
            }
            Label("Waiting for authorization", systemImage: "clock")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(36)
    }
}

struct AuthErrorView: View {
    let message: String
    let retryDeviceAuth: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.red)
            Text("Authentication failed").font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            Button("Try device auth", action: retryDeviceAuth)
                .buttonStyle(.borderedProminent)
        }
        .padding(36)
    }
}
