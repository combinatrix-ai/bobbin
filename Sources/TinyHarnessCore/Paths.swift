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
