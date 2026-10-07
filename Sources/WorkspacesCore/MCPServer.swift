import Foundation

public struct ToolDefinition: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

public enum WorkspaceTools {
    /// `closed` forbids properties beyond the listed ones (the tools that must never carry free text).
    public static func schema(_ properties: [String: (String, String)], required: [String] = [], closed: Bool = false) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (name, (type, description)) in properties {
            props[name] = .object(["type": .string(type), "description": .string(description)])
        }
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ]
        if closed { schema["additionalProperties"] = .bool(false) }
        return .object(schema)
    }

    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "list_sessions",
            description: "Lists the Claude Code sessions open in the Workspaces app, grouped by workspace and project, with each one's state and id. Use it before open_session or send_message.",
            inputSchema: schema(["all_workspaces": ("boolean", "Include every workspace, not only this session's.")])
        ),
        ToolDefinition(
            name: "set_status",
            description: "Tells the Workspaces app, in a few words, what this session is doing right now (for example \"running the tests\"). The phrase shows in the sidebar and the grid. Call it when you start a long step.",
            inputSchema: schema(["text": ("string", "Short phrase, in the language the person uses.")], required: ["text"])
        ),
        ToolDefinition(
            name: "open_session",
            description: "Opens a new Claude Code session in a project of the Workspaces app, optionally in a new git worktree and with a first prompt.",
            inputSchema: schema([
                "project": ("string", "Project name as list_sessions shows it."),
                "worktree": ("string", "Name for a new git worktree. Omit to follow the project's setting."),
                "prompt": ("string", "First message for the new session."),
            ], required: ["project"])
        ),
        ToolDefinition(
            name: "send_message",
            description: "Types a message into another session's prompt without pressing Enter, and marks that session so the person sees it. Use it to hand context to a sibling session.",
            inputSchema: schema([
                "session": ("string", "Target session id (or its prefix) from list_sessions."),
                "text": ("string", "The message."),
            ], required: ["session", "text"])
        ),
        ToolDefinition(
            name: "notify",
            description: "Sends a macOS notification asking for the person's attention, with a short message.",
            inputSchema: schema(["text": ("string", "What the person should look at.")], required: ["text"])
        ),
        ToolDefinition(
            name: "close_session",
            description: "Closes another session of the same workspace that has finished or is idle. Refused while it is working or waiting, or while its worktree has changes not committed (git status shows anything modified or untracked). Logged in recycles.jsonl; the conversation's transcript stays on disk.",
            inputSchema: schema(["session": ("string", "Session id (or its prefix) from list_sessions.")], required: ["session"], closed: true)
        ),
        ToolDefinition(
            name: "recycle_self",
            description: "Starts this session over in a clean conversation without losing what matters, when the context passed the limit and the work goes on in this session. An item whose PR is open and has nothing left for this session is not recycled: write the Passagem, commit and stop, and the session is closed. First write the handoff: a section in the FRENTE.md at the root of this session's worktree whose title starts with \"Passagem\" and carries the date and time it was written (## Passagem 07/10 14h30), with the item in progress (branch, commit, PR), what is left and the exact next step, orders received and still pending, queued jobs and background tasks with their commands and state, who to report to, decisions, pitfalls. Commit everything. Then call this and end your turn. Refused unless the latest Passagem's title is from the last 30 minutes and git status is clean. When the turn ends, the app checks again, types /clear, checks once more that the session is stopped with nothing else in its input, logs the Passagem and the old transcript path in recycles.jsonl and only then sends it. The new conversation gets that Passagem with the branch, HEAD, pull request and background tasks, then a fixed message telling it to resume, and a few minutes later the app checks that it did. Takes no arguments.",
            inputSchema: schema([:], closed: true)
        ),
        ToolDefinition(
            name: "recycle_session",
            description: "Same as recycle_self, for another session of this workspace (an orchestrating session uses it). Refused while that session is in the middle of a turn, has text typed in its prompt, has no Passagem in its FRENTE.md dated in the last 30 minutes, or has changes not committed. If it starts working between the call and the /clear, the recycle waits for the end of that turn. Takes only the session id; never any text.",
            inputSchema: schema(["session": ("string", "Session id (or its prefix) from list_sessions.")], required: ["session"], closed: true)
        ),
    ]
}

/// MCP over stdio (newline-delimited JSON-RPC). Transport-free so it can be tested.
public final class MCPServer {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public static let appInstructions = "This session runs inside the Workspaces app, next to other Claude Code sessions. Use set_status at the start of long steps; use list_sessions to see sibling sessions. \(handoffRule)"

    /// The FRENTE.md rule, the same in the app and on the server.
    public static let handoffRule = "In projects that keep a FRENTE.md: when an item's PR is open and nothing is left for this session, write its Passagem section (title with date and time, ## Passagem 07/10 14h30), commit, and stop; the session is closed, not recycled. When the context passes the limit with work still to do, write the Passagem, commit, and call recycle_self."

    private let enabledTools: () -> [String]?
    private let callTool: (String, JSONValue) -> ToolResult
    private let tools: [ToolDefinition]
    private let instructions: String

    /// - Parameters:
    ///   - enabledTools: names the app allows now, or nil when the app is unreachable (all are listed).
    ///   - callTool: runs a tool.
    ///   - tools: the tools offered; the server daemon has its own descriptions.
    public init(enabledTools: @escaping () -> [String]?, callTool: @escaping (String, JSONValue) -> ToolResult,
                tools: [ToolDefinition] = WorkspaceTools.all, instructions: String = MCPServer.appInstructions) {
        self.enabledTools = enabledTools
        self.callTool = callTool
        self.tools = tools
        self.instructions = instructions
    }

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(_ message: JSONValue) -> JSONValue? {
        guard let method = message["method"]?.stringValue else { return nil }
        guard let id = message["id"], id != .null else { return nil }
        let params = message["params"] ?? .object([:])

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("workspaces"), "version": .string("0.1.0")]),
                "instructions": .string(instructions),
            ]))
        case "ping":
            return result(id, .object([:]))
        case "tools/list":
            let enabled = enabledTools()
            let tools = self.tools
                .filter { enabled?.contains($0.name) ?? true }
                .map { JSONValue.object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]) }
            return result(id, .object(["tools": .array(tools)]))
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return error(id, code: -32602, message: "missing tool name")
            }
            guard tools.contains(where: { $0.name == name }) else {
                return error(id, code: -32602, message: "unknown tool: \(name)")
            }
            let outcome = callTool(name, params["arguments"] ?? .object([:]))
            return result(id, .object([
                "content": .array([.object(["type": .string("text"), "text": .string(outcome.text)])]),
                "isError": .bool(outcome.isError),
            ]))
        default:
            return error(id, code: -32601, message: "method not found: \(method)")
        }
    }

    private func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private func error(_ id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
