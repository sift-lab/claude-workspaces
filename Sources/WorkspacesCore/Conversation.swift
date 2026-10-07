import Foundation

/// Which Claude Code conversation a session is in, and which one `claude --resume` should open.
///
/// Hooks arrive from separate helper processes, so their order is not guaranteed: Claude Code
/// caps the SessionEnd hooks of a `/clear` at 1.5 s and moves on, and a slow helper can deliver
/// the old conversation's SessionEnd after the new one's SessionStart. A conversation that ended
/// or was replaced is therefore never adopted again from a late hook, only from a resume.
public struct ConversationTracker: Equatable, Sendable {
    /// The conversation Claude Code is in now (token readings, list_sessions, reminders).
    public private(set) var current: String?
    /// The conversation to reopen with `--resume`. Nil while the current one has no message yet
    /// (a fresh start, or right after a `/clear`): Claude Code cannot resume an empty conversation.
    public private(set) var resumable: String?
    /// Conversations that ended or were replaced, newest last.
    public private(set) var finished: [String] = []

    static let finishedLimit = 32

    public init(saved: String?) {
        current = saved
        resumable = saved
    }

    /// Applies a hook. Returns true when `resumable` changed, so the saved session must be written.
    @discardableResult
    public mutating func apply(_ update: HookUpdate) -> Bool {
        guard let id = update.claudeSessionId, !id.isEmpty else { return false }
        let before = resumable
        switch update.event {
        case "SessionEnd":
            // It names the conversation that ended, never the next one.
            finish(id)
        case "SessionStart":
            switch update.source {
            case "clear", "startup":
                // A new, empty conversation. Nothing to resume until it gets a message.
                guard id != current else { break }
                if let current { finish(current) }
                current = id
                resumable = nil
            default:
                // "resume", "compact" and the rest open a conversation that already has messages.
                finished.removeAll { $0 == id }
                if let current, current != id { finish(current) }
                current = id
                resumable = id
            }
        default:
            // Only events that mean the conversation has a message. Claude Code's reminder that the
            // prompt sat idle also comes for an empty conversation, which --resume could not open.
            guard Self.carriesAMessage(update) else { break }
            if id == current {
                resumable = id
            } else if !finished.contains(id) {
                // The SessionStart was missed; a message in a conversation we never saw end is the live one.
                if let current { finish(current) }
                current = id
                resumable = id
            }
        }
        return resumable != before
    }

    static func carriesAMessage(_ update: HookUpdate) -> Bool {
        switch update.event {
        case "UserPromptSubmit", "PostToolUse", "Stop": return true
        // A permission request is about a tool call, so a turn is under way.
        case "Notification": return update.status == .waiting
        default: return false
        }
    }

    private mutating func finish(_ id: String) {
        finished.removeAll { $0 == id }
        finished.append(id)
        if finished.count > Self.finishedLimit { finished.removeFirst(finished.count - Self.finishedLimit) }
    }
}

/// One line per change of the conversation a session resumes, in `conversations.jsonl`, so a
/// session that comes back in the wrong conversation can be traced to the hook that moved it.
public enum ConversationLog {
    public static func line(session: UUID, label: String, update: HookUpdate, from: String?, to: String?,
                            time: Date = Date()) -> Data {
        var record: [String: JSONValue] = [
            "time": .string(ISO8601DateFormatter().string(from: time)),
            "session": .string(session.uuidString),
            "label": .string(label),
            "event": .string(update.event),
            "from": from.map(JSONValue.string) ?? .null,
            "to": to.map(JSONValue.string) ?? .null,
        ]
        if let source = update.source { record["source"] = .string(source) }
        return JSONValue.object(record).encodedLine()
    }

    /// Best effort: the log only explains, the saved session is what matters.
    public static func append(session: UUID, label: String, update: HookUpdate, from: String?, to: String?,
                              url: URL = AppPaths.conversationLogFile) {
        let data = line(session: session, label: label, update: update, from: from, to: to)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
