import Foundation
import WorkspacesCore

/// The Mac app's tools, with the same names, for sessions on the server. Where the server works
/// differently (send_message presses Enter, open_session takes an account and a model, notify goes
/// to the phone) the description says so; the rest are the Mac's own.
public enum ServerTools {
    public static let instructions = "This session runs on the server under workspacesd, next to other Claude Code sessions in tmux. Use set_status at the start of long steps; use list_sessions to see sibling sessions. " + MCPServer.handoffRule

    private static func mac(_ name: String) -> ToolDefinition {
        WorkspaceTools.all.first { $0.name == name }!
    }

    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "list_sessions",
            description: "Lists the Claude Code sessions the server runs, grouped by workspace and project, with each one's state, id, account, model and context. Use it before open_session or send_message.",
            inputSchema: mac("list_sessions").inputSchema
        ),
        mac("set_status"),
        ToolDefinition(
            name: "open_session",
            description: "Opens a new Claude Code session on the server, in a project or in a folder, optionally in a new git worktree, with a first prompt, an account and a model.",
            inputSchema: WorkspaceTools.schema([
                "project": ("string", "Project name as list_sessions shows it. Give this or path."),
                "path": ("string", "Folder to run in; it becomes a project when it is not one yet. Give this or project."),
                "worktree": ("string", "Name for a new git worktree. Omit to run in the folder itself."),
                "prompt": ("string", "First message for the new session."),
                "account": ("string", "Account to run under, e.g. conta1 or conta2. Omit for the default."),
                "model": ("string", "Model for the session, e.g. opus or sonnet. Omit for the account's default."),
            ])
        ),
        ToolDefinition(
            name: "send_message",
            description: "Types a message into another session's prompt and presses Enter, so it is sent (a session in the middle of a turn gets it queued). Marks that session so the person sees it.",
            inputSchema: mac("send_message").inputSchema
        ),
        ToolDefinition(
            name: "notify",
            description: "Sends a push notification to the person's phone (ntfy), asking for their attention, with a short message.",
            inputSchema: mac("notify").inputSchema
        ),
        mac("close_session"),
        mac("recycle_self"),
        mac("recycle_session"),
    ]
}
