import Foundation

public final class APIKeyProvider {
    public enum Source: String, Sendable {
        case processEnvironment = "OPENAI_API_KEY"
        case launchAgentEnvironment = "launchctl"
    }

    public init() {}

    public func detectedSource() -> Source? {
        if processEnvironmentKey() != nil { return .processEnvironment }
        if launchAgentKey() != nil { return .launchAgentEnvironment }
        return nil
    }

    public func readDetectedKey() -> String? {
        processEnvironmentKey() ?? launchAgentKey()
    }

    private func processEnvironmentKey() -> String? {
        normalized(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
    }

    private func launchAgentKey() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "OPENAI_API_KEY"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return normalized(String(data: data, encoding: .utf8))
        } catch {
            return nil
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
