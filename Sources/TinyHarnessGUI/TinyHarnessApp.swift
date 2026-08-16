import SwiftUI
import TinyHarnessCore
import TinyHarnessIcon

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
            // The status item carries the Tiny Harness mark itself. The image
            // is a template, so AppKit tints it for light and dark menu bars
            // and inverts it while the popover is open.
            Image(nsImage: Self.menuBarIcon)
                .renderingMode(.template)
                .accessibilityLabel("Tiny Harness")
        }
        .menuBarExtraStyle(.window)
    }

    /// Built once: the glyph is resolution-independent, so the same instance
    /// serves every backing scale.
    private static let menuBarIcon = IconRenderer.menuBarImage()
}
