import Foundation

/// What a Claude Code hook tells the app about a session.
public struct HookUpdate: Equatable, Sendable {
    /// The hook's event name ("SessionStart", "Stop"...).
    public var event: String
    public var status: SessionStatus?
    /// Shown under the session name, e.g. the permission Claude is asking for.
    public var message: String?
    public var claudeSessionId: String?
    public var cwd: String?
    /// The conversation's .jsonl, as Claude Code reports it.
    public var transcriptPath: String?
    /// SessionStart only: "startup", "resume", "clear", "compact" or "fork".
    public var source: String?
    /// True when the event starts a new task, so the old activity phrase no longer applies.
    public var clearsActivity: Bool
    /// A prompt was sent, so Claude now has a conversation it can resume.
    public var startsConversation: Bool
    /// UserPromptSubmit only: the text that was sent.
    public var prompt: String?

    public init(event: String = "", status: SessionStatus?, message: String? = nil, claudeSessionId: String? = nil,
                cwd: String? = nil, transcriptPath: String? = nil, source: String? = nil,
                clearsActivity: Bool = false, startsConversation: Bool = false, prompt: String? = nil) {
        self.event = event
        self.status = status
        self.message = message
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.source = source
        self.clearsActivity = clearsActivity
        self.startsConversation = startsConversation
        self.prompt = prompt
    }
}

public enum HookEvent {
    /// The events the app subscribes to in the settings it passes to `claude --settings`.
    public static let subscribed = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    public static func update(from payload: JSONValue) -> HookUpdate? {
        guard let event = payload["hook_event_name"]?.stringValue else { return nil }
        var update = HookUpdate(event: event, status: nil, claudeSessionId: payload["session_id"]?.stringValue,
                                cwd: payload["cwd"]?.stringValue, transcriptPath: payload["transcript_path"]?.stringValue)

        switch event {
        case "SessionStart":
            update.status = .idle
            update.source = payload["source"]?.stringValue
        case "UserPromptSubmit":
            update.status = .working
            update.clearsActivity = true
            update.startsConversation = true
            update.prompt = payload["prompt"]?.stringValue
        case "PostToolUse":
            // After a permission prompt is answered the tool runs, so this also clears "waiting".
            update.status = .working
        case "Notification":
            // Claude also notifies when a finished session has sat at its prompt for a while
            // ("idle_prompt"). That is not waiting for the person, so the state stays as it is.
            let type = payload["notification_type"]?.stringValue
            let message = payload["message"]?.stringValue
            let idleReminder = type == "idle_prompt"
                || (type == nil && message?.lowercased().contains("waiting for your input") == true)
            if !idleReminder {
                update.status = .waiting
                update.message = message
            }
        case "Stop":
            update.status = .done
        case "SessionEnd":
            // /clear and /resume end one conversation and start another in the same process.
            let reason = payload["reason"]?.stringValue
            if reason != "clear", reason != "resume" { update.status = .ended }
        default:
            break
        }
        return update
    }
}

/// What the hook helper prints for Claude Code. For SessionStart and UserPromptSubmit plain stdout
/// becomes context, so only a JSON object the app sent on purpose is printed, never an error text.
public enum HookReply {
    public static func stdout(_ reply: IPCResponse?) -> String? {
        guard let reply, reply.ok else { return nil }
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}"), case .object? = JSONValue.parse(Data(text.utf8)) else { return nil }
        return text + "\n"
    }
}

/// Hook output that adds context for Claude (`hookSpecificOutput.additionalContext`).
public enum HookOutput {
    public static func additionalContext(event: String, _ text: String) -> String {
        let value = JSONValue.object(["hookSpecificOutput": .object([
            "hookEventName": .string(event),
            "additionalContext": .string(text),
        ])])
        var line = value.encodedLine()
        line.removeLast()
        return String(decoding: line, as: UTF8.self)
    }
}
