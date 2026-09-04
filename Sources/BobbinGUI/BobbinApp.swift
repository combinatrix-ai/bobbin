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
        // Constructing the shared updater starts Sparkle's scheduled checks.
        _ = UpdaterController.shared
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
                let paths = try HarnessPaths()
                let isFreshInstall = !FileManager.default.fileExists(
                    atPath: paths.root.path
                )
                let controller = try HarnessController()
                AppLaunchAtLogin.controller.initializeDefaultIfNeeded(
                    isFreshInstall: isFreshInstall,
                    store: AppLaunchAtLogin.defaultStore
                )
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
            MenuBarStatusLabel(controller: controller, store: controller.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item has two independent signals: the central core breathes
/// while one or more turns run, and a single lower-right dot marks any unseen
/// completed result. TimelineView is scoped to this tiny label, preserving the
/// existing MenuBarExtra window/popover behavior while providing a steady
/// 12-frame-per-second alpha animation.
private struct MenuBarStatusLabel: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathingStartedAt = Date()
    @State private var settlingStartedAt: Date?
    @State private var settleFromOpacity = 1.0

    var body: some View {
        let isWorking = store.hasRunningThread
        let hasUnseen = store.hasUnseenResults
        let isSettling = settlingStartedAt != nil

        // TimelineView is paused between lifecycle changes. The one-hour
        // fallback keeps the label eligible for a future scene refresh but
        // avoids a permanent 12 Hz wakeup while Bobbin is idle. Reduce Motion
        // also pauses the animation because its working core is static.
        let isAnimating = (!reduceMotion && isWorking) || isSettling
        let interval = 1.0 / 12.0
        TimelineView(.periodic(from: Date(), by: isAnimating ? interval : 3_600)) { context in
            let opacity = coreOpacity(
                at: context.date,
                isWorking: isWorking,
                reduceMotion: reduceMotion
            )
            let state = IconRenderer.MenuBarIconState(
                isWorking: isWorking,
                hasUnseenResult: hasUnseen,
                coreOpacity: opacity
            )

            Image(nsImage: IconRenderer.menuBarImage(state: state))
                .renderingMode(.template)
                .accessibilityLabel("Bobbin")
                .accessibilityValue(controller.statusItemAccessibilityValue)
        }
        .onAppear {
            breathingStartedAt = Date()
            settlingStartedAt = nil
        }
        .onChange(of: isWorking) { wasWorking, nowWorking in
            let now = Date()
            if nowWorking {
                breathingStartedAt = now
                settlingStartedAt = nil
            } else if wasWorking {
                if reduceMotion {
                    settlingStartedAt = nil
                    settleFromOpacity = 1
                    return
                }
                // Preserve the alpha at the moment the final turn stopped,
                // then ease to the quiet full-opacity core in <=400 ms.
                settleFromOpacity = coreOpacity(
                    at: now,
                    isWorking: true,
                    reduceMotion: reduceMotion
                )
                settlingStartedAt = now
            }
        }
        .onChange(of: reduceMotion) { _, nowReduced in
            guard isWorking else { return }
            if nowReduced {
                settlingStartedAt = nil
            } else {
                breathingStartedAt = Date()
            }
        }
        .task(id: settlingStartedAt) {
            guard settlingStartedAt != nil else { return }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(IconRenderer.MenuBarAnimation.settleDuration * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.settlingStartedAt = nil
        }
    }

    private func coreOpacity(
        at date: Date,
        isWorking: Bool,
        reduceMotion: Bool
    ) -> Double {
        if reduceMotion {
            return isWorking ? 0.5 : 1
        }

        if isWorking {
            let elapsed = max(0, date.timeIntervalSince(breathingStartedAt))
            return IconRenderer.MenuBarAnimation.breathingOpacity(elapsed: elapsed)
        }

        guard let settlingStartedAt else { return 1 }
        return IconRenderer.MenuBarAnimation.settlingOpacity(
            from: settleFromOpacity,
            elapsed: date.timeIntervalSince(settlingStartedAt)
        )
    }
}
