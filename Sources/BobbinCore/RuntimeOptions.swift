import Foundation

/// Options resolved once, from the process the user actually launched.
///
/// Parsing lives in its own type so the demo switch can be proven correct in a
/// test rather than inferred from wherever it happens to be read.
public struct RuntimeOptions: Equatable, Sendable {
    /// Runs the app against deterministic in-process fixtures in an isolated
    /// temporary state root.
    ///
    /// Demo mode never launches `codex app-server`, never reads a credential,
    /// never touches the real application-support directory and never reaches
    /// the network. It exists so the product can be shown and captured without
    /// exposing anything real.
    public var demoMode: Bool
    /// The JSON state file supplied for a demo run, if any.
    public var demoDataPath: String?
    /// A command-line shape error that must be shown instead of selecting the
    /// built-in fixture.
    public var demoDataError: String?

    public init(
        demoMode: Bool = false,
        demoDataPath: String? = nil,
        demoDataError: String? = nil
    ) {
        self.demoMode = demoMode || demoDataPath != nil || demoDataError != nil
        self.demoDataPath = demoDataPath
        self.demoDataError = demoDataError
    }

    /// The exact flag. Nothing is inferred from prefixes, so an unrelated
    /// argument such as `--demo-mode-notes` cannot switch the app into a fake
    /// data set by accident.
    public static let demoFlag = "--demo-mode"
    public static let demoEnvironmentKey = "BOBBIN_DEMO_MODE"
    public static let demoDataFlag = "--demo-data"
    public static let demoDataEnvironmentKey = "BOBBIN_DEMO_DATA"

    private static let truthyValues: Set<String> = ["1", "true", "yes", "on"]

    public static func fromProcess(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RuntimeOptions {
        // Drop the executable path: an app installed at a path that happens to
        // contain the flag text must not enable demo mode.
        let flags = Array(arguments.dropFirst())
        let hasFlag = flags.contains(demoFlag)

        let raw = environment[demoEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasEnvironment = truthyValues.contains(raw ?? "")

        var argumentDataPath: String?
        var argumentDataError: String?
        var index = 0
        while index < flags.count {
            if flags[index] == demoDataFlag {
                guard index + 1 < flags.count,
                      !flags[index + 1].hasPrefix("--") else {
                    argumentDataError = "Missing a path after \(demoDataFlag)."
                    index += 1
                    continue
                }

                let path = flags[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if path.isEmpty {
                    argumentDataError = "Missing a path after \(demoDataFlag)."
                } else {
                    argumentDataPath = path
                    argumentDataError = nil
                }
                index += 2
                continue
            }
            index += 1
        }

        let dataPath: String?
        let dataError: String?
        if argumentDataPath != nil || argumentDataError != nil {
            dataPath = argumentDataPath
            dataError = argumentDataError
        } else if let rawDataPath = environment[demoDataEnvironmentKey] {
            let path = rawDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty {
                dataPath = nil
                dataError = "\(demoDataEnvironmentKey) is set but empty."
            } else {
                dataPath = path
                dataError = nil
            }
        } else {
            dataPath = nil
            dataError = nil
        }

        return RuntimeOptions(
            demoMode: hasFlag || hasEnvironment,
            demoDataPath: dataPath,
            demoDataError: dataError
        )
    }
}
