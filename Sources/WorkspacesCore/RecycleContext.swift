import Foundation

// What a recycle reads around the session besides the gate: where the worktree stands in git, what
// still runs in the background, and what the transcripts say about the turn and the resume.

// MARK: Git and background tasks

/// Where the session stands at the /clear. Background tasks outlive /clear and keep notifying the
/// conversation, so the new one has to know they are its own.
public struct RecycleContext: Codable, Equatable, Sendable {
    public var worktree: String?
    public var branch: String?
    public var head: String?
    /// The branch's open pull request, or why there is none to show.
    public var pullRequest: String?
    /// Command lines of the shells still running under Claude.
    public var backgroundTasks: [String]

    public init(worktree: String? = nil, branch: String? = nil, head: String? = nil, pullRequest: String? = nil,
                backgroundTasks: [String] = []) {
        self.worktree = worktree
        self.branch = branch
        self.head = head
        self.pullRequest = pullRequest
        self.backgroundTasks = backgroundTasks
    }

    /// Read only: git in the worktree at `root`. The pull request comes from the host, which knows
    /// whether gh can be asked. The background tasks are read at the /clear itself.
    public static func read(root: String, git: String, pullRequest: (_ root: String, _ branch: String) -> String?) -> RecycleContext {
        var context = RecycleContext(worktree: root)
        let branch = GitProbe.run(git, ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"])
        if branch.status == 0 {
            let name = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
            context.branch = name == "HEAD" ? "nenhum (HEAD solto)" : name
            if name != "HEAD" { context.pullRequest = pullRequest(root, name) }
        }
        let head = GitProbe.run(git, ["-C", root, "log", "-1", "--format=%h %s"])
        if head.status == 0 { context.head = head.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        return context
    }

    /// As the new conversation reads it.
    public var description: String {
        var lines: [String] = []
        if let worktree { lines.append("Pasta do worktree: \(worktree)") }
        if let branch { lines.append("Ramo: \(branch)") }
        if let head { lines.append("HEAD: \(head)") }
        if let pullRequest { lines.append("PR do ramo: \(pullRequest)") }
        if backgroundTasks.isEmpty {
            lines.append("Tarefas em segundo plano vivas no /clear: nenhuma.")
        } else {
            lines.append("Tarefas em segundo plano vivas no /clear (seguem rodando e podem notificar esta conversa; são desta sessão):")
            lines += backgroundTasks.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

public enum PullRequestLookup {
    /// The branch's open pull request from gh, in `root`, within `timeout` seconds: "#12 <url>",
    /// "nenhum PR aberto", or nil when gh did not answer.
    /// Short: the sequence waits for it on the queue that runs everything else.
    public static func find(gh: String, root: String, branch: String, timeout: TimeInterval = 3) -> String? {
        let result = GitProbe.run(gh, ["pr", "list", "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"],
                                  cwd: root, timeout: timeout)
        guard result.status == 0, case .array(let list)? = JSONValue.parse(Data(result.output.utf8)) else { return nil }
        guard let first = list.first, let number = first["number"]?.numberValue else { return "nenhum PR aberto" }
        return "#\(Int(number)) \(first["url"]?.stringValue ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// gh in `path` (a PATH value) or the usual places.
    public static func locate(path: String?) -> String? {
        let folders = (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return folders.map { "\($0)/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum BackgroundTasks {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh"]
    static let maxLength = 300

    /// The shells under `pid` that no other shell started: Claude runs each Bash call and each
    /// background task in one, and after a turn ended only the background ones are left.
    public static func list(under pid: Int32) -> [String] {
        let ps = GitProbe.run("/bin/ps", ["-A", "-o", "pid=,ppid=,args="])
        guard ps.status == 0 else { return [] }
        return tasks(psOutput: ps.output, root: pid)
    }

    static func tasks(psOutput: String, root: Int32) -> [String] {
        var children: [Int32: [(pid: Int32, args: String)]] = [:]
        for line in psOutput.components(separatedBy: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            children[parent, default: []].append((pid, String(fields[2])))
        }
        var found: [String] = []
        var stack = (children[root] ?? []).reversed().map { $0 }
        var seen: Set<Int32> = [root]
        while let process = stack.popLast() {
            guard seen.insert(process.pid).inserted else { continue }
            if isShell(process.args) {
                found.append(readable(process.args))
            } else {
                stack += (children[process.pid] ?? []).reversed()
            }
        }
        return found
    }

    static func isShell(_ args: String) -> Bool {
        guard let first = args.split(separator: " ").first else { return false }
        let name = String(first.split(separator: "/").last ?? first)
        return shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    /// Claude Code wraps each command as `bash -c -l source <snapshot> && eval '<command>' ...`:
    /// the command is what says what the task is.
    static func readable(_ args: String) -> String {
        var text = args
        if let start = text.range(of: "eval '"), let end = text.range(of: "' ", options: .backwards, range: start.upperBound..<text.endIndex) {
            text = String(text[start.upperBound..<end.lowerBound]).replacingOccurrences(of: "'\\''", with: "'")
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }
}

// MARK: Transcripts

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

/// The check a few minutes after a resume: the new conversation exists, got the Passagem and the
/// resume prompt, and went to work.
public enum ResumeCheck {
    public static func verdict(transcript: String?, handoffFile: String?, contextDelivered: Bool)
        -> (verdict: RecycleRecord.Verdict, reason: String?) {
        guard let transcript, let data = FileManager.default.contents(atPath: transcript) else {
            return (.quebrada, "o .jsonl da conversa nova não está no disco")
        }
        let entries = data.split(separator: 0x0A).compactMap { JSONValue.parse(Data($0)) }
        guard let prompt = entries.firstIndex(where: { $0["type"]?.stringValue == "user" && text(of: $0).contains(Handoff.resumePromptStart) }) else {
            return (.quebrada, "o prompt de retomada não está na conversa nova")
        }
        let after = entries[prompt...]
        let toolInputs = after.filter { $0["type"]?.stringValue == "assistant" }.flatMap(toolUses)
        let readTheFile = handoffFile.map { file in toolInputs.contains { $0.contains(file) } } ?? false
        guard contextDelivered || readTheFile else {
            return (.quebrada, "a conversa nova não recebeu a Passagem: o contexto do /clear não foi entregue e ela não leu o arquivo da Passagem")
        }
        guard !toolInputs.isEmpty else { return (.quebrada, "a conversa nova ainda não fez nenhuma chamada de ferramenta") }
        return (.conferida, nil)
    }

    /// The text of a message, whether its content is a string or a list of blocks.
    static func text(of entry: JSONValue) -> String {
        let content = entry["message"]?["content"]
        if let text = content?.stringValue { return text }
        guard case .array(let blocks)? = content else { return "" }
        return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    /// Each tool call's input, as JSON text.
    static func toolUses(_ entry: JSONValue) -> [String] {
        guard case .array(let blocks)? = entry["message"]?["content"] else { return [] }
        return blocks.filter { $0["type"]?.stringValue == "tool_use" }.map { block in
            String(decoding: (block["input"] ?? .null).encodedLine(), as: UTF8.self)
        }
    }
}
