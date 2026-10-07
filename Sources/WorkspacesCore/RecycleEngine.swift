import Foundation

// The recycle sequence, shared by the app and the server: gate, /clear, the new conversation, the
// resume prompt and the check after it. Every phase is on disk, so a restart picks up where it
// stopped. Nothing here clears a conversation without the Passagem on its way to the next one:
// whatever goes wrong either waits for a better moment or says so, loudly, to the owner.

/// Where a recycle stands, as the sidebar and list_sessions show it.
public enum RecycleProgress: Equatable, Sendable {
    case scheduled
    case waking
    case clearing
    /// /clear did not answer in time; still waiting for it.
    case delayed
    case resuming
    /// The resume prompt waits for a turn that started before it.
    case waitingTurn
    case done(Date)
    case failed(String)
}

/// What the host knows about a session right now.
public struct RecycleSubject: Sendable {
    public var label: String
    /// Where Claude runs: the session's cwd, or its project's folder.
    public var folder: String?
    /// The terminal runs and the session is not asleep.
    public var awake: Bool
    public var hibernated: Bool
    public var status: SessionStatus
    /// Claude's current conversation, as the hooks tell it.
    public var conversation: String?
    /// True once that conversation has a message.
    public var hasConversation: Bool
    /// A recado of the app's own waits to be typed.
    public var pendingMessage: Bool
    public var contextTokens: Int?

    public init(label: String, folder: String?, awake: Bool, hibernated: Bool, status: SessionStatus,
                conversation: String?, hasConversation: Bool, pendingMessage: Bool, contextTokens: Int?) {
        self.label = label
        self.folder = folder
        self.awake = awake
        self.hibernated = hibernated
        self.status = status
        self.conversation = conversation
        self.hasConversation = hasConversation
        self.pendingMessage = pendingMessage
        self.contextTokens = contextTokens
    }
}

/// The app or the daemon, as the recycle sees it. Everything runs on one queue.
public protocol RecycleHost: AnyObject {
    var now: Date { get }
    /// Runs `work` later on the same queue; the closure returned cancels it.
    @discardableResult func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> () -> Void
    func subject(_ id: UUID) -> RecycleSubject?
    func screen(_ id: UUID) -> [ScreenLine]
    /// The process in the terminal (Claude), for its background tasks.
    func processID(_ id: UUID) -> Int32?
    /// The .jsonl of a conversation of this session.
    func transcript(_ id: UUID, conversation: String) -> String?
    /// Types text key by key, without Enter.
    func type(_ id: UUID, _ text: String)
    /// Bracketed paste, without Enter.
    func paste(_ id: UUID, _ text: String)
    func pressEnter(_ id: UUID)
    /// Moves to the start of the input line and deletes `count` characters forward: takes back a
    /// /clear typed first, whatever came after it.
    func deleteFromStart(_ id: UUID, count: Int)
    /// Starts a hibernated session again; the failure, if any.
    func wake(_ id: UUID) -> String?
    /// A frozen session (app only) is thawed before anything is typed into it.
    func thaw(_ id: UUID)
    func show(_ id: UUID, _ progress: RecycleProgress?)
    /// A notification, and the session marked for attention when `attention` is true.
    func tell(_ id: UUID, title: String, body: String, attention: Bool)
    /// The branch's open pull request for the handoff ("#12 https://…", "nenhum aberto"), or nil
    /// when it cannot be looked up.
    func pullRequest(root: String, branch: String) -> String?
    func log(_ text: String)
}

public final class RecycleEngine {
    /// When a turn ends Claude Code may still send messages that were queued; wait, then look again.
    public static let settle: TimeInterval = 2.5
    /// Between typing /clear and the final check before Enter.
    public static let typeDelay: TimeInterval = 0.4
    public static let clearTimeout: TimeInterval = 30
    /// A /clear that ran this late still gets its Passagem and resume prompt.
    public static let lateWindow: TimeInterval = 15 * 60
    /// SessionStart comes a moment before the prompt takes input.
    public static let resumeDelay: TimeInterval = 1.5
    public static let resumeTimeout: TimeInterval = 30
    public static let wakeTimeout: TimeInterval = 120
    /// A deferred recycle also looks again on its own, in case no Stop comes.
    public static let retryDelay: TimeInterval = 60
    public static let maxDeferrals = 5
    /// The check of a resume runs this long after it.
    public static let checkDelay: TimeInterval = 5 * 60

    struct Open: Codable {
        enum Phase: String, Codable {
            /// recycle_self: waits for the caller's turn to end (or a deferred recycle for the next end).
            case waitingForStop
            /// recycle_session on a hibernated session: waits for it to start again.
            case waitingForStart
            /// /clear typed, Enter not pressed yet.
            case typing
            /// Logged and /clear sent: waits for the new conversation.
            case clearing
            /// The new conversation exists; the resume prompt is on its way.
            case resuming
            /// Another message started a turn first: the resume prompt goes when it ends.
            case waitingTurn
        }

        var phase: Phase
        var since: Date
        var record: RecycleRecord?
        var new: String?
        var late = false
        var contextDelivered = false
        var deferrals = 0
        /// The owner was told a draft holds the resume prompt back.
        var draftWarned = false
    }

    struct Check: Codable {
        var record: RecycleRecord
        var at: Date
        var contextDelivered: Bool
    }

    struct State: Codable {
        var open: [String: Open] = [:]
        var checks: [String: Check] = [:]
    }

    public let log: RecycleLog
    /// The phases on disk, next to recycles.jsonl.
    public let stateURL: URL
    /// The full handoff texts, one file per recycle.
    public let handoffFolder: URL
    let git: String
    /// Who runs the sequence, as the messages say it: "o app", "o servidor".
    let actor: String
    /// What restarts, as the messages say it: "Workspaces", "workspacesd".
    let program: String
    private unowned let host: RecycleHost
    private var state = State()
    private var timers: [UUID: () -> Void] = [:]
    private var checkTimers: [UUID: () -> Void] = [:]

    public init(host: RecycleHost, log: RecycleLog, git: String, actor: String, program: String) {
        self.host = host
        self.log = log
        self.git = git
        self.actor = actor
        self.program = program
        let folder = log.url.deletingLastPathComponent()
        stateURL = folder.appendingPathComponent("recycles-open.json")
        handoffFolder = folder.appendingPathComponent("passagens", isDirectory: true)
        if let data = FileManager.default.contents(atPath: stateURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = (try? decoder.decode(State.self, from: data)) ?? State()
        }
    }

    public func isBusy(_ id: UUID) -> Bool { state.open[id.uuidString] != nil }

    /// The session was closed: nothing is waiting for it any more.
    public func forget(_ id: UUID) {
        cancelTimer(id)
        checkTimers.removeValue(forKey: id)?()
        state.open[id.uuidString] = nil
        state.checks[id.uuidString] = nil
        save()
    }

    // MARK: Tools

    /// recycle_self: checked now, run when the caller's turn ends (its own call is part of the turn).
    public func requestSelf(_ id: UUID) -> ToolResult {
        guard let subject = host.subject(id) else { return ToolResult(text: "Sessão não encontrada.", isError: true) }
        if let refusal = basicRefusal(id, subject) { return refusal }
        if case .failure(let refusal) = RecycleGate.check(facts(id, subject), turnEnded: false) {
            return ToolResult(text: refusal.message, isError: true)
        }
        set(id, Open(phase: .waitingForStop, since: host.now))
        host.show(id, .scheduled)
        return ToolResult(text: "Reciclagem agendada. Quando este turno terminar, \(actor) confere a trava de novo (Passagem mais recente do FRENTE.md com data e hora no título dos últimos 30 min, git status limpo, sessão parada e caixa de entrada vazia), digita /clear, confere tudo outra vez, registra em recycles.jsonl e só então envia; depois a conversa nova recebe a Passagem e a mensagem fixa de retomada. Encerre o turno agora, sem mudar mais nada.")
    }

    /// recycle_session: runs now, or after waking a hibernated session.
    public func requestSession(_ id: UUID) -> ToolResult {
        guard let subject = host.subject(id) else { return ToolResult(text: "Sessão não encontrada.", isError: true) }
        if let refusal = basicRefusal(id, subject) { return refusal }
        if subject.hibernated {
            if case .failure(let refusal) = RecycleGate.check(facts(id, subject), turnEnded: false) {
                return ToolResult(text: refusal.message, isError: true)
            }
            set(id, Open(phase: .waitingForStart, since: host.now))
            host.show(id, .waking)
            arm(id, after: Self.wakeTimeout) { [weak self] in
                self?.stop(id, "a sessão não voltou em 2 min depois de acordar; nada foi limpo")
            }
            if let failure = host.wake(id) {
                drop(id)
                host.show(id, nil)
                return ToolResult(text: "Recusado: não consegui acordar \(subject.label) (\(failure)).", isError: true)
            }
            return ToolResult(text: "\(subject.label) estava hibernando e está acordando. A reciclagem segue quando ela abrir, com a trava conferida de novo; acompanhe em list_sessions.")
        }
        host.thaw(id)
        if let refusal = begin(id) { return ToolResult(text: refusal.message, isError: true) }
        return ToolResult(text: "/clear digitado em \(subject.label). \(actor.prefix(1).uppercased() + actor.dropFirst()) confere a sessão de novo antes do Enter e registra em recycles.jsonl; se ela tiver voltado a trabalhar, a reciclagem fica para o fim do turno. Acompanhe em list_sessions.")
    }

    private func basicRefusal(_ id: UUID, _ subject: RecycleSubject) -> ToolResult? {
        if isBusy(id) { return ToolResult(text: "Recusado: já há uma reciclagem em andamento nesta sessão.", isError: true) }
        if !subject.awake, !subject.hibernated { return ToolResult(text: "Recusado: a sessão está encerrada.", isError: true) }
        if subject.pendingMessage { return ToolResult(text: RecycleRefusal.pendingMessage.message, isError: true) }
        return nil
    }

    // MARK: The sequence

    private struct Refusal {
        let message: String
        var busy = false
    }

    /// Gate, then "/clear" typed. The final check, the log and Enter come a moment later. Returns
    /// the refusal, if any, with nothing typed.
    private func begin(_ id: UUID) -> Refusal? {
        guard let subject = host.subject(id), subject.awake else { return Refusal(message: "Recusado: a sessão não está acordada.") }
        let gateFacts = facts(id, subject)
        if case .failure(let refusal) = RecycleGate.check(gateFacts) {
            return Refusal(message: refusal.message, busy: refusal.isBusy)
        }
        guard let root = gateFacts.worktree.root else { return Refusal(message: "Recusado: a pasta da sessão é desconhecida.") }
        // The slow part (gh) before anything is typed: between /clear and Enter the session waits.
        let context = RecycleContext.read(root: root, git: git) { [host] root, branch in
            host.pullRequest(root: root, branch: branch)
        }
        var open = state.open[id.uuidString] ?? Open(phase: .typing, since: host.now)
        open.phase = .typing
        open.since = host.now
        open.record = RecycleRecord(kind: .recycle, session: id.uuidString, context: context)
        set(id, open)
        host.show(id, .clearing)
        host.type(id, "/clear")
        arm(id, after: Self.typeDelay) { [weak self] in self?.send(id) }
        return nil
    }

    /// The last look before Enter: the session still stopped, nothing else in the input, the
    /// Passagem copied now. Then the log line, and only then Enter.
    private func send(_ id: UUID) {
        guard var open = state.open[id.uuidString], open.phase == .typing, let subject = host.subject(id), subject.awake else {
            if state.open[id.uuidString] != nil { stop(id, "a sessão fechou com o /clear digitado; nada foi limpo") }
            return
        }
        let screen = host.screen(id)
        let typed = PromptScreen.typedInput(screen)
        var gateFacts = facts(id, subject, screen: screen)
        gateFacts.promptEmpty = typed == "/clear"
        let section: HandoffSection
        switch RecycleGate.check(gateFacts) {
        case .success(let found):
            section = found
        case .failure(let refusal):
            takeBackClear(id, typed: typed)
            let reason = refusal == .promptNotEmpty
                ? "a caixa de entrada não mostrava só o /clear na hora do Enter (\(typed.map { "\"\($0)\"" } ?? "não achei a caixa"))"
                : refusal.message.dropFirstRecusado
            if refusal.isBusy || refusal == .promptNotEmpty || refusal == .promptUnknown {
                deferRecycle(id, reason: reason)
            } else {
                refuse(id, reason: reason)
            }
            return
        }
        guard let old = gateFacts.conversation, let transcript = gateFacts.transcript, var record = open.record else {
            takeBackClear(id, typed: typed)
            refuse(id, reason: RecycleRefusal.noConversation.message.dropFirstRecusado)
            return
        }
        record.time = host.now
        record.label = subject.label
        record.cwd = subject.folder
        record.frente = gateFacts.worktree.frentePath
        record.oldConversation = old
        record.oldTranscript = transcript
        record.handoff = section.text
        record.handoffDate = section.date
        record.contextTokens = subject.contextTokens
        if let pid = host.processID(id) { record.context?.backgroundTasks = BackgroundTasks.list(under: pid) }
        do {
            record.handoffFile = try writeHandoff(record)
            try log.append(record)
        } catch {
            takeBackClear(id, typed: typed)
            refuse(id, reason: "não consegui gravar a Passagem e o registro (\(error.localizedDescription)); nada foi limpo")
            return
        }
        open.record = record
        open.phase = .clearing
        open.since = host.now
        set(id, open)
        host.pressEnter(id)
        arm(id, after: Self.clearTimeout) { [weak self] in self?.clearTimedOut(id) }
    }

    /// The input was empty when /clear was typed, so it starts with it, whatever came after; only
    /// a line read and not starting with it is left alone.
    private func takeBackClear(_ id: UUID, typed: String?) {
        if typed?.hasPrefix("/clear") ?? true { host.deleteFromStart(id, count: 6) }
    }

    private func writeHandoff(_ record: RecycleRecord) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: handoffFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(record.session.lowercased().prefix(8))-\(formatter.string(from: record.time)).md"
        let url = handoffFolder.appendingPathComponent(name)
        var withPath = record
        withPath.handoffFile = url.path
        guard fm.createFile(atPath: url.path, contents: Data(Handoff.handoffText(withPath).utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url.path
    }

    /// No new conversation 30 s after Enter. A /clear still in the input is taken back; one that
    /// runs later anyway still gets the Passagem and the resume prompt, within the late window.
    private func clearTimedOut(_ id: UUID) {
        guard var open = state.open[id.uuidString], open.phase == .clearing, let record = open.record else { return }
        if PromptScreen.typedInput(host.screen(id))?.hasPrefix("/clear") == true { host.deleteFromStart(id, count: 6) }
        open.late = true
        set(id, open)
        let reason = "a conversa nova não começou em 30 s depois do /clear; se ele rodar, a retomada segue até \(Int(Self.lateWindow / 60)) min depois. A anterior continua em \(record.oldTranscript ?? "?")"
        try? log.append(record.followUp(.delayed, time: host.now, reason: reason))
        host.show(id, .delayed)
        host.tell(id, title: "Reciclagem atrasada", body: reason, attention: true)
        let left = record.time.addingTimeInterval(Self.lateWindow).timeIntervalSince(host.now)
        arm(id, after: max(1, left)) { [weak self] in
            self?.stop(id, "o /clear não rodou em \(Int(Self.lateWindow / 60)) min; a conversa anterior continua em \(record.oldTranscript ?? "?"), sem nada limpo pela reciclagem")
        }
    }

    /// Every hook, after the host applied it.
    public func hook(_ update: HookUpdate, session id: UUID) {
        guard let open = state.open[id.uuidString] else { return }
        switch open.phase {
        case .waitingForStop, .waitingForStart:
            let trigger = open.phase == .waitingForStop ? "Stop" : "SessionStart"
            if update.event == trigger {
                host.after(Self.settle) { [weak self] in self?.runScheduled(id) }
            } else if update.status == .ended {
                stop(id, "a sessão terminou antes da reciclagem; nada foi limpo")
            }
        case .typing:
            break
        case .clearing:
            if update.event == "SessionStart", let new = update.claudeSessionId, new != open.record?.oldConversation {
                newConversation(new, session: id)
            }
        case .resuming, .waitingTurn:
            if update.event == "UserPromptSubmit", update.claudeSessionId == nil || update.claudeSessionId == open.new {
                if update.prompt?.contains(Handoff.resumePromptStart) == true {
                    succeed(id)
                } else {
                    // Another message got in first. The resume prompt goes after that turn.
                    var waiting = open
                    waiting.phase = .waitingTurn
                    set(id, waiting)
                    host.show(id, .waitingTurn)
                    arm(id, after: Self.retryDelay) { [weak self] in self?.deliverResume(id) }
                }
            } else if update.event == "Stop", open.phase == .waitingTurn {
                host.after(Self.settle) { [weak self] in self?.deliverResume(id) }
            } else if update.status == .ended {
                stop(id, "a sessão terminou antes de receber a mensagem de retomada; a Passagem está em \(open.record?.handoffFile ?? "?")")
            }
        }
    }

    /// The status line also tells when the conversation changed, in case the SessionStart hook is late.
    public func statusLine(conversation new: String?, session id: UUID) {
        guard let open = state.open[id.uuidString], open.phase == .clearing, let new, new != open.record?.oldConversation else { return }
        newConversation(new, session: id)
    }

    /// SessionStart with source "clear": the handoff of the recycle that sent it.
    public func sessionStartContext(session id: UUID) -> String? {
        // The status line may have told of the new conversation first: then the phase moved on,
        // and the context is still owed.
        guard var open = state.open[id.uuidString], let record = open.record,
              open.phase == .clearing || (!open.contextDelivered && (open.phase == .resuming || open.phase == .waitingTurn)) else { return nil }
        open.contextDelivered = true
        set(id, open)
        return HookOutput.additionalContext(event: "SessionStart", Handoff.sessionStartContext(record))
    }

    private func runScheduled(_ id: UUID) {
        guard let open = state.open[id.uuidString], open.phase == .waitingForStop || open.phase == .waitingForStart else { return }
        guard let subject = host.subject(id) else { return }
        // A message queued for the session starts a new turn right after Stop: wait for the next one.
        guard subject.status == .done || subject.status == .idle else { return }
        cancelTimer(id)
        host.thaw(id)
        if let refusal = begin(id) {
            let reason = refusal.message.dropFirstRecusado
            if refusal.busy { deferRecycle(id, reason: reason) } else { refuse(id, reason: reason) }
        }
    }

    /// Not stopped at the last moment: back to waiting for the end of the turn, said out loud.
    private func deferRecycle(_ id: UUID, reason: String) {
        guard var open = state.open[id.uuidString] else { return }
        open.deferrals += 1
        if open.deferrals > Self.maxDeferrals {
            refuse(id, reason: "adiada \(Self.maxDeferrals) vezes; a última: \(reason)")
            return
        }
        open.phase = .waitingForStop
        open.record = nil
        open.since = host.now
        set(id, open)
        let label = host.subject(id)?.label
        try? log.append(RecycleRecord(time: host.now, kind: .deferred, session: id.uuidString, label: label,
                                      cwd: host.subject(id)?.folder, reason: reason))
        host.show(id, .scheduled)
        host.tell(id, title: "Reciclagem adiada", body: "\(reason). Ela segue no fim do próximo turno.", attention: false)
        arm(id, after: Self.retryDelay) { [weak self] in self?.runScheduled(id) }
    }

    private func newConversation(_ new: String, session id: UUID) {
        guard var open = state.open[id.uuidString] else { return }
        cancelTimer(id)
        open.phase = .resuming
        open.new = new
        open.since = host.now
        set(id, open)
        host.show(id, .resuming)
        host.after(Self.resumeDelay) { [weak self] in self?.deliverResume(id) }
    }

    /// Pastes the resume prompt into an empty input and presses Enter. With a turn running, it
    /// waits for the turn's end; with the prompt already typed, it only presses Enter.
    private func deliverResume(_ id: UUID) {
        guard var open = state.open[id.uuidString], open.phase == .resuming || open.phase == .waitingTurn,
              let record = open.record, let subject = host.subject(id), subject.awake else { return }
        if subject.status == .working || subject.status == .waiting {
            open.phase = .waitingTurn
            set(id, open)
            host.show(id, .waitingTurn)
            // Stop is the usual way out; a turn that ends otherwise (an API error) is seen here.
            arm(id, after: Self.retryDelay) { [weak self] in self?.deliverResume(id) }
            return
        }
        let text = Handoff.resumePrompt(handoffFile: record.handoffFile ?? "", oldTranscript: record.oldTranscript ?? "")
        let typed = PromptScreen.typedInput(host.screen(id))
        if typed?.isEmpty == true {
            host.paste(id, text)
        } else if typed?.hasPrefix(Handoff.resumePromptStart) != true {
            // Someone's draft is there: it would go with the prompt. Wait for them to send it.
            open.phase = .waitingTurn
            let warn = !open.draftWarned
            open.draftWarned = true
            set(id, open)
            host.show(id, .waitingTurn)
            if warn {
                host.tell(id, title: "Retomada esperando", body: "a caixa de entrada não está vazia; a mensagem de retomada vai quando ela esvaziar", attention: true)
            }
            arm(id, after: Self.retryDelay) { [weak self] in self?.deliverResume(id) }
            return
        }
        open.phase = .resuming
        set(id, open)
        host.show(id, .resuming)
        host.after(0.5) { [weak self] in
            guard let self, self.state.open[id.uuidString]?.phase == .resuming else { return }
            self.host.pressEnter(id)
        }
        arm(id, after: Self.resumeTimeout) { [weak self] in
            self?.stop(id, "a mensagem de retomada foi digitada, mas não vi o envio em 30 s; a Passagem está em \(record.handoffFile ?? "?")")
        }
    }

    private func succeed(_ id: UUID) {
        guard let open = state.open[id.uuidString], let record = open.record else { return }
        cancelTimer(id)
        state.open[id.uuidString] = nil
        let done = record.followUp(.resumed, time: host.now, newConversation: open.new)
        try? log.append(done)
        state.checks[id.uuidString] = Check(record: done, at: host.now.addingTimeInterval(Self.checkDelay),
                                            contextDelivered: open.contextDelivered)
        save()
        armCheck(id)
        host.show(id, .done(host.now))
    }

    /// Something after the request went wrong. The old conversation is untouched on disk either way.
    private func stop(_ id: UUID, _ reason: String) {
        guard let open = state.open[id.uuidString] else { return }
        drop(id)
        if let record = open.record, open.phase != .typing {
            try? log.append(record.followUp(.failed, time: host.now, newConversation: open.new, reason: reason))
        }
        host.show(id, .failed(reason))
        host.tell(id, title: "Reciclagem não terminou", body: reason, attention: true)
    }

    /// A recycle that was due and the gate refused then: nobody else would see it.
    private func refuse(_ id: UUID, reason: String) {
        drop(id)
        let subject = host.subject(id)
        try? log.append(RecycleRecord(time: host.now, kind: .refused, session: id.uuidString, label: subject?.label,
                                      cwd: subject?.folder, oldConversation: subject?.conversation, reason: reason))
        host.show(id, .failed(reason))
        host.tell(id, title: "Reciclagem recusada", body: reason, attention: true)
    }

    // MARK: The check after a resume

    private func armCheck(_ id: UUID) {
        guard let check = state.checks[id.uuidString] else { return }
        checkTimers.removeValue(forKey: id)?()
        checkTimers[id] = host.after(max(0, check.at.timeIntervalSince(host.now))) { [weak self] in self?.runCheck(id) }
    }

    private func runCheck(_ id: UUID) {
        guard let check = state.checks.removeValue(forKey: id.uuidString) else { return }
        checkTimers[id] = nil
        save()
        let record = check.record
        let transcript = record.newConversation.flatMap { host.transcript(id, conversation: $0) }
        let result = ResumeCheck.verdict(transcript: transcript, handoffFile: record.handoffFile,
                                         contextDelivered: check.contextDelivered)
        try? log.append(record.followUp(.verified, time: host.now, verdict: result.verdict, reason: result.reason))
        if result.verdict == .quebrada {
            let reason = result.reason ?? "?"
            host.show(id, .failed("retomada quebrada: \(reason)"))
            host.tell(id, title: "Retomada quebrada", body: "\(reason). A Passagem está em \(record.handoffFile ?? "?").", attention: true)
        }
    }

    // MARK: After a restart

    /// Finishes what a restart interrupted: phases and checks come back from disk.
    public func recover() {
        for (key, open) in state.open {
            guard let id = UUID(uuidString: key) else { continue }
            guard let subject = host.subject(id), subject.awake || open.phase == .waitingForStart else {
                stop(id, "o \(program) reiniciou no meio da reciclagem e a sessão não está aberta; \(open.record?.handoffFile.map { "a Passagem está em \($0)" } ?? "nada foi limpo")")
                continue
            }
            switch open.phase {
            case .waitingForStop:
                host.show(id, .scheduled)
                host.after(Self.settle) { [weak self] in self?.runScheduled(id) }
            case .waitingForStart:
                stop(id, "o \(program) reiniciou enquanto a sessão acordava para reciclar; nada foi limpo")
            case .typing:
                takeBackClear(id, typed: PromptScreen.typedInput(host.screen(id)))
                stop(id, "o \(program) reiniciou com o /clear digitado e não enviado; nada foi limpo")
            case .clearing:
                // The conversation may have changed while nobody listened: the status line or the
                // next hook says so. The window still holds.
                host.show(id, open.late ? .delayed : .clearing)
                let record = open.record
                let left = (record?.time ?? host.now).addingTimeInterval(Self.lateWindow).timeIntervalSince(host.now)
                if let new = subject.conversation, new != record?.oldConversation {
                    newConversation(new, session: id)
                } else {
                    let program = program
                    arm(id, after: max(1, left)) { [weak self] in
                        self?.stop(id, "o \(program) reiniciou depois do /clear e a conversa nova não apareceu em \(Int(Self.lateWindow / 60)) min; a Passagem está em \(record?.handoffFile ?? "?")")
                    }
                }
            case .resuming, .waitingTurn:
                // The prompt may have gone while nobody listened.
                if let new = open.new, let path = host.transcript(id, conversation: new),
                   ResumeCheck.text(ofFile: path).contains(Handoff.resumePromptStart) {
                    succeed(id)
                } else {
                    host.after(Self.settle) { [weak self] in self?.deliverResume(id) }
                }
            }
        }
        for key in state.checks.keys {
            if let id = UUID(uuidString: key) { armCheck(id) }
        }
    }

    // MARK: Facts, state and timers

    private func facts(_ id: UUID, _ subject: RecycleSubject, screen: [ScreenLine]? = nil) -> RecycleFacts {
        let worktree = subject.folder.map { WorktreeFacts.read(cwd: $0, git: git) } ?? WorktreeFacts(git: .failed("pasta da sessão desconhecida"))
        let conversation = subject.hasConversation ? subject.conversation : nil
        let transcript = conversation.flatMap { host.transcript(id, conversation: $0) }
        let prompt = subject.awake ? PromptScreen.inputIsEmpty(screen ?? host.screen(id)) : nil
        return RecycleFacts(worktree: worktree, status: subject.status, conversation: conversation, transcript: transcript,
                            promptEmpty: prompt, pendingMessage: subject.pendingMessage,
                            turn: TranscriptTurn.read(path: transcript), now: host.now)
    }

    private func set(_ id: UUID, _ open: Open) {
        state.open[id.uuidString] = open
        save()
    }

    private func drop(_ id: UUID) {
        cancelTimer(id)
        state.open[id.uuidString] = nil
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            host.log("não consegui gravar \(stateURL.path): \(error)")
        }
    }

    private func arm(_ id: UUID, after seconds: TimeInterval, _ action: @escaping () -> Void) {
        cancelTimer(id)
        timers[id] = host.after(seconds, action)
    }

    private func cancelTimer(_ id: UUID) {
        timers.removeValue(forKey: id)?()
    }
}

private extension String {
    var dropFirstRecusado: String { hasPrefix("Recusado: ") ? String(dropFirst("Recusado: ".count)) : self }
}

extension ResumeCheck {
    /// Every user message's text in a transcript, to see whether a prompt went.
    static func text(ofFile path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return data.split(separator: 0x0A).compactMap { JSONValue.parse(Data($0)) }
            .filter { $0["type"]?.stringValue == "user" }.map(text(of:)).joined(separator: "\n")
    }
}
