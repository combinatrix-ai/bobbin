import Foundation

public enum ComputerUseState: Equatable, Sendable {
    case unavailable(String)
    case disabled(String)
    case ready
    case failed(String)

    public var settingsLabel: String {
        switch self {
        case .ready: "Ready"
        case .unavailable(let reason): "Unavailable. " + reason
        case .disabled(let reason): "Disabled. " + reason
        case .failed(let reason): "Could not start. " + reason
        }
    }
}

struct ComputerUseRuntime: Sendable {
    let source: DesktopComputerUseSource?
    let initialState: ComputerUseState
    let service: ComputerUseService

    static func discover() async -> ComputerUseRuntime {
        await Task.detached {
            let service = ComputerUseService()
            do {
                let source = try service.discover()
                return ComputerUseRuntime(source: source, initialState: .unavailable("Install the OpenAI desktop app to enable Computer Use."), service: service)
            } catch {
                return ComputerUseRuntime(source: nil, initialState: .failed(error.localizedDescription), service: service)
            }
        }.value
    }

    func prepare(using client: any HarnessAppServerClient, home: URL) async -> ComputerUseState {
        guard let source else { return initialState }
        var installation: ComputerUseInstallation?
        do {
            let policy = try await effectivePolicy(client)
            if let veto = Self.policyVeto(policy) { return .disabled(veto) }
            try Task.checkCancellation()
            let preparation = try ComputerUsePreparationLock(home: home)
            defer { withExtendedLifetime(preparation) {} }
            let provisioning = Task.detached {
                try service.prepare(source: source, home: home, heldPreparation: preparation)
            }
            let prepared = try await withTaskCancellationHandler {
                try await provisioning.value
            } onCancel: {
                provisioning.cancel()
            }
            installation = prepared
            let marketplace = prepared.marketplace
            try Task.checkCancellation()
            if let veto = Self.policyVeto(try await effectivePolicy(client)) { throw ComputerUsePolicyDisabled(reason: veto) }
            try source.assertCurrent()
            let root = try OwnedComputerUseDirectory(home)
            try root.assertRegularFileOrAbsent("config.toml")
            _ = try await client.request(method: "experimentalFeature/enablement/set", params: ["enablement": ["plugins": true]])
            _ = try await client.request(method: "marketplace/add", params: ["source": marketplace.path])
            let list = try await client.request(method: "plugin/list", params: ["marketplaceKinds": ["local"], "forceRefetch": false])
            let expected = marketplace.appendingPathComponent(".agents/plugins/marketplace.json").path
            guard let markets = list["marketplaces"] as? [[String: Any]],
                  let owned = markets.first(where: { $0["path"] as? String == expected }),
                  let plugins = owned["plugins"] as? [[String: Any]],
                  let plugin = plugins.first(where: { $0["name"] as? String == "unified-computer-use" }),
                  plugin["availability"] as? String != "DISABLED_BY_ADMIN",
                  plugin["installPolicy"] as? String != "NOT_AVAILABLE" else {
                throw ComputerUseError("The owned Computer Use marketplace is not available.")
            }
            let parameters: [String: Any] = ["marketplacePath": expected, "pluginName": "unified-computer-use"]
            _ = try await client.request(method: "plugin/read", params: parameters)
            if let veto = Self.policyVeto(try await effectivePolicy(client)) { throw ComputerUsePolicyDisabled(reason: veto) }
            try root.assertStable()
            try root.assertRegularFileOrAbsent("config.toml")
            try source.assertCurrent()
            _ = try await client.request(method: "plugin/install", params: parameters)
            _ = try await client.request(method: "config/mcpServer/reload", params: [:])
            var cursor: String?
            var seen = Set<String>()
            for _ in 0..<20 {
                var parameters: [String: Any] = ["limit": 100]
                if let cursor { parameters["cursor"] = cursor }
                let response = try await client.request(method: "mcpServerStatus/list", params: parameters)
                guard let servers = response["data"] as? [[String: Any]] else { throw ComputerUseError("Computer Use status is invalid.") }
                if servers.contains(where: { $0["name"] as? String == "cua_repl" && ($0["tools"] as? [String: Any])?["js"] != nil }) {
                    if let veto = Self.policyVeto(try await effectivePolicy(client)) { throw ComputerUsePolicyDisabled(reason: veto) }
                    try root.assertStable()
                    try root.assertRegularFileOrAbsent("config.toml")
                    try source.assertCurrent()
                    try Task.checkCancellation()
                    try prepared.commit()
                    return .ready
                }
                guard let next = response["nextCursor"] as? String, !next.isEmpty, seen.insert(next).inserted else { break }
                cursor = next
            }
            throw ComputerUseError("The native cua_repl.js tool is not available.")
        } catch {
            do { try installation?.rollback() } catch {
                return .failed("Could not safely restore Computer Use. " + error.localizedDescription)
            }
            if let disabled = error as? ComputerUsePolicyDisabled { return .disabled(disabled.reason) }
            return .failed(error.localizedDescription)
        }
    }

    private struct ComputerUsePolicyDisabled: Error {
        let reason: String
    }

    private func effectivePolicy(_ client: any HarnessAppServerClient) async throws -> [String: Any] {
        let result = try await client.request(method: "config/read", params: ["includeLayers": false])
        guard let config = result["config"] as? [String: Any] else { throw ComputerUseError("Could not inspect effective Computer Use policy.") }
        return config
    }

    static func policyVeto(_ config: [String: Any]) -> String? {
        if (config["features"] as? [String: Any])?["plugins"] as? Bool == false { return "Plugins are disabled in Codex policy." }
        let plugins = config["plugins"] as? [String: Any] ?? [:]
        for name in ["computer-use@openai-bundled", "unified-computer-use@openai-bundled"] {
            let plugin = plugins[name] as? [String: Any] ?? [:]
            if plugin["enabled"] as? Bool == false { return "Computer Use is disabled in Codex policy." }
            if let servers = plugin["mcp_servers"] as? [String: Any], !servers.isEmpty {
                return "Existing Computer Use plugin restrictions are preserved."
            }
        }
        let servers = config["mcp_servers"] as? [String: Any] ?? [:]
        if servers["computer-use"] != nil { return "Existing legacy Computer Use policy is preserved." }
        if let server = servers["cua_repl"] as? [String: Any] {
            if server["enabled"] as? Bool == false { return "The native Computer Use server is disabled." }
            if ["enabled_tools", "disabled_tools", "tools", "command", "args", "env", "url"].contains(where: { server[$0] != nil }) {
                return "Existing native Computer Use server restrictions are preserved."
            }
        }
        return nil
    }
}
