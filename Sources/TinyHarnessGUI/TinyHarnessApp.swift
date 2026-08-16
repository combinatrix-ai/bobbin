import SwiftUI
import TinyHarnessCore

@main
struct TinyHarnessApp: App {
    @StateObject private var controller: HarnessController

    init() {
        do {
            let controller = try HarnessController()
            _controller = StateObject(wrappedValue: controller)
        } catch {
            fatalError("Tiny Harness failed to initialize: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(controller: controller)
                .frame(width: 392, height: 560)
        } label: {
            Text("ti")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .accessibilityLabel("Tiny Harness")
        }
        .menuBarExtraStyle(.window)
    }
}
