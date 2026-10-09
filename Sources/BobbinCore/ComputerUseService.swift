import Foundation
import CryptoKit
import Darwin

struct ComputerUseError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SignedBundleIdentity: Equatable, Codable, Sendable {
    let codeHash: String
    let version: String
    let build: String
}

protocol ComputerUseSignatureInspecting: Sendable {
    func inspect(_ bundle: URL, identifier: String?) throws -> SignedBundleIdentity
}

struct SystemSignatureInspector: ComputerUseSignatureInspecting {
    func inspect(_ bundle: URL, identifier: String?) throws -> SignedBundleIdentity {
        var requirement = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
        if let identifier { requirement += " and identifier \"\(identifier)\"" }
        _ = try ComputerUseService.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R=" + requirement, bundle.path])
        let details = try ComputerUseService.run("/usr/bin/codesign", ["-d", "--verbose=4", bundle.path])
        guard let hash = details.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") }).map({ String($0.dropFirst(7)) }), !hash.isEmpty,
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else {
            throw ComputerUseError("Could not read the signed Computer Use version.")
        }
        return SignedBundleIdentity(codeHash: hash, version: version, build: build)
    }
}

struct DesktopComputerUseSource: Sendable {
    let resources: URL
    let fingerprint: String
    let serviceIdentity: SignedBundleIdentity
    let clientIdentity: SignedBundleIdentity
    var executable: URL { resources.appendingPathComponent("codex-cli/CodexCLI.app/Contents/MacOS/codex") }
    var runtime: URL { resources.appendingPathComponent("cua_node") }
    var modules: URL { runtime.appendingPathComponent("lib/node_modules") }
    var marketplace: URL { resources.appendingPathComponent("plugins/openai-bundled") }
    var plugin: URL { marketplace.appendingPathComponent("plugins/unified-computer-use") }
    var service: URL { modules.appendingPathComponent("@oai/sky/Codex Computer Use.app") }

    func assertCurrent() throws {
        try Task.checkCancellation()
        guard try Self.fingerprint(resources) == fingerprint else {
            throw ComputerUseError("The desktop updated while Computer Use was starting. Restart Bobbin to try again.")
        }
    }

    static func fingerprint(_ resources: URL) throws -> String {
        try ComputerUseService.digest([
            resources.appendingPathComponent("cua_node"),
            resources.appendingPathComponent("plugins/openai-bundled/plugins/unified-computer-use"),
            resources.appendingPathComponent("plugins/openai-bundled/.agents/plugins/marketplace.json"),
            resources.appendingPathComponent("codex-cli/CodexCLI.app"),
            resources.appendingPathComponent("../Info.plist").standardizedFileURL
        ])
    }
}

final class OwnedComputerUseDirectory {
    let url: URL
    let descriptor: Int32
    private let identity: stat

    init(_ url: URL, create: Bool = false) throws {
        self.url = url.standardized
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ComputerUseError("Cannot open the filesystem root.") }
        do {
            for component in self.url.pathComponents.dropFirst() {
                if create && mkdirat(fd, component, 0o700) != 0 && errno != EEXIST {
                    throw ComputerUseError("Cannot create an owned Computer Use directory.")
                }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ComputerUseError("Computer Use refuses a symlink or inaccessible directory (\(component), errno \(errno)).") }
                close(fd)
                fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw ComputerUseError("Computer Use requires a private directory owned by this user.")
            }
            if create && fchmod(fd, 0o700) != 0 {
                throw ComputerUseError("Cannot make the owned Computer Use directory private.")
            }
            identity = info
            descriptor = fd
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(descriptor) }

    func assertStable() throws {
        let current = try OwnedComputerUseDirectory(url)
        guard current.identity.st_dev == identity.st_dev, current.identity.st_ino == identity.st_ino else {
            throw ComputerUseError("The owned Computer Use directory changed during preparation.")
        }
    }

    func assertRegularFileOrAbsent(_ name: String) throws {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw ComputerUseError("Cannot inspect the owned Computer Use configuration.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw ComputerUseError("Computer Use refuses a linked or unowned configuration file.")
        }
    }
}

struct ComputerUseService: Sendable {
    let inspector: any ComputerUseSignatureInspecting
    static let clientPath = "Contents/SharedSupport/SkyComputerUseClient.app"
    static let ownerFile = ".bobbin-owner.json"

    init(inspector: any ComputerUseSignatureInspecting = SystemSignatureInspector()) { self.inspector = inspector }

    func discover(applications: [URL] = [URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app")]) throws -> DesktopComputerUseSource? {
        for app in applications {
            let resources = app.appendingPathComponent("Contents/Resources")
            let executable = resources.appendingPathComponent("codex-cli/CodexCLI.app/Contents/MacOS/codex")
            let runtime = resources.appendingPathComponent("cua_node")
            let service = runtime.appendingPathComponent("lib/node_modules/@oai/sky/Codex Computer Use.app")
            let plugin = resources.appendingPathComponent("plugins/openai-bundled/plugins/unified-computer-use/.mcp.json")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("bin/node").path),
                  FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("bin/node_repl").path),
                  FileManager.default.fileExists(atPath: plugin.path) else { continue }
            _ = try inspector.inspect(app, identifier: nil)
            let before = try DesktopComputerUseSource.fingerprint(resources)
            let serviceID = try inspector.inspect(service, identifier: "com.openai.sky.CUAService")
            let clientID = try inspector.inspect(service.appendingPathComponent(Self.clientPath), identifier: "com.openai.sky.CUAService.cli")
            let source = DesktopComputerUseSource(resources: resources, fingerprint: before, serviceIdentity: serviceID, clientIdentity: clientID)
            try source.assertCurrent()
            return source
        }
        return nil
    }

    func prepare(source: DesktopComputerUseSource, home: URL, heldPreparation: ComputerUsePreparationLock? = nil) throws -> ComputerUseInstallation {
        let root = try OwnedComputerUseDirectory(home)
        try root.assertRegularFileOrAbsent("config.toml")
        let preparation = try heldPreparation ?? ComputerUsePreparationLock(home: home)
        defer { withExtendedLifetime(preparation) {} }
        try source.assertCurrent()
        var publications: [OwnedComputerUsePublication] = []
        do {
            let publication = try publish(parent: root, name: "computer-use", fingerprint: source.fingerprint, build: { stage in
                let app = stage.appendingPathComponent("Codex Computer Use.app")
                _ = try Self.run("/usr/bin/ditto", [source.service.path, app.path])
            }, validate: { directory in
                let app = directory.appendingPathComponent("Codex Computer Use.app")
                guard try inspector.inspect(app, identifier: "com.openai.sky.CUAService") == source.serviceIdentity,
                      try inspector.inspect(app.appendingPathComponent(Self.clientPath), identifier: "com.openai.sky.CUAService.cli") == source.clientIdentity else {
                    throw ComputerUseError("The staged Computer Use signature does not match its desktop source.")
                }
            }, current: source.assertCurrent)
            publications.append(publication)
            _ = try OwnedComputerUseDirectory(home.appendingPathComponent(".tmp"), create: true)
            let parent = try OwnedComputerUseDirectory(home.appendingPathComponent(".tmp/bundled-marketplaces"), create: true)
            let marketplacePublication = try publish(parent: parent, name: "openai-bundled", fingerprint: source.fingerprint, build: { stage in
                try makeMarketplace(source: source, home: home, stage: stage)
            }, validate: { directory in
                try Self.assertNoSymlinks(directory)
            }, current: source.assertCurrent)
            publications.append(marketplacePublication)
            try root.assertStable()
            try root.assertRegularFileOrAbsent("config.toml")
            try source.assertCurrent()
            return ComputerUseInstallation(
                marketplace: parent.url.appendingPathComponent("openai-bundled"),
                publications: publications,
                preparation: preparation
            )
        } catch {
            for publication in publications.reversed() { try publication.rollback() }
            throw error
        }
    }

    private func makeMarketplace(source: DesktopComputerUseSource, home: URL, stage: URL) throws {
        var manifest = try Self.object(source.marketplace.appendingPathComponent(".agents/plugins/marketplace.json"))
        guard manifest["name"] as? String == "openai-bundled", let entries = manifest["plugins"] as? [[String: Any]] else {
            throw ComputerUseError("The desktop marketplace manifest is invalid.")
        }
        let plugins = entries.filter { $0["name"] as? String == "unified-computer-use" }
        guard plugins.count == 1 else { throw ComputerUseError("The desktop Computer Use plugin is missing.") }
        manifest["plugins"] = plugins
        let manifestDirectory = stage.appendingPathComponent(".agents/plugins")
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.write(manifest, to: manifestDirectory.appendingPathComponent("marketplace.json"))
        let plugin = stage.appendingPathComponent("plugins/unified-computer-use")
        try Self.assertNoSymlinks(source.plugin)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for entry in try FileManager.default.contentsOfDirectory(at: source.plugin, includingPropertiesForKeys: nil) where entry.lastPathComponent != ".mcp.json" {
            try FileManager.default.copyItem(at: entry, to: plugin.appendingPathComponent(entry.lastPathComponent))
        }
        let pluginManifest = try Self.object(plugin.appendingPathComponent(".codex-plugin/plugin.json"))
        guard pluginManifest["name"] as? String == "unified-computer-use", pluginManifest["mcpServers"] as? String == "./.mcp.json" else {
            throw ComputerUseError("The desktop Computer Use plugin manifest is invalid.")
        }
        var template = try Self.object(source.plugin.appendingPathComponent(".mcp.json"))
        guard let servers = template["mcpServers"] as? [String: Any], var server = servers["cua_repl"] as? [String: Any] else {
            throw ComputerUseError("The desktop Computer Use template is invalid.")
        }
        let node = source.runtime.appendingPathComponent("bin/node").path
        server["command"] = node
        server["args"] = [source.modules.appendingPathComponent("@oai/cua-repl/bin/cua-repl.mjs").path]
        server["enabled"] = true
        server["env_vars"] = [String]()
        server["env"] = [
            "CODEX_HOME": home.path,
            "CUA_REPL_NODE_REPL_PATH": source.runtime.appendingPathComponent("bin/node_repl").path,
            "CUA_REPL_ENABLED_SURFACES": "computer",
            "NODE_REPL_NODE_PATH": node,
            "NODE_REPL_NODE_MODULE_DIRS": source.modules.path,
            "NODE_REPL_TRUSTED_CODE_PATHS": home.path + ":" + source.modules.path,
            "NODE_REPL_TRUSTED_SERVICES": "{\"sky\":\"@oai/sky/service\"}",
            "NODE_REPL_JS_BANNER": "await import(\"@oai/cua/tinyskyAlt\");",
            "SKY_CUA_SERVICE_PATH": home.appendingPathComponent("computer-use/Codex Computer Use.app").path
        ]
        template["mcpServers"] = ["cua_repl": server]
        try Self.write(template, to: plugin.appendingPathComponent(".mcp.json"))
    }

    func publish(parent: OwnedComputerUseDirectory, name: String, fingerprint: String, build: (URL) throws -> Void, validate: (URL) throws -> Void, current: () throws -> Void) throws -> OwnedComputerUsePublication {
        try parent.assertStable()
        let target = parent.url.appendingPathComponent(name)
        var info = stat()
        let exists = fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if !exists && errno != ENOENT { throw ComputerUseError("Cannot inspect the Computer Use destination.") }
        let prior = exists ? try OwnedComputerUseEntry(parent: parent, name: name, kind: name) : nil
        if let prior, prior.source == fingerprint {
            try validate(target)
            try current()
            return OwnedComputerUsePublication(parent: parent, name: name, published: prior, previous: .unchanged)
        }
        let stageName = ".\(name)-stage-\(UUID().uuidString)"
        guard mkdirat(parent.descriptor, stageName, 0o700) == 0 else { throw ComputerUseError("Cannot stage Computer Use.") }
        let stage = parent.url.appendingPathComponent(stageName)
        var stagedInfo = stat()
        guard fstatat(parent.descriptor, stageName, &stagedInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw ComputerUseError("Cannot inspect Computer Use staging.") }
        var published = false
        defer {
            if !published, (try? parent.assertStable()) != nil {
                var latest = stat()
                if fstatat(parent.descriptor, stageName, &latest, AT_SYMLINK_NOFOLLOW) == 0,
                   latest.st_dev == stagedInfo.st_dev, latest.st_ino == stagedInfo.st_ino {
                    try? FileManager.default.removeItem(at: stage)
                }
            }
        }
        try build(stage)
        try validate(stage)
        try Self.write(["owner": "bobbin", "kind": name, "source": fingerprint, "digest": try Self.payloadDigest(stage)], to: stage.appendingPathComponent(Self.ownerFile))
        let staged = try OwnedComputerUseEntry(parent: parent, name: stageName, kind: name)
        try current()
        try parent.assertStable()
        try prior?.assertMatches(parent: parent, name: name)
        try staged.assertMatches(parent: parent, name: stageName)
        let flags = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(parent.descriptor, stageName, parent.descriptor, name, flags) == 0 else { throw ComputerUseError("Cannot publish the staged Computer Use installation.") }
        published = true
        let publication = OwnedComputerUsePublication(
            parent: parent,
            name: name,
            published: staged,
            previous: prior.map { .backup(name: stageName, entry: $0) } ?? .absent(cleanupName: stageName)
        )
        do {
            try publication.validate()
            try validate(target)
            try current()
        } catch {
            try publication.rollback()
            throw error
        }
        return publication
    }

    static func payloadDigest(_ directory: URL) throws -> String {
        try digest(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ownerFile }.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    static func digest(_ roots: [URL]) throws -> String {
        var hash = SHA256()
        func visit(_ url: URL, relative: String) throws {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            hash.update(data: Data(relative.utf8))
            if values.isSymbolicLink == true {
                hash.update(data: Data(("link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))).utf8))
            } else if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            }
        }
        for (index, root) in roots.enumerated() { try visit(root, relative: "\(index)/\(root.lastPathComponent)") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func assertNoSymlinks(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw ComputerUseError("Computer Use refuses symlinked managed plugin files.") }
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try assertNoSymlinks(child) }
        }
    }

    static func object(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ComputerUseError("Computer Use found an invalid or linked manifest.")
        }
        return object
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ComputerUseError("Computer Use verification failed (\(URL(fileURLWithPath: executable).lastPathComponent), status \(process.terminationStatus)).") }
        return String(decoding: data, as: UTF8.self)
    }
}

struct OwnedComputerUseEntry: Equatable {
    let device: dev_t
    let inode: ino_t
    let receiptDevice: dev_t
    let receiptInode: ino_t
    let receipt: Data
    let digest: String
    let source: String
    let kind: String

    init(parent: OwnedComputerUseDirectory, name: String, kind: String) throws {
        try parent.assertStable()
        var directory = stat()
        guard fstatat(parent.descriptor, name, &directory, AT_SYMLINK_NOFOLLOW) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid() else {
            throw ComputerUseError("Refusing to touch a replaced Computer Use directory.")
        }
        let path = parent.url.appendingPathComponent(name)
        let owned = try OwnedComputerUseDirectory(path)
        var receiptInfo = stat()
        guard fstatat(owned.descriptor, ComputerUseService.ownerFile, &receiptInfo, AT_SYMLINK_NOFOLLOW) == 0,
              receiptInfo.st_mode & S_IFMT == S_IFREG, receiptInfo.st_uid == getuid(), receiptInfo.st_nlink == 1 else {
            throw ComputerUseError("Refusing to touch a replaced Computer Use ownership receipt.")
        }
        let receipt = try Data(contentsOf: path.appendingPathComponent(ComputerUseService.ownerFile))
        guard let object = try JSONSerialization.jsonObject(with: receipt) as? [String: Any] else {
            throw ComputerUseError("The Computer Use ownership receipt is invalid.")
        }
        let digest = try ComputerUseService.payloadDigest(path)
        guard object["owner"] as? String == "bobbin", object["kind"] as? String == kind,
              object["digest"] as? String == digest, let source = object["source"] as? String else {
            throw ComputerUseError("Refusing to touch an edited Computer Use installation.")
        }
        self.device = directory.st_dev
        self.inode = directory.st_ino
        self.receiptDevice = receiptInfo.st_dev
        self.receiptInode = receiptInfo.st_ino
        self.receipt = receipt
        self.digest = digest
        self.source = source
        self.kind = kind
    }

    func assertMatches(parent: OwnedComputerUseDirectory, name: String) throws {
        guard try OwnedComputerUseEntry(parent: parent, name: name, kind: kind) == self else {
            throw ComputerUseError("Computer Use publication or backup changed. The changed paths were preserved.")
        }
    }
}

final class OwnedComputerUsePublication {
    enum Previous {
        case unchanged
        case absent(cleanupName: String)
        case backup(name: String, entry: OwnedComputerUseEntry)
    }

    private let parent: OwnedComputerUseDirectory
    private let name: String
    private let published: OwnedComputerUseEntry
    private let previous: Previous
    private var settled = false

    init(parent: OwnedComputerUseDirectory, name: String, published: OwnedComputerUseEntry, previous: Previous) {
        self.parent = parent
        self.name = name
        self.published = published
        self.previous = previous
    }

    func validate() throws {
        guard !settled else { return }
        try published.assertMatches(parent: parent, name: name)
        if case .backup(let backupName, let entry) = previous {
            try entry.assertMatches(parent: parent, name: backupName)
        }
    }

    func commit() throws {
        guard !settled else { return }
        try validate()
        cleanupAfterActivation()
    }

    func cleanupAfterActivation(beforeCleanup: () throws -> Void = {}) {
        guard !settled else { return }
        defer { settled = true }
        do {
            try beforeCleanup()
            try validate()
            if case .backup(let backupName, let entry) = previous {
                try entry.assertMatches(parent: parent, name: backupName)
                try FileManager.default.removeItem(at: parent.url.appendingPathComponent(backupName))
            }
        } catch {
        }
    }

    func rollback() throws {
        guard !settled else { return }
        try validate()
        let cleanupName: String
        switch previous {
        case .unchanged:
            settled = true
            return
        case .absent(let name):
            cleanupName = name
            guard renameatx_np(parent.descriptor, self.name, parent.descriptor, cleanupName, UInt32(RENAME_EXCL)) == 0 else {
                throw ComputerUseError("Computer Use rollback could not remove its new installation.")
            }
        case .backup(let name, _):
            cleanupName = name
            guard renameatx_np(parent.descriptor, cleanupName, parent.descriptor, self.name, UInt32(RENAME_SWAP)) == 0 else {
                throw ComputerUseError("Computer Use rollback could not restore the prior installation.")
            }
        }
        settled = true
        try published.assertMatches(parent: parent, name: cleanupName)
        try FileManager.default.removeItem(at: parent.url.appendingPathComponent(cleanupName))
    }
}

final class ComputerUseInstallation: @unchecked Sendable {
    let marketplace: URL
    private let publications: [OwnedComputerUsePublication]
    private var preparation: ComputerUsePreparationLock?
    private enum State { case pending, committed, rolledBack }
    private var state = State.pending

    init(marketplace: URL, publications: [OwnedComputerUsePublication], preparation: ComputerUsePreparationLock) {
        self.marketplace = marketplace
        self.publications = publications
        self.preparation = preparation
    }

    func commit(beforeCleanup: ((Int) throws -> Void)? = nil) throws {
        guard state == .pending else { return }
        for publication in publications { try publication.validate() }
        try Task.checkCancellation()
        state = .committed
        defer { preparation = nil }
        for (index, publication) in publications.enumerated() {
            publication.cleanupAfterActivation { try beforeCleanup?(index) }
        }
    }

    func rollback() throws {
        guard state == .pending else { return }
        for publication in publications { try publication.validate() }
        for publication in publications.reversed() { try publication.rollback() }
        state = .rolledBack
        preparation = nil
    }
}

final class ComputerUsePreparationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(home: URL) throws {
        let root = try OwnedComputerUseDirectory(home)
        try root.assertRegularFileOrAbsent(".bobbin-computer-use.lock")
        let fd = openat(root.descriptor, ".bobbin-computer-use.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ComputerUseError("Cannot lock Computer Use preparation.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ComputerUseError("Another Bobbin process is preparing Computer Use, or its lock file is unsafe.")
        }
        descriptor = fd
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
