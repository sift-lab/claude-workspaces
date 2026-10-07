import Foundation

// "Um item, uma sessão": when an item's PR is open, the session writes a "Passagem" section in the
// FRENTE.md at the root of its worktree and its conversation starts over with /clear, picking up
// from that section. Everything here guards one rule: nothing important is lost on the way. The
// gate refuses with a clear reason, the log is written before anything is cleared, and the message
// the new conversation gets is fixed text, never free text.

// MARK: Fixed texts

public enum Handoff {
    public static let fileName = "FRENTE.md"
    /// The Passagem must have been written this recently, by the date and time in its title.
    public static let maxAge: TimeInterval = 30 * 60
    /// A title a little ahead of the clock is a clock out of step, not a mistake.
    static let maxAhead: TimeInterval = 5 * 60
    /// Claude Code keeps hook context up to about 10 KB; above that it shows a short preview only.
    public static let contextLimit = 9_000

    /// What the new conversation receives after /clear. Fixed text: only the paths change.
    public static func resumePrompt(handoffFile: String, oldTranscript: String) -> String {
        "Leia a Passagem copiada no /clear em \(handoffFile) e retome. A conversa anterior está em \(oldTranscript): se faltar algo, procure nela com grep, sem ler inteira."
    }

    /// The first words of every resume prompt: how a prompt is told apart from any other message.
    public static let resumePromptStart = "Leia a Passagem copiada no /clear em "

    /// Everything the new conversation needs, as written to the handoff file: where it came from,
    /// where it stands in git, what still runs in the background, and the whole Passagem.
    public static func handoffText(_ record: RecycleRecord) -> String {
        var text = "Esta conversa começou com o /clear de uma reciclagem do Workspaces."
        if let path = record.oldTranscript {
            text += " A conversa anterior continua em \(path); o que faltar se procura nela com grep, sem ler inteira."
        }
        if let context = record.context {
            text += "\n\n" + context.description
        }
        if let handoff = record.handoff {
            var origin = "Passagem"
            if let frente = record.frente { origin += " de \(frente)" }
            if let date = record.handoffDate { origin += ", escrita em \(stamp(date))" }
            text += "\n\n\(origin), copiada na hora do /clear:\n\n" + handoff
        }
        return text
    }

    /// Context for the conversation that starts after a recycle's /clear (SessionStart, source
    /// "clear"): the handoff text when it fits, otherwise its file and its beginning.
    public static func sessionStartContext(_ record: RecycleRecord, limit: Int = contextLimit) -> String {
        let full = handoffText(record)
        guard full.count > limit, let file = record.handoffFile else { return full }
        let head = "O texto da reciclagem tem \(full.count) caracteres, mais do que cabe aqui. Leia o arquivo \(file) inteiro antes de seguir. Começo:\n\n"
        let tail = "\n\n[continua em \(file)]"
        return head + String(full.prefix(max(0, limit - head.count - tail.count))) + tail
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        // Local time, as the title was written; Foundation on Linux defaults formatters to GMT.
        formatter.timeZone = .current
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: date)
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

    /// The Passagem that counts: the one with the latest date and time in its title (the later
    /// one in the file on a tie). Sections with no date in the title are not considered.
    public static func latest(in markdown: String, now: Date, calendar: Calendar = .current) -> HandoffSection? {
        var best: HandoffSection?
        for text in sections(in: markdown) {
            let title = text.components(separatedBy: "\n").first.flatMap(heading)?.title ?? ""
            guard let date = date(inTitle: title, now: now, calendar: calendar) else { continue }
            if best.map({ date >= $0.date }) ?? true { best = HandoffSection(text: text, title: title, date: date) }
        }
        return best
    }

    /// The section close_session logs: the latest dated one, or the last one in the file.
    public static func section(in markdown: String, now: Date = Date()) -> String? {
        latest(in: markdown, now: now)?.text ?? sections(in: markdown).last
    }

    /// The date and time in a Passagem title, local time: "07/10 14h30", "07/10/2026 14:30",
    /// "2026-10-07 14:30", "(07/10, 08h)". A day and month without a year is the latest such day
    /// not in the future. Nil without both a date and an hour.
    public static func date(inTitle title: String, now: Date, calendar: Calendar = .current) -> Date? {
        func groups(_ pattern: String) -> [String?]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: title).map { String(title[$0]) }
            }
        }
        var parts = DateComponents()
        if let iso = groups("(?<![0-9])([0-9]{4})-([0-9]{2})-([0-9]{2})(?![0-9])") {
            parts.year = Int(iso[0]!); parts.month = Int(iso[1]!); parts.day = Int(iso[2]!)
        } else if let br = groups("(?<![0-9/])([0-9]{1,2})/([0-9]{1,2})(?:/([0-9]{2,4}))?(?![0-9/])") {
            parts.day = Int(br[0]!); parts.month = Int(br[1]!)
            if let year = br[2].flatMap({ Int($0) }) { parts.year = year < 100 ? 2000 + year : year }
        } else {
            return nil
        }
        guard let time = groups("(?<![0-9:])([0-9]{1,2})(?:h([0-9]{2})?|:([0-9]{2}))(?![0-9])") else { return nil }
        parts.hour = Int(time[0]!)
        parts.minute = Int(time[1] ?? time[2] ?? "0")
        guard let month = parts.month, (1...12).contains(month), let day = parts.day, (1...31).contains(day),
              let hour = parts.hour, (0...23).contains(hour), let minute = parts.minute, (0...59).contains(minute) else { return nil }
        if parts.year == nil {
            let year = calendar.component(.year, from: now)
            parts.year = year
            if let date = calendar.date(from: parts), date > now.addingTimeInterval(24 * 3600) { parts.year = year - 1 }
        }
        guard let date = calendar.date(from: parts),
              calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month else { return nil }
        return date
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

/// One Passagem section and the date in its title.
public struct HandoffSection: Equatable, Sendable {
    public var text: String
    public var title: String
    public var date: Date

    public init(text: String, title: String, date: Date) {
        self.text = text
        self.title = title
        self.date = date
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

    static func run(_ git: String, _ arguments: [String], cwd: String? = nil,
                    timeout: TimeInterval? = nil) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "\(error)") }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
        // Read before waiting, so a large output never blocks on a full pipe.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self),
                String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: The prompt on screen

/// One terminal cell, with the two attributes the input check reads.
public struct ScreenCell: Equatable, Sendable {
    public var character: Character
    /// Drawn faint (SGR 2). Claude Code draws its placeholder this way, and the next prompt it
    /// suggests after a turn takes the placeholder's place: shown in the input line, never typed.
    public var faint: Bool
    /// Drawn in inverse video (SGR 7), as Claude Code paints its own cursor.
    public var inverse: Bool

    public init(_ character: Character, faint: Bool = false, inverse: Bool = false) {
        self.character = character
        self.faint = faint
        self.inverse = inverse
    }
}

/// One terminal row, cell by cell.
public struct ScreenLine: Equatable, Sendable {
    public var cells: [ScreenCell]

    public init(cells: [ScreenCell]) {
        self.cells = cells
    }

    /// Plain text: no cell faint or inverse.
    public init(_ text: String) {
        cells = text.map { ScreenCell($0) }
    }

    public var text: String { String(cells.map(\.character)) }
}

public enum PromptScreen {
    private static let markers: [Character] = ["❯", ">"]
    private static let frame: Set<Character> = ["│", "|", "┃", " "]
    private static let rules: Set<Character> = ["─", "━", "╭", "┌"]

    /// Reads Claude Code's input line from the screen, bottom up: true when it is on screen with
    /// nothing typed in it, false when it holds text, nil when it is not found. The input line is
    /// the one that starts with the prompt mark right below a rule ("───" or the top of a box);
    /// sent prompts are echoed above with the same mark. Anything typed and not sent would go out
    /// together with "/clear", so only a positive "empty" lets a recycle through.
    public static func inputIsEmpty(_ lines: [ScreenLine]) -> Bool? {
        inputCells(lines).map(holdsNothingTyped)
    }

    /// What is typed in the input line: "" when nothing is, nil when the line is not found.
    public static func typedInput(_ lines: [ScreenLine]) -> String? {
        guard let cells = inputCells(lines) else { return nil }
        if holdsNothingTyped(cells) { return "" }
        return String(cells.filter { !$0.faint }.map(\.character)).trimmingCharacters(in: .whitespaces)
    }

    private static func inputCells(_ lines: [ScreenLine]) -> ArraySlice<ScreenCell>? {
        for index in lines.indices.reversed() where index > 0 {
            let above = lines[index - 1].cells.drop { $0.character == " " }
            guard let rule = above.first?.character, rules.contains(rule) else { continue }
            let start = lines[index].cells.drop { frame.contains($0.character) }
            guard let mark = start.first?.character, markers.contains(mark) else { continue }
            let rest = start.dropFirst()
            guard rest.isEmpty || rest.first?.character.isWhitespace == true else { continue }
            var content = rest.drop { $0.character.isWhitespace }
            while let last = content.last?.character, last.isWhitespace || frame.contains(last) { content.removeLast() }
            return content
        }
        return nil
    }

    /// The same, for text read without attributes.
    public static func inputIsEmpty(_ lines: [String]) -> Bool? {
        inputIsEmpty(lines.map(ScreenLine.init))
    }

    /// True when what follows the mark is only blanks or faint text: the placeholder, or the
    /// suggested next prompt. With Claude Code's drawn cursor on, that text's first character is
    /// painted inverse instead of faint; it is skipped only when faint text follows it, so a
    /// one-letter draft under the cursor still counts as typed.
    private static func holdsNothingTyped(_ cells: ArraySlice<ScreenCell>) -> Bool {
        var shown = cells
        if shown.first?.inverse == true,
           shown.dropFirst().contains(where: { $0.faint && !$0.character.isWhitespace }) {
            shown = shown.dropFirst()
        }
        return shown.allSatisfy { $0.faint || $0.character.isWhitespace }
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
    /// A recado of the app's own waits to be typed in the session.
    public var pendingMessage: Bool
    /// What the end of the transcript says: a message that came by another way (Claude Code's own
    /// SendMessage, a queued prompt) shows there before any hook does.
    public var turn: TranscriptTurn
    public var now: Date

    public init(worktree: WorktreeFacts, status: SessionStatus, conversation: String?, transcript: String?,
                promptEmpty: Bool?, pendingMessage: Bool = false, turn: TranscriptTurn = .unknown, now: Date = Date()) {
        self.worktree = worktree
        self.status = status
        self.conversation = conversation
        self.transcript = transcript
        self.promptEmpty = promptEmpty
        self.pendingMessage = pendingMessage
        self.turn = turn
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
    case undatedHandoff(String)
    case emptyHandoffSection(String)
    case staleHandoff(String, minutes: Int)
    case futureHandoff(String, title: String)
    case dirtyTree([String])
    case midTurn(SessionStatus)
    case pendingMessage
    case turnInTranscript(String)
    case promptNotEmpty
    case promptUnknown

    /// The session is not stopped: a recycle that was due waits for the next end of turn instead.
    public var isBusy: Bool {
        switch self {
        case .midTurn, .pendingMessage, .turnInTranscript: return true
        default: return false
        }
    }

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
            return "Recusado: falta o \(path). Escreva nele a seção Passagem, com data e hora no título (## Passagem 07/10 14h30), e chame de novo."
        case .noHandoffSection(let path):
            return "Recusado: o \(path) não tem seção com título começando por \"Passagem\". Escreva a passagem, com data e hora no título (## Passagem 07/10 14h30), e chame de novo."
        case .undatedHandoff(let path):
            return "Recusado: nenhuma seção Passagem do \(path) tem data e hora no título, e é por ela que a idade da passagem é medida. Escreva o título como \"## Passagem 07/10 14h30\" e chame de novo."
        case .emptyHandoffSection(let path):
            return "Recusado: a seção Passagem mais recente do \(path) está vazia."
        case .staleHandoff(let path, let minutes):
            return "Recusado: a Passagem mais recente do \(path) é de \(minutes) min atrás, pela data e hora do título, e precisa ter sido escrita nos últimos 30 min. Escreva uma seção nova, com a hora de agora no título, e chame de novo."
        case .futureHandoff(let path, let title):
            return "Recusado: a Passagem \"\(title)\" do \(path) tem data e hora no futuro. Corrija o título com a hora de agora e chame de novo."
        case .dirtyTree(let lines):
            let shown = lines.prefix(8).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            let more = lines.count > 8 ? " e mais \(lines.count - 8)" : ""
            return "Recusado: a árvore tem mudanças sem commit (\(shown)\(more)). Faça commit, ou ponha no ignore o que for descartável, e chame de novo."
        case .midTurn(let status):
            return "Recusado: a sessão está no meio de um turno (\(status.label.lowercased())). Chame de novo quando ela estiver parada."
        case .pendingMessage:
            return "Recusado: um recado espera para ser digitado nesta sessão, e iria junto com o /clear."
        case .turnInTranscript(let reason):
            return "Recusado: \(reason). Chame de novo quando a sessão estiver parada."
        case .promptNotEmpty:
            return "Recusado: há texto não enviado na caixa de entrada da sessão, e ele iria junto com o /clear. Envie ou apague o texto e chame de novo."
        case .promptUnknown:
            return "Recusado: não consegui ver a caixa de entrada vazia na tela da sessão, então o /clear poderia levar junto um rascunho."
        }
    }
}

public enum RecycleGate {
    /// The Passagem when everything holds, or the first reason to refuse.
    /// `turnEnded` is false only when recycle_self schedules itself: the caller is in the middle of
    /// its own turn, so the turn and the prompt are checked again when it ends.
    public static func check(_ facts: RecycleFacts, turnEnded: Bool = true,
                             maxAge: TimeInterval = Handoff.maxAge) -> Result<HandoffSection, RecycleRefusal> {
        guard facts.conversation != nil else { return .failure(.noConversation) }
        guard facts.transcript != nil else { return .failure(.noTranscript) }
        if facts.pendingMessage { return .failure(.pendingMessage) }
        if turnEnded {
            if facts.status == .working || facts.status == .waiting { return .failure(.midTurn(facts.status)) }
            if case .busy(let reason) = facts.turn { return .failure(.turnInTranscript(reason)) }
        }
        let worktree = facts.worktree
        switch worktree.git {
        case .notRepository: return .failure(.notRepository)
        case .failed(let error): return .failure(.gitFailed(error))
        case .clean, .dirty: break
        }
        guard let path = worktree.frentePath, let text = worktree.frenteText else {
            return .failure(.noFrente(worktree.frentePath ?? Handoff.fileName))
        }
        guard !Handoff.sections(in: text).isEmpty else { return .failure(.noHandoffSection(path)) }
        guard let section = Handoff.latest(in: text, now: facts.now) else { return .failure(.undatedHandoff(path)) }
        guard Handoff.hasBody([section.text]) else { return .failure(.emptyHandoffSection(path)) }
        let age = facts.now.timeIntervalSince(section.date)
        guard age <= maxAge else { return .failure(.staleHandoff(path, minutes: Int(min(age, 1e7) / 60))) }
        guard age >= -Handoff.maxAhead else { return .failure(.futureHandoff(path, title: section.title)) }
        if case .dirty(let lines) = worktree.git { return .failure(.dirtyTree(lines)) }
        if turnEnded {
            switch facts.promptEmpty {
            case true?: break
            case false?: return .failure(.promptNotEmpty)
            case nil: return .failure(.promptUnknown)
            }
        }
        return .success(section)
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
        /// Logged right before Enter sends the /clear.
        case recycle
        /// The new conversation sent the resume prompt.
        case resumed
        /// Something after the log went wrong; the old conversation is still on disk.
        case failed
        /// A recycle_self waited for its turn to end and the gate refused it then.
        case refused
        /// The session was not stopped when the /clear was due: it waits for the next end of turn.
        case deferred
        /// The new conversation did not start in time after /clear. The recycle stays open: if the
        /// /clear runs later, the new conversation still gets the Passagem and the resume prompt.
        case delayed
        /// The check a few minutes after a resume: `verdict` and `reason`.
        case verified
        /// close_session.
        case close
    }

    public enum Verdict: String, Codable, Sendable {
        case conferida, quebrada
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
    /// Copy of the Passagem section at that moment.
    public var handoff: String?
    /// The date and time in the Passagem's title.
    public var handoffDate: Date?
    /// Where the whole text the new conversation gets was written.
    public var handoffFile: String?
    /// Branch, HEAD, pull request and background tasks at the /clear.
    public var context: RecycleContext?
    public var contextTokens: Int?
    public var verdict: Verdict?
    public var reason: String?

    public init(time: Date = Date(), kind: Kind, session: String, label: String? = nil, cwd: String? = nil,
                frente: String? = nil, oldConversation: String? = nil, oldTranscript: String? = nil,
                newConversation: String? = nil, handoff: String? = nil, handoffDate: Date? = nil, handoffFile: String? = nil,
                context: RecycleContext? = nil, contextTokens: Int? = nil, verdict: Verdict? = nil, reason: String? = nil) {
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
        self.handoffDate = handoffDate
        self.handoffFile = handoffFile
        self.context = context
        self.contextTokens = contextTokens
        self.verdict = verdict
        self.reason = reason
    }

    /// The same recycle, as a later line of another kind: no copy of the Passagem again.
    public func followUp(_ kind: Kind, time: Date, newConversation: String? = nil, verdict: Verdict? = nil,
                         reason: String? = nil) -> RecycleRecord {
        RecycleRecord(time: time, kind: kind, session: session, label: label, cwd: cwd, frente: frente,
                      oldConversation: oldConversation, oldTranscript: oldTranscript,
                      newConversation: newConversation ?? self.newConversation, handoffFile: handoffFile,
                      verdict: verdict, reason: reason)
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
