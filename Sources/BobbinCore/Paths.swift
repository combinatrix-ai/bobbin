import Foundation

public struct HarnessPaths: Sendable {
    public let root: URL
    public let stateFile: URL
    public let codexHome: URL

    public init(root: URL? = nil) throws {
        let resolvedRoot: URL
        if let root {
            resolvedRoot = root
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            resolvedRoot = appSupport.appendingPathComponent("Bobbin", isDirectory: true)
        }

        self.root = resolvedRoot
        self.stateFile = resolvedRoot.appendingPathComponent("state.json")
        self.codexHome = resolvedRoot.appendingPathComponent("CodexHome", isDirectory: true)
    }

    /// Prefix for demo roots. Deletion is gated on it, so cleanup can never
    /// widen to a directory Bobbin did not create.
    public static let demoRootPrefix = "Bobbin-Demo-"

    /// A throwaway root under the system temporary directory.
    ///
    /// Demo mode reads and writes only here, so a demo run cannot observe or
    /// disturb the real `~/Library/Application Support/Bobbin`.
    public static func demo() throws -> HarnessPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(demoRootPrefix + UUID().uuidString, isDirectory: true)
        return try HarnessPaths(root: root)
    }

    /// True only for a root this process could have created for a demo run.
    public var isDemoRoot: Bool {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return root.lastPathComponent.hasPrefix(Self.demoRootPrefix)
            && root.standardizedFileURL.path.hasPrefix(temporary)
    }

    /// Removes a demo root, and refuses to remove anything else.
    public func removeDemoRoot() {
        guard isDemoRoot else { return }
        try? FileManager.default.removeItem(at: root)
    }

    public func prepare() throws {
        try createPrivateDirectory(root)
        try createPrivateDirectory(codexHome)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
