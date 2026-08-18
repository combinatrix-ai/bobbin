import AppKit
import SwiftUI
import BobbinCore
import BobbinIcon

private final class DemoRootCleanup: NSObject {
    private let paths: HarnessPaths

    init(paths: HarnessPaths) {
        self.paths = paths
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func applicationWillTerminate() {
        paths.removeDemoRoot()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        paths.removeDemoRoot()
    }
}

@main
struct BobbinApp: App {
    @StateObject private var controller: HarnessController
    @StateObject private var popoverSession = PopoverSessionState()
    private let demoCleanup: DemoRootCleanup?

    init() {
        let options = RuntimeOptions.fromProcess()
        do {
            if options.demoMode {
                let paths = try HarnessPaths.demo()
                let cleanup = DemoRootCleanup(paths: paths)
                var fixture: DemoFixture?
                var dataError: String?

                if let optionError = options.demoDataError {
                    // A malformed --demo-data invocation is itself demo data
                    // input; it must never select the built-in fixture.
                    dataError = optionError
                } else if let dataPath = options.demoDataPath {
                    do {
                        let dataURL = Self.demoDataURL(for: dataPath)
                        let loaded = try DemoFixture.load(from: dataURL)
                        try loaded.install(to: paths)
                        fixture = loaded
                    } catch {
                        dataError = error.localizedDescription
                    }
                } else {
                    let loaded = DemoFixture.builtIn()
                    try loaded.install(to: paths)
                    fixture = loaded
                }

                let controller = try HarnessController(
                    demoPaths: paths,
                    fixture: fixture,
                    error: dataError
                )
                self.demoCleanup = cleanup
                _controller = StateObject(wrappedValue: controller)
            } else {
                let controller = try HarnessController()
                self.demoCleanup = nil
                _controller = StateObject(wrappedValue: controller)
            }
        } catch {
            fatalError("Bobbin failed to initialize: \(error.localizedDescription)")
        }
    }

    private static func demoDataURL(for path: String) -> URL {
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(controller: controller, session: popoverSession)
                .frame(width: 392, height: 560)
        } label: {
            // The status item carries the Bobbin mark itself. The image
            // is a template, so AppKit tints it for light and dark menu bars
            // and inverts it while the popover is open.
            Image(nsImage: Self.menuBarIcon)
                .renderingMode(.template)
                .accessibilityLabel("Bobbin")
        }
        .menuBarExtraStyle(.window)
    }

    /// Built once: the glyph is resolution-independent, so the same instance
    /// serves every backing scale.
    private static let menuBarIcon = IconRenderer.menuBarImage()
}
