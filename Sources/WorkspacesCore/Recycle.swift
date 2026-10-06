import Foundation

// "Um item, uma sessão": when an item's PR is open, the session writes a "Passagem" section in the
// FRENTE.md at the root of its worktree and its conversation starts over with /clear, picking up
// from that section. Everything here guards one rule: nothing important is lost on the way. The
// gate refuses with a clear reason, the log is written before anything is cleared, and the message
// the new conversation gets is fixed text, never free text.

// MARK: Fixed texts

public enum Handoff {
    public static let fileName = "FRENTE.md"
    /// The Passagem must have been written this recently.
    public static let maxAge: TimeInterval = 30 * 60

    /// What the new conversation receives after /clear. Fixed text: only the path changes.
    public static func resumePrompt(oldTranscript: String) -> String {
        "Leia a seção Passagem do FRENTE.md e retome. A conversa anterior está em \(oldTranscript): se faltar algo, procure nela com grep, sem ler inteira."
    }

    /// Context for the conversation that starts after a recycle's /clear (SessionStart, source "clear").
    public static func sessionStartContext(_ record: RecycleRecord) -> String {
        var text = "Esta conversa começou com o /clear de uma reciclagem do Workspaces."
        if let path = record.oldTranscript {
            text += " A conversa anterior continua em \(path); o que faltar se procura nela com grep, sem ler inteira."
        }
        if let frente = record.frente { text += " A passagem está em \(frente)." }
        if let handoff = record.handoff {
            text += " Cópia da seção Passagem feita antes do /clear:\n\n" + handoff
        }
        return text
    }

    /// Every section whose heading starts with "Passagem", from its heading to the next heading of
    /// the same or a higher level. Headings inside fenced code blocks do not count.
    public static func sections(in markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var sections: [String] = []
        var current: (level: Int, lines: [String])?
        var fence: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                current?.lines.append(line)
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                current?.lines.append(line)
                continue
            }
            if let heading = heading(line) {
                if let open = current, heading.level <= open.level {
                    sections.append(open.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                    current = nil
                }
                if current == nil, heading.title.lowercased().hasPrefix("passagem") {
                    current = (heading.level, [line])
                    continue
                }
            }
            current?.lines.append(line)
        }
        if let open = current { sections.append(open.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
        return sections
    }

    /// All Passagem sections, in file order.
    public static func section(in markdown: String) -> String? {
        let all = sections(in: markdown)
        return all.isEmpty ? nil : all.joined(separator: "\n\n")
    }

    /// True when some Passagem section has text under its heading.
    static func hasBody(_ sections: [String]) -> Bool {
        sections.contains { section in
            section.components(separatedBy: "\n").dropFirst().contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    /// An ATX heading ("## Passagem 06/10"): its level and title.
    static func heading(_ line: String) -> (level: Int, title: String)? {
        guard line.first == "#" else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // A closing sequence ("## Passagem ##") is not part of the title.
        while title.hasSuffix("#") { title.removeLast() }
        return (hashes, title.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: The worktree

public enum GitState: Equatable, Sendable {
    case clean
    /// `git status --porcelain` lines: tracked and modified, or untracked and not ignored.
    case dirty([String])
    case notRepository
    case failed(String)
}

/// What the gate reads from the session's worktree: the FRENTE.md at its root and git status.
public struct WorktreeFacts: Equatable, Sendable {
    public var root: String?
    public var frentePath: String?
    public var frenteText: String?
    public var frenteModified: Date?
    public var git: GitState

    public init(root: String? = nil, frentePath: String? = nil, frenteText: String? = nil, frenteModified: Date? = nil,
                git: GitState) {
        self.root = root
        self.frentePath = frentePath
        self.frenteText = frenteText
        self.frenteModified = frenteModified
        self.git = git
    }

    /// Runs git in `cwd` (read only: no optional locks) and reads `<root>/FRENTE.md`.
    public static func read(cwd: String, git: String = "/usr/bin/git") -> WorktreeFacts {
        let top = GitProbe.run(git, ["-C", cwd, "rev-parse", "--show-toplevel"])
        guard top.status == 0 else {
            let notRepo = top.error.lowercased().contains("not a git repository")
            return WorktreeFacts(git: notRepo ? .notRepository : .failed(top.error.isEmpty ? "git rev-parse saiu com \(top.status)" : top.error))
        }
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let frente = URL(fileURLWithPath: root).appendingPathComponent(Handoff.fileName).path
        let text = FileManager.default.contents(atPath: frente).map { String(decoding: $0, as: UTF8.self) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: frente))?[.modificationDate] as? Date
        let status = GitProbe.run(git, ["-C", root, "status", "--porcelain"])
        let state: GitState
        if status.status != 0 {
            state = .failed(status.error.isEmpty ? "git status saiu com \(status.status)" : status.error)
        } else {
            let blocking = GitProbe.blocking(status.output)
            state = blocking.isEmpty ? .clean : .dirty(blocking)
        }
        return WorktreeFacts(root: root, frentePath: frente, frenteText: text, frenteModified: modified, git: state)
    }
}

public enum GitProbe {
    /// Porcelain lines that keep a session from being recycled or closed: everything but ignored files.
    public static func blocking(_ porcelain: String) -> [String] {
        porcelain.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("!!") }
    }

    static func run(_ git: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "\(error)") }
        // Read before waiting, so a large output never blocks on a full pipe.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self),
                String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: The prompt on screen

public enum PromptScreen {
    private static let markers: [Character] = ["❯", ">"]
    private static let frame: Set<Character> = ["│", "|", "┃", " "]
    private static let rules: Set<Character> = ["─", "━", "╭", "┌"]

    /// Reads Claude Code's input line from the screen, bottom up: true when it is on screen and
    /// empty, false when it holds text, nil when it is not found. The input line is the one that
    /// starts with the prompt mark right below a rule ("───" or the top of a box); sent prompts
    /// are echoed above with the same mark. Anything typed and not sent would go out together
    /// with "/clear", so only a positive "empty" lets a recycle through.
    public static func inputIsEmpty(_ lines: [String]) -> Bool? {
        for index in lines.indices.reversed() where index > 0 {
            let above = lines[index - 1].drop { $0 == " " }
            guard let rule = above.first, rules.contains(rule) else { continue }
            let start = lines[index].drop { frame.contains($0) }
            guard let first = start.first, markers.contains(first) else { continue }
            let rest = start.dropFirst()
            guard rest.isEmpty || rest.first?.isWhitespace == true else { continue }
            var content = rest.trimmingCharacters(in: .whitespaces)
            while let last = content.last, frame.contains(last) { content.removeLast() }
            return content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return nil
    }
}

// MARK: The gate

/// Everything the gate looks at, gathered by the app.
public struct RecycleFacts: Sendable {
    public var worktree: WorktreeFacts
    public var status: SessionStatus
    /// Claude's id of the current conversation; nil before the first prompt.
    public var conversation: String?
    /// The current conversation's .jsonl, only when it exists on disk.
    public var transcript: String?
    /// See `PromptScreen.inputIsEmpty`.
    public var promptEmpty: Bool?
    public var now: Date

    public init(worktree: WorktreeFacts, status: SessionStatus, conversation: String?, transcript: String?,
                promptEmpty: Bool?, now: Date = Date()) {
        self.worktree = worktree
        self.status = status
        self.conversation = conversation
        self.transcript = transcript
        self.promptEmpty = promptEmpty
        self.now = now
    }
}

public enum RecycleRefusal: Error, Equatable, Sendable {
    case noConversation
    case noTranscript
    case notRepository
    case gitFailed(String)
    case noFrente(String)
    case noHandoffSection(String)
    case emptyHandoffSection(String)
    case staleHandoff(String, minutes: Int)
    case dirtyTree([String])
    case midTurn(SessionStatus)
    case promptNotEmpty
    case promptUnknown

    public var message: String {
        switch self {
        case .noConversation:
            return "Recusado: a sessão ainda não tem conversa para reciclar."
        case .noTranscript:
            return "Recusado: não achei o .jsonl da conversa atual no disco, e a retomada precisa dele para procurar o que faltar."
        case .notRepository:
            return "Recusado: a pasta da sessão não está num repositório git, então não dá para conferir que nada ficou sem commit."
        case .gitFailed(let error):
            return "Recusado: o git status falhou (\(error)), então não dá para conferir que nada ficou sem commit."
        case .noFrente(let path):
            return "Recusado: falta o \(path). Escreva nele a seção Passagem (item em curso com ramo, commit e PR, o que falta, jobs na fila, próximos itens, decisões, armadilhas, vigias ligados) e chame de novo."
        case .noHandoffSection(let path):
            return "Recusado: o \(path) não tem seção com título começando por \"Passagem\". Escreva a passagem e chame de novo."
        case .emptyHandoffSection(let path):
            return "Recusado: a seção Passagem do \(path) está vazia."
        case .staleHandoff(let path, let minutes):
            return "Recusado: o \(path) foi salvo há \(minutes) min, e a passagem precisa ter sido escrita nos últimos 30 min. Atualize a seção Passagem e chame de novo."
        case .dirtyTree(let lines):
            let shown = lines.prefix(8).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            let more = lines.count > 8 ? " e mais \(lines.count - 8)" : ""
            return "Recusado: a árvore tem mudanças sem commit (\(shown)\(more)). Faça commit, ou ponha no ignore o que for descartável, e chame de novo."
        case .midTurn(let status):
            return "Recusado: a sessão está no meio de um turno (\(status.label.lowercased())). Chame de novo quando ela estiver parada."
        case .promptNotEmpty:
            return "Recusado: há texto não enviado na caixa de entrada da sessão, e ele iria junto com o /clear. Envie ou apague o texto e chame de novo."
        case .promptUnknown:
            return "Recusado: não consegui ver a caixa de entrada vazia na tela da sessão, então o /clear poderia levar junto um rascunho."
        }
    }
}

public enum RecycleGate {
    /// The Passagem text when everything holds, or the first reason to refuse.
    /// `turnEnded` is false only when recycle_self schedules itself: the caller is in the middle of
    /// its own turn, so the turn and the prompt are checked again when it ends.
    public static func check(_ facts: RecycleFacts, turnEnded: Bool = true,
                             maxAge: TimeInterval = Handoff.maxAge) -> Result<String, RecycleRefusal> {
        guard facts.conversation != nil else { return .failure(.noConversation) }
        guard facts.transcript != nil else { return .failure(.noTranscript) }
        if turnEnded, facts.status == .working || facts.status == .waiting { return .failure(.midTurn(facts.status)) }
        let worktree = facts.worktree
        switch worktree.git {
        case .notRepository: return .failure(.notRepository)
        case .failed(let error): return .failure(.gitFailed(error))
        case .clean, .dirty: break
        }
        guard let path = worktree.frentePath, let text = worktree.frenteText else {
            return .failure(.noFrente(worktree.frentePath ?? Handoff.fileName))
        }
        let sections = Handoff.sections(in: text)
        guard !sections.isEmpty else { return .failure(.noHandoffSection(path)) }
        guard Handoff.hasBody(sections) else { return .failure(.emptyHandoffSection(path)) }
        let age = facts.now.timeIntervalSince(worktree.frenteModified ?? .distantPast)
        guard age <= maxAge else { return .failure(.staleHandoff(path, minutes: Int(min(age, 1e7) / 60))) }
        if case .dirty(let lines) = worktree.git { return .failure(.dirtyTree(lines)) }
        if turnEnded {
            switch facts.promptEmpty {
            case true?: break
            case false?: return .failure(.promptNotEmpty)
            case nil: return .failure(.promptUnknown)
            }
        }
        return .success(sections.joined(separator: "\n\n"))
    }

    /// close_session: never while the session works or waits, never with uncommitted changes.
    /// A folder outside git has nothing to commit, so it may close.
    public static func checkClose(status: SessionStatus, git: GitState) -> RecycleRefusal? {
        if status == .working || status == .waiting { return .midTurn(status) }
        switch git {
        case .clean, .notRepository: return nil
        case .dirty(let lines): return .dirtyTree(lines)
        case .failed(let error): return .gitFailed(error)
        }
    }

    /// These tools take no free text: any argument besides the allowed ones is refused.
    public static func unexpectedArguments(_ arguments: JSONValue, allowed: Set<String>) -> [String] {
        guard case .object(let object) = arguments else { return arguments == .null ? [] : ["(argumentos)"] }
        return object.keys.filter { !allowed.contains($0) }.sorted()
    }
}

// MARK: The log

/// One line of recycles.jsonl. Append only: nothing in it, or in the transcripts it points to, is ever deleted.
public struct RecycleRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Logged before /clear is sent.
        case recycle
        /// The new conversation received the fixed message.
        case resumed
        /// Something after the log went wrong; the old conversation is still on disk.
        case failed
        /// A recycle_self waited for its turn to end and the gate refused it then.
        case refused
        /// close_session.
        case close
    }

    public var time: Date
    public var kind: Kind
    /// The app's id for the session.
    public var session: String
    public var label: String?
    public var cwd: String?
    public var frente: String?
    public var oldConversation: String?
    public var oldTranscript: String?
    public var newConversation: String?
    /// Copy of the Passagem section(s) at that moment.
    public var handoff: String?
    public var contextTokens: Int?
    public var reason: String?

    public init(time: Date = Date(), kind: Kind, session: String, label: String? = nil, cwd: String? = nil,
                frente: String? = nil, oldConversation: String? = nil, oldTranscript: String? = nil,
                newConversation: String? = nil, handoff: String? = nil, contextTokens: Int? = nil, reason: String? = nil) {
        self.time = time
        self.kind = kind
        self.session = session
        self.label = label
        self.cwd = cwd
        self.frente = frente
        self.oldConversation = oldConversation
        self.oldTranscript = oldTranscript
        self.newConversation = newConversation
        self.handoff = handoff
        self.contextTokens = contextTokens
        self.reason = reason
    }
}

public struct RecycleLog: Sendable {
    public let url: URL

    public init(url: URL = AppPaths.recycleLogFile) {
        self.url = url
    }

    /// Appends one line and flushes it to disk before returning. Throws rather than lose it.
    public func append(_ record: RecycleRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Every record that parses; a broken line is skipped, never fatal.
    public func records() -> [RecycleRecord] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(RecycleRecord.self, from: Data($0)) }
    }

    /// What a conversation that just started after /clear should receive: the newest recycle of
    /// this session that no later record closed (resumed, failed, refused, close), if recent.
    public static func pendingHandoff(in records: [RecycleRecord], session: String, now: Date,
                                      within: TimeInterval = 15 * 60) -> RecycleRecord? {
        var pending: RecycleRecord?
        for record in records where record.session == session {
            pending = record.kind == .recycle ? record : nil
        }
        guard let pending, now.timeIntervalSince(pending.time) <= within else { return nil }
        return pending
    }
}

// MARK: Transcripts

public enum TranscriptLocator {
    /// The .jsonl of a conversation: the path a hook reported when it exists, otherwise the file
    /// named after the id in any project folder under `root` (~/.claude/projects).
    /// The path is typed into the new conversation, so one with control characters (an escape
    /// sequence could end the bracketed paste) is never returned.
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
