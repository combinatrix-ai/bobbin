import Foundation
import CoreFoundation

public enum RPCID: Hashable, Sendable {
    case integer(Int64)
    case string(String)

    init?(_ value: Any?) {
        if let string = value as? String { self = .string(string); return }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        self = .integer(number.int64Value)
    }

    var json: Any {
        switch self {
        case .integer(let value): value
        case .string(let value): value
        }
    }
}

public struct ServerRequestToken: Hashable, Sendable {
    let generation: UUID
    let id: RPCID
    let nonce: UUID
}

public enum ComputerUseApprovalTarget: Equatable, Sendable {
    case toolExecution(code: String)
    case nativeApp(identifier: String, name: String)
}

public struct ComputerUseApproval: Equatable, Sendable {
    public let threadID: String
    public let turnID: String?
    public let target: ComputerUseApprovalTarget
    public let message: String
    public let subtitle: String?

    public var scopeExplanation: String {
        switch target {
        case .toolExecution:
            "Computer Use can run desktop actions for this chat. App access is requested separately."
        case .nativeApp:
            "Computer Use can view and control this app for this chat."
        }
    }

    init?(method: String, params: [String: Any]) {
        guard method == "mcpServer/elicitation/request",
              params["serverName"] as? String == "cua_repl",
              let mode = params["mode"] as? String, ["form", "openai/form"].contains(mode),
              let schema = params["requestedSchema"] as? [String: Any],
              schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String: Any], properties.isEmpty,
              Set(schema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties"]),
              schema["required"] == nil || (schema["required"] as? [String]) == [],
              schema["additionalProperties"] == nil || (schema["additionalProperties"] as? Bool) == false,
              let meta = params["_meta"] as? [String: Any],
              meta["codex_approval_kind"] as? String == "mcp_tool_call",
              let tool = meta["tool_params"] as? [String: Any],
              let thread = Self.nonempty(params["threadId"]),
              let message = Self.nonempty(params["message"]),
              params["turnId"] == nil || params["turnId"] is NSNull || Self.nonempty(params["turnId"]) != nil
        else { return nil }

        if meta["connector_id"] as? String == "computer-use" {
            guard let app = Self.nonempty(tool["app"]) else { return nil }
            let display = meta["tool_params_display"] as? [[String: Any]]
            let name = display?.first(where: { $0["name"] as? String == "app" }).flatMap { Self.nonempty($0["value"]) } ?? app
            target = .nativeApp(identifier: app, name: name)
            self.message = message
        } else {
            guard meta["connector_id"] == nil,
                  tool["app"] == nil,
                  message == "Allow the cua_repl MCP server to run tool \"js\"?",
                  Set(tool.keys).isSubset(of: ["code", "title", "timeout_ms"]),
                  let code = Self.nonempty(tool["code"]),
                  tool["title"] == nil || tool["title"] is String,
                  tool["timeout_ms"] == nil || Self.isPositiveInteger(tool["timeout_ms"])
            else { return nil }
            target = .toolExecution(code: code)
            self.message = "Allow Computer Use for this chat?"
        }
        self.threadID = thread
        self.turnID = params["turnId"] as? String
        self.subtitle = Self.nonempty(meta["subtitle"])
    }

    private static func isPositiveInteger(_ value: Any?) -> Bool {
        guard case .integer(let number) = RPCID(value) else { return false }
        return number > 0
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }
}

public enum ComputerUseDecision: String, Sendable {
    case allowForChat, decline, cancel

    var result: [String: Any] {
        switch self {
        case .allowForChat: ["action": "accept", "content": [String: Any](), "_meta": ["persist": "session"]]
        case .decline: ["action": "decline", "content": NSNull()]
        case .cancel: ["action": "cancel", "content": NSNull()]
        }
    }
}

public struct PendingComputerUseApproval: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let localThreadID: UUID
    public let approval: ComputerUseApproval
    let token: ServerRequestToken
    let activeTurnID: String
    let expiresAt: Date
}
