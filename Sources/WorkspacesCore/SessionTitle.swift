import Foundation

/// What a session is about: a short name for its row in the sidebar and a sentence for the top of the window.
public struct SessionTitle: Codable, Hashable, Sendable {
    /// Two to four words ("QA Primova na 442").
    public var tab: String
    /// One sentence ("QA do Primova Pay no build 442 com o validador da bancada").
    public var full: String
    /// Given by the person (`/titulo <texto>` or Renomear): never generated over.
    public var pinned: Bool

    /// The sidebar row has room for about 18 characters next to the time and the context mark.
    public static let tabLimit = 22
    public static let fullLimit = 90

    public init(tab: String, full: String, pinned: Bool = false) {
        self.tab = tab
        self.full = full
        self.pinned = pinned
    }

    /// The person's own text: kept whole as the title, cut at a word for the tab.
    public static func given(_ text: String) -> SessionTitle {
        let full = clean(text, limit: fullLimit)
        return SessionTitle(tab: clean(full, limit: tabLimit), full: full, pinned: true)
    }

    /// One line, no dashes the person never writes, no final period, at most `limit` characters cut at a word.
    public static func clean(_ text: String, limit: Int) -> String {
        var s = text.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: " – ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: "-")
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*").union(.whitespaces))
        while s.hasSuffix(".") { s.removeLast() }
        guard s.count > limit else { return s }
        let head = s.prefix(limit)
        // When the limit falls right after a word, that word stays.
        let atWordEnd = s.dropFirst(limit).first == " "
        let cut = atWordEnd ? String(head) : head.lastIndex(of: " ").map { String(head[..<$0]) } ?? String(head)
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-").union(.whitespaces))
    }
}

/// `/titulo` typed in Claude Code. The hook answers it and blocks the prompt, so the model never sees it.
public enum TitleCommand: Equatable, Sendable {
    /// `/titulo` alone: generate the title again from the conversation.
    case regenerate
    /// `/titulo <texto>`: this is the title, kept.
    case set(String)

    /// The plugin's command is `/workspaces:titulo`; `/titulo` is accepted too.
    static let names = ["/workspaces:titulo", "/titulo"]

    public static func parse(_ prompt: String) -> TitleCommand? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in names where text.lowercased().hasPrefix(name) {
            let rest = text.dropFirst(name.count)
            guard rest.first.map({ $0.isWhitespace }) ?? true else { continue }
            let argument = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            return argument.isEmpty ? .regenerate : .set(argument)
        }
        return nil
    }

    /// What the hook prints: Claude Code drops the prompt and shows the reason to the person.
    public static func reply(_ reason: String) -> String {
        var line = JSONValue.object(["decision": .string("block"), "reason": .string(reason)]).encodedLine()
        line.removeLast()
        return String(decoding: line, as: UTF8.self)
    }
}

/// The one call to a small model that names a session: `claude -p` with no tools, no MCP and
/// nothing of the person's setup, so it costs about a thousand tokens and saves no conversation.
public enum TitlePrompt {
    public static let system = """
    Você dá nome a sessões do Claude Code. Responda só com um objeto JSON, sem texto em volta: \
    {"aba": "...", "titulo": "..."}. aba: 2 ou 3 palavras, no máximo 18 caracteres, o assunto da sessão. \
    titulo: uma frase objetiva de no máximo 70 caracteres sobre o que a sessão vai fazer. \
    Português do Brasil com a acentuação correta, mesmo que o pedido venha sem acento. \
    Sem travessão, sem emoji, sem ponto final. Use só o que o pedido diz.
    """

    /// Arguments after the `claude` command.
    public static func arguments(model: String) -> [String] {
        ["-p", "--safe-mode", "--model", model, "--tools", "", "--strict-mcp-config", "--no-session-persistence",
         "--output-format", "json", "--system-prompt", system]
    }

    /// The prompts go in whole up to a budget: the first one says what the task is, the latest ones where it went.
    public static func request(project: String, branch: String?, prompts: [String], given: String? = nil) -> String {
        var lines = ["Projeto: \(project)"]
        if let branch { lines.append("Branch: \(branch)") }
        if let given {
            lines.append("A pessoa escolheu este título, use-o como titulo e escreva a aba a partir dele:")
            lines.append(given)
        } else {
            lines.append(prompts.count > 1 ? "Pedidos, do primeiro ao mais recente:" : "Pedido:")
            let budget = max(300, 2400 / max(1, prompts.count))
            for prompt in prompts {
                let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(text.count > budget ? String(text.prefix(budget)) + "…" : text)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Reads `claude -p --output-format json`: its `result` holds the JSON the model wrote.
    public static func parse(_ output: Data) -> SessionTitle? {
        guard let reply = JSONValue.parse(output), reply["is_error"] != .bool(true),
              let text = reply["result"]?.stringValue,
              let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let answer = JSONValue.parse(Data(text[open...close].utf8)),
              let tab = answer["aba"]?.stringValue, let full = answer["titulo"]?.stringValue else { return nil }
        let title = SessionTitle(tab: SessionTitle.clean(tab, limit: SessionTitle.tabLimit),
                                 full: SessionTitle.clean(full, limit: SessionTitle.fullLimit))
        return title.tab.isEmpty || title.full.isEmpty ? nil : title
    }
}

/// The plugin passed to every session with `--plugin-dir`, so `/titulo` completes in Claude Code
/// (as `/workspaces:titulo`) without touching the person's `~/.claude`.
public enum TitlePlugin {
    /// Runs only if the app did not answer the hook: the prompt then reaches the model.
    public static let command = """
    ---
    description: Atualiza o título desta sessão no Workspaces (sem texto, gera de novo)
    argument-hint: [título]
    ---
    O app Workspaces não respondeu a este comando, então o título não mudou. Diga isso em uma frase e não faça mais nada.

    """

    public static func write(to directory: URL) throws {
        let fm = FileManager.default
        let manifest = directory.appendingPathComponent(".claude-plugin", isDirectory: true)
        let commands = directory.appendingPathComponent("commands", isDirectory: true)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: true)
        try fm.createDirectory(at: commands, withIntermediateDirectories: true)
        let plugin = JSONValue.object(["name": .string("workspaces"), "version": .string("1.0.0"),
                                       "description": .string("Comandos do app Workspaces")])
        try plugin.encodedLine().write(to: manifest.appendingPathComponent("plugin.json"), options: .atomic)
        try Data(command.utf8).write(to: commands.appendingPathComponent("titulo.md"), options: .atomic)
    }
}

/// What a tool just did, in a few words, from the PostToolUse hook: free, unlike asking a model.
public enum ToolActivity {
    public static func phrase(tool: String?, input: JSONValue?) -> String? {
        guard let tool, !tool.hasPrefix("mcp__workspaces__") else { return nil }
        if let description = input?["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return String(description.prefix(80))
        }
        let file = (input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit": return file.map { "Editando \($0)" }
        case "Write": return file.map { "Escrevendo \($0)" }
        case "Read": return file.map { "Lendo \($0)" }
        case "Grep", "Glob": return "Buscando no código"
        case "WebSearch", "WebFetch": return "Pesquisando na web"
        default: return nil
        }
    }
}

/// The person's prompts in a conversation's .jsonl, for naming it again after the app restarted.
public enum TranscriptPrompts {
    /// The first prompt and the latest ones; slash commands, their output and pasted context are skipped.
    public static func read(_ data: Data, latest: Int = 3) -> [String] {
        var prompts: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = JSONValue.parse(Data(line)), entry["type"] == .string("user"),
                  entry["isMeta"] != .bool(true), let text = text(of: entry["message"]?["content"]) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), TitleCommand.parse(trimmed) == nil else { continue }
            prompts.append(trimmed)
        }
        guard prompts.count > latest + 1 else { return prompts }
        return [prompts[0]] + prompts.suffix(latest)
    }

    private static func text(of content: JSONValue?) -> String? {
        switch content {
        case .string(let text)?: return text
        case .array(let parts)?:
            if parts.contains(where: { $0["type"] == .string("tool_result") }) { return nil }
            let texts = parts.compactMap { $0["type"] == .string("text") ? $0["text"]?.stringValue : nil }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default: return nil
        }
    }
}
