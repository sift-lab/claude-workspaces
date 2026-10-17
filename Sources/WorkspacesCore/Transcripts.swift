import Foundation

// Where a conversation's .jsonl is, and what its end says about the turn.

/// Whether the conversation is between turns, read from the end of its .jsonl. Hooks only see
/// what goes through Claude Code's prompt; a message sent by Claude Code's own SendMessage, or one
/// queued while a turn ran, shows here first.
public enum TranscriptTurn: Equatable, Sendable {
    /// The last thing in the conversation is the end of a turn, and nothing waits in the queue.
    case ended
    case busy(String)
    /// Nothing that tells either way.
    case unknown

    static let tailBytes = 256 * 1024

    public static func read(path: String?) -> TranscriptTurn {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return .unknown }
        var lines = data.split(separator: 0x0A)
        // A tail that starts mid-line drops its first, partial line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return parse(lines.compactMap { JSONValue.parse(Data($0)) })
    }

    public static func parse(_ entries: [JSONValue]) -> TranscriptTurn {
        enum Last { case ended, activity }
        var last: Last?
        var queued = false
        for entry in entries {
            switch entry["type"]?.stringValue {
            case "assistant":
                // Claude Code writes a reply block by block, often with no stop_reason; the end of
                // the turn then shows in the system lines after it. A reply with none after the end
                // of a turn changes nothing; after a message, the turn that message started goes on.
                switch entry["message"]?["stop_reason"]?.stringValue {
                case "tool_use"?: last = .activity
                case nil: if last != .ended { last = .activity }
                default: last = .ended
                }
            case "user":
                if !isLocal(entry) { last = .activity }
            case "system":
                let subtype = entry["subtype"]?.stringValue
                if subtype == "turn_duration" || subtype == "stop_hook_summary" { last = .ended }
            case "queue-operation":
                queued = entry["operation"]?.stringValue == "enqueue"
            case "attachment":
                if entry["attachment"]?["type"]?.stringValue == "queued_command" { last = .activity }
            default:
                break
            }
        }
        if queued { return .busy("há uma mensagem na fila do Claude Code da sessão") }
        switch last {
        case .ended?: return .ended
        case .activity?: return .busy("a conversa recebeu uma mensagem ou segue num turno depois do último fim de turno")
        case nil: return .unknown
        }
    }

    /// A user line no turn answers: meta lines and the output of a local slash command.
    static func isLocal(_ entry: JSONValue) -> Bool {
        if entry["isMeta"] == .bool(true) { return true }
        guard let text = entry["message"]?["content"]?.stringValue else { return false }
        return text.hasPrefix("<local-command") || text.hasPrefix("<command-name>")
    }
}

public enum TranscriptLocator {
    /// The .jsonl of a conversation: the path a hook reported when it exists, otherwise the file
    /// named after the id in any project folder under `root` (~/.claude/projects).
    /// The path goes back to a session in a tool's reply, so one with control characters (an
    /// escape sequence) is never returned.
    public static func find(conversation: String, hint: String?, root: URL) -> String? {
        let fm = FileManager.default
        let name = conversation + ".jsonl"
        if let hint, plain(hint), URL(fileURLWithPath: hint).lastPathComponent == name, fm.fileExists(atPath: hint) { return hint }
        guard !conversation.isEmpty, !conversation.contains("/"),
              let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let candidate = folder.appendingPathComponent(name).path
            if plain(candidate), fm.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func plain(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
