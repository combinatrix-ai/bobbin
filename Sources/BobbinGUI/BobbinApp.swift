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

/// One presentation-only phase origin shared by the status item and all
/// visible thread rows. It is reset only when the aggregate running state
/// changes from quiet to working, so opening the popover never restarts the
/// breath and rows that start later join the existing cycle.
@MainActor
final class MenuBarActivityClock: ObservableObject {
    @Published private(set) var phaseStartedAt = Date()

    func reset(at date: Date) {
        phaseStartedAt = date
    }
}

@main
struct BobbinApp: App {
    @StateObject private var controller: HarnessController
    @StateObject private var popoverSession = PopoverSessionState()
    @StateObject private var activityClock = MenuBarActivityClock()
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
                .environmentObject(activityClock)
        } label: {
            MenuBarStatusLabel(
                controller: controller,
                store: controller.store,
                activityClock: activityClock
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item has two independent signals: the central core breathes
/// while one or more turns run, and a single lower-right dot marks any unseen
/// completed result. The direct Image is kept as the effective MenuBarExtra
/// label root because AppKit needs a concrete intrinsic-size image to create a
/// visible status item. A conditional task swaps only the core alpha while a
/// turn is running or settling; idle labels have no recurring timer.
private struct MenuBarStatusLabel: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore
    @ObservedObject var activityClock: MenuBarActivityClock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settlingStartedAt: Date?
    @State private var settleFromOpacity = 1.0
    @State private var coreOpacity = 1.0

    private var isWorking: Bool { store.hasRunningThread }
    private var hasUnseenResult: Bool { store.hasUnseenResults }
    private var isSettling: Bool { settlingStartedAt != nil }

    private var animationTaskID: String {
        [
            isWorking ? "working" : "quiet",
            reduceMotion ? "reduce-motion" : "motion",
            isSettling ? String(settlingStartedAt!.timeIntervalSinceReferenceDate) : "settled",
            String(activityClock.phaseStartedAt.timeIntervalSinceReferenceDate)
        ].joined(separator: ":")
    }

    var body: some View {
        // Keep Image as the actual root view. In particular, do not put a
        // TimelineView or an empty Group around it: MenuBarExtra uses this
        // intrinsic image to measure and install its NSStatusItem.
        Image(
            nsImage: IconRenderer.menuBarImage(
                state: IconRenderer.MenuBarIconState(
                    isWorking: isWorking,
                    hasUnseenResult: hasUnseenResult,
                    coreOpacity: coreOpacity
                )
            )
        )
            .renderingMode(.template)
            .accessibilityLabel("Bobbin")
            .accessibilityValue(controller.statusItemAccessibilityValue)
        .onAppear {
            settlingStartedAt = nil
            coreOpacity = reduceMotion
                ? (isWorking ? 0.5 : 1)
                : (isWorking ? breathingOpacity(at: Date()) : 1)
        }
        .onChange(of: isWorking) { wasWorking, nowWorking in
            let now = Date()
            if nowWorking {
                if !wasWorking {
                    activityClock.reset(at: now)
                }
                settlingStartedAt = nil
                coreOpacity = reduceMotion ? 0.5 : breathingOpacity(at: now)
            } else if wasWorking {
                if reduceMotion {
                    settlingStartedAt = nil
                    settleFromOpacity = 1
                    coreOpacity = 1
                    return
                }
                // Preserve the alpha at the moment the final turn stopped,
                // then ease to the quiet full-opacity core in <=400 ms.
                settleFromOpacity = opacity(
                    at: now,
                    isWorking: true,
                    reduceMotion: false
                )
                settlingStartedAt = now
            }
        }
        .onChange(of: reduceMotion) { _, nowReduced in
            if nowReduced {
                // Reduce Motion also cancels an in-flight settle. Otherwise a
                // settle started before the preference changed could leave
                // the task paused forever with a partially faded core.
                settlingStartedAt = nil
                settleFromOpacity = 1
                coreOpacity = isWorking ? 0.5 : 1
            } else if isWorking {
                coreOpacity = breathingOpacity(at: Date())
            }
        }
        .task(id: animationTaskID) {
            await runAnimationLoop()
        }
    }

    private func opacity(
        at date: Date,
        isWorking: Bool,
        reduceMotion: Bool
    ) -> Double {
        if reduceMotion {
            return isWorking ? 0.5 : 1
        }

        if isWorking {
            return breathingOpacity(at: date)
        }

        guard let settlingStartedAt else { return 1 }
        return IconRenderer.MenuBarAnimation.settlingOpacity(
            from: settleFromOpacity,
            elapsed: date.timeIntervalSince(settlingStartedAt)
        )
    }

    /// Rows use this same absolute reference clock, so the menu-bar core and
    /// every running dot breathe in phase even when work starts at different
    /// times. The phase itself is presentation-only; it never changes state.
    private func breathingOpacity(at date: Date) -> Double {
        IconRenderer.MenuBarAnimation.breathingOpacity(
            elapsed: date.timeIntervalSince(activityClock.phaseStartedAt)
        )
    }

    @MainActor
    private func runAnimationLoop() async {
        guard !reduceMotion else {
            coreOpacity = isWorking ? 0.5 : 1
            return
        }

        guard isWorking || isSettling else {
            coreOpacity = 1
            return
        }

        let frameInterval = 1.0 / 12.0
        while !Task.isCancelled {
            let now = Date()
            if isWorking {
                coreOpacity = opacity(
                    at: now,
                    isWorking: true,
                    reduceMotion: false
                )
            } else if let startedAt = settlingStartedAt {
                let elapsed = max(0, now.timeIntervalSince(startedAt))
                coreOpacity = IconRenderer.MenuBarAnimation.settlingOpacity(
                    from: settleFromOpacity,
                    elapsed: elapsed
                )
                if elapsed >= IconRenderer.MenuBarAnimation.settleDuration {
                    coreOpacity = 1
                    settlingStartedAt = nil
                    return
                }
            } else {
                coreOpacity = 1
                return
            }

            let remaining = isWorking
                ? frameInterval
                : max(
                    0,
                    IconRenderer.MenuBarAnimation.settleDuration
                        - now.timeIntervalSince(settlingStartedAt ?? now)
                )
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(min(frameInterval, remaining) * 1_000_000_000)
                )
            } catch {
                return
            }
        }
    }
}
