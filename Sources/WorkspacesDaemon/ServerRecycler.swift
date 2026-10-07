import Foundation
import WorkspacesCore

/// recycle_self, recycle_session and close_session on the server: the same gate, log and fixed
/// texts as the app's Recycler (WorkspacesCore), with tmux as the terminal. Any step that could
/// lose context refuses or stops instead, says why, and leaves the old conversation where it was.
// Copy of the app's Recycler sequence; to be shared behind a terminal protocol later.
final class ServerRecycler {
    private enum Phase {
        case waitingForStop
        case waitingForStart
        case clearing(old: String, record: RecycleRecord)
        case resuming(new: String, record: RecycleRecord)
    }

    static let settle: TimeInterval = 2.5
    static let clearTimeout: TimeInterval = 30
    static let resumeTimeout: TimeInterval = 30
    static let wakeTimeout: TimeInterval = 120

    let log: RecycleLog
    private unowned let daemon: Daemon
    private var phases: [UUID: Phase] = [:]
    private var timers: [UUID: ScheduledWork] = [:]

    init(daemon: Daemon, log: RecycleLog) {
        self.daemon = daemon
        self.log = log
    }

    private var scheduler: Scheduler { daemon.scheduler }
    private var terminal: SessionTerminal { daemon.terminal }

    func isBusy(_ session: ServerSession) -> Bool { phases[session.id] != nil }

    func forget(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        phases[id] = nil
    }

    // MARK: Tools

    func requestSelf(_ caller: ServerSession) -> ToolResult {
        if let refusal = basicRefusal(caller) { return refusal }
        if case .failure(let refusal) = RecycleGate.check(facts(for: caller), turnEnded: false) {
            return ToolResult(text: refusal.message, isError: true)
        }
        phases[caller.id] = .waitingForStop
        caller.recycle = .scheduled
        return ToolResult(text: "Reciclagem agendada. Quando este turno terminar, o servidor confere a trava de novo (Passagem do FRENTE.md salva nos últimos 30 min, git status limpo, caixa de entrada vazia), registra em recycles.jsonl, envia /clear e depois a mensagem fixa de retomada. Encerre o turno agora, sem mudar mais nada.")
    }

    func requestSession(_ target: ServerSession) -> ToolResult {
        if let refusal = basicRefusal(target) { return refusal }
        if target.hibernated {
            if case .failure(let refusal) = RecycleGate.check(facts(for: target), turnEnded: false) {
                return ToolResult(text: refusal.message, isError: true)
            }
            phases[target.id] = .waitingForStart
            target.recycle = .waking
            arm(target, after: Self.wakeTimeout) { [weak self, weak target] in
                guard let self, let target else { return }
                self.stop(target, "a sessão não voltou em 2 min depois de acordar; nada foi limpo", log: false)
            }
            if let failure = daemon.wake(target) {
                forget(target.id)
                target.recycle = nil
                return ToolResult(text: "Recusado: não consegui acordar \(target.label) (\(failure)).", isError: true)
            }
            return ToolResult(text: "\(target.label) estava hibernando e está acordando. A reciclagem segue quando ela abrir, com a trava conferida de novo; acompanhe em list_sessions.")
        }
        switch begin(target) {
        case .failure(let message):
            return ToolResult(text: message.text, isError: true)
        case .success(let record):
            return ToolResult(text: "Registrado em recycles.jsonl e /clear enviado para \(target.label). A conversa anterior continua em \(record.oldTranscript ?? "?"). Quando a conversa nova começar, o servidor envia a mensagem fixa de retomada; acompanhe em list_sessions.")
        }
    }

    func close(_ target: ServerSession) -> ToolResult {
        guard !isBusy(target) else { return ToolResult(text: "Recusado: há uma reciclagem em andamento nesta sessão.", isError: true) }
        let folder = daemon.folder(of: target)
        let worktree = folder.map { WorktreeFacts.read(cwd: $0, git: Self.git) } ?? WorktreeFacts(git: .failed("pasta da sessão desconhecida"))
        // A hibernated session is not in a turn, whatever it was doing when it went to sleep.
        let status: SessionStatus = target.hibernated ? .idle : target.status
        if let refusal = RecycleGate.checkClose(status: status, git: worktree.git) {
            return ToolResult(text: refusal.message, isError: true)
        }
        let conversation = target.hasConversation ? target.claudeSessionId : nil
        let transcript = conversation.flatMap { locate($0, session: target) }
        let record = RecycleRecord(kind: .close, session: target.id.uuidString, label: target.label, cwd: folder,
                                   frente: worktree.frenteText == nil ? nil : worktree.frentePath,
                                   oldConversation: conversation, oldTranscript: transcript,
                                   handoff: worktree.frenteText.flatMap(Handoff.section(in:)),
                                   contextTokens: target.contextTokens)
        do {
            try log.append(record)
        } catch {
            return ToolResult(text: "Recusado: não consegui registrar em \(log.url.path) (\(error.localizedDescription)); nada foi fechado.", isError: true)
        }
        daemon.close(target)
        let kept = transcript.map { " A conversa continua em \($0)." } ?? ""
        return ToolResult(text: "Fechei \(target.label) e registrei em recycles.jsonl.\(kept)")
    }

    private func basicRefusal(_ session: ServerSession) -> ToolResult? {
        if isBusy(session) { return ToolResult(text: "Recusado: já há uma reciclagem em andamento nesta sessão.", isError: true) }
        if !session.hibernated, !terminal.isRunning(session.terminalName) {
            return ToolResult(text: "Recusado: a sessão está encerrada.", isError: true)
        }
        if session.pendingPaste != nil {
            return ToolResult(text: "Recusado: um recado espera para ser digitado nesta sessão, e iria junto com o /clear.", isError: true)
        }
        return nil
    }

    // MARK: The sequence

    private struct Message: Error {
        let text: String
    }

    private func begin(_ session: ServerSession) -> Result<RecycleRecord, Message> {
        guard !session.hibernated, terminal.isRunning(session.terminalName) else {
            return .failure(Message(text: "Recusado: a sessão não está acordada."))
        }
        let facts = facts(for: session)
        let handoff: String
        switch RecycleGate.check(facts) {
        case .failure(let refusal): return .failure(Message(text: refusal.message))
        case .success(let text): handoff = text
        }
        guard let old = facts.conversation, let transcript = facts.transcript else {
            return .failure(Message(text: RecycleRefusal.noConversation.message))
        }
        let record = RecycleRecord(kind: .recycle, session: session.id.uuidString, label: session.label,
                                   cwd: session.record.cwd, frente: facts.worktree.frentePath, oldConversation: old,
                                   oldTranscript: transcript, handoff: handoff, contextTokens: session.contextTokens)
        do {
            try log.append(record)
        } catch {
            return .failure(Message(text: "Recusado: não consegui registrar em \(log.url.path) (\(error.localizedDescription)); nada foi limpo."))
        }
        phases[session.id] = .clearing(old: old, record: record)
        session.recycle = .clearing
        let name = session.terminalName
        terminal.type(name, "/clear")
        scheduler.after(0.4) { [weak self, weak session] in
            guard let self, let session, case .clearing? = self.phases[session.id] else { return }
            self.terminal.pressEnter(name)
        }
        arm(session, after: Self.clearTimeout) { [weak self, weak session] in
            guard let self, let session else { return }
            self.stop(session, "a conversa nova não começou em 30 s depois do /clear; a anterior continua em \(transcript)", log: true)
        }
        return .success(record)
    }

    func hook(_ update: HookUpdate, session: ServerSession) {
        guard let phase = phases[session.id] else {
            if update.event == "UserPromptSubmit", session.recycle?.isFailure == true { session.recycle = nil }
            return
        }
        switch phase {
        case .waitingForStop, .waitingForStart:
            let trigger: String
            if case .waitingForStop = phase { trigger = "Stop" } else { trigger = "SessionStart" }
            if update.event == trigger {
                scheduler.after(Self.settle) { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.runScheduled(session)
                }
            } else if update.status == .ended {
                stop(session, "a sessão terminou antes da reciclagem; nada foi limpo", log: false)
            }
        case .clearing(let old, let record):
            if update.event == "SessionStart", let new = update.claudeSessionId, new != old {
                newConversation(new, session: session, record: record)
            }
        case .resuming(let new, let record):
            if update.event == "UserPromptSubmit", update.claudeSessionId == nil || update.claudeSessionId == new {
                succeed(session, new: new, record: record)
            }
        }
    }

    func statusLine(_ reading: StatusLineReading, session: ServerSession) {
        guard case .clearing(let old, let record)? = phases[session.id], let new = reading.sessionId, new != old else { return }
        newConversation(new, session: session, record: record)
    }

    func sessionStartContext(for session: ServerSession) -> String? {
        guard let record = RecycleLog.pendingHandoff(in: log.records(), session: session.id.uuidString, now: scheduler.now) else { return nil }
        return HookOutput.additionalContext(event: "SessionStart", Handoff.sessionStartContext(record))
    }

    private func runScheduled(_ session: ServerSession) {
        guard let phase = phases[session.id] else { return }
        switch phase {
        case .waitingForStop, .waitingForStart: break
        case .clearing, .resuming: return
        }
        // A message queued for the session starts a new turn right after Stop: wait for the next one.
        guard session.status == .done || session.status == .idle else { return }
        cancelTimer(session.id)
        phases[session.id] = nil
        if case .failure(let message) = begin(session) {
            refuseScheduled(session, message.text)
        }
    }

    private func newConversation(_ new: String, session: ServerSession, record: RecycleRecord) {
        cancelTimer(session.id)
        phases[session.id] = .resuming(new: new, record: record)
        session.recycle = .resuming
        let text = Handoff.resumePrompt(oldTranscript: record.oldTranscript ?? "")
        let name = session.terminalName
        // SessionStart comes a moment before the prompt takes input.
        scheduler.after(1.5) { [weak self, weak session] in
            guard let self, let session, case .resuming(let current, _)? = self.phases[session.id], current == new else { return }
            self.terminal.paste(name, text)
            self.scheduler.after(0.5) { [weak self, weak session] in
                guard let self, let session, case .resuming(let current, _)? = self.phases[session.id], current == new else { return }
                self.terminal.pressEnter(name)
            }
        }
        arm(session, after: Self.resumeTimeout) { [weak self, weak session] in
            guard let self, let session else { return }
            self.stop(session, "a mensagem de retomada foi digitada, mas não vi o envio em 30 s; confira a caixa de entrada da sessão", log: true)
        }
    }

    private func succeed(_ session: ServerSession, new: String, record: RecycleRecord) {
        cancelTimer(session.id)
        phases[session.id] = nil
        let done = RecycleRecord(kind: .resumed, session: record.session, label: record.label, cwd: record.cwd,
                                 frente: record.frente, oldConversation: record.oldConversation,
                                 oldTranscript: record.oldTranscript, newConversation: new)
        try? log.append(done)
        session.recycle = .done(scheduler.now)
    }

    private func stop(_ session: ServerSession, _ reason: String, log logged: Bool) {
        guard let phase = phases.removeValue(forKey: session.id) else { return }
        cancelTimer(session.id)
        if logged {
            var record: RecycleRecord?
            switch phase {
            case .clearing(_, let r), .resuming(_, let r): record = r
            case .waitingForStop, .waitingForStart: record = nil
            }
            if var failed = record {
                failed.time = scheduler.now
                failed.kind = .failed
                failed.handoff = nil
                failed.reason = reason
                try? log.append(failed)
            }
        }
        tellOwner(session, title: "Reciclagem não terminou", reason: reason)
    }

    private func refuseScheduled(_ session: ServerSession, _ message: String) {
        let reason = message.hasPrefix("Recusado: ") ? String(message.dropFirst("Recusado: ".count)) : message
        try? log.append(RecycleRecord(kind: .refused, session: session.id.uuidString, label: session.label,
                                      cwd: session.record.cwd, oldConversation: session.claudeSessionId, reason: reason))
        tellOwner(session, title: "Reciclagem recusada", reason: reason)
    }

    private func tellOwner(_ session: ServerSession, title: String, reason: String) {
        session.recycle = .failed(reason)
        session.attention = true
        _ = daemon.notifier.post(title: "\(title): \(session.label)", body: reason)
        daemon.log("\(title): \(session.label): \(reason)")
    }

    // MARK: Facts and timers

    static let git = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    private func locate(_ conversation: String, session: ServerSession) -> String? {
        let root = URL(fileURLWithPath: daemon.server.configDirectory(account: session.record.account))
            .appendingPathComponent("projects", isDirectory: true)
        return TranscriptLocator.find(conversation: conversation, hint: session.transcriptPath, root: root)
    }

    private func facts(for session: ServerSession) -> RecycleFacts {
        let folder = daemon.folder(of: session)
        let worktree = folder.map { WorktreeFacts.read(cwd: $0, git: Self.git) } ?? WorktreeFacts(git: .failed("pasta da sessão desconhecida"))
        let conversation = session.hasConversation ? session.claudeSessionId : nil
        let transcript = conversation.flatMap { locate($0, session: session) }
        let awake = !session.hibernated && terminal.isRunning(session.terminalName)
        let prompt = awake ? PromptScreen.inputIsEmpty(ScreenParser.lines(terminal.capture(session.terminalName))) : nil
        return RecycleFacts(worktree: worktree, status: session.status, conversation: conversation, transcript: transcript,
                            promptEmpty: prompt, now: scheduler.now)
    }

    private func arm(_ session: ServerSession, after seconds: TimeInterval, _ action: @escaping () -> Void) {
        cancelTimer(session.id)
        timers[session.id] = scheduler.after(seconds, action)
    }

    private func cancelTimer(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
    }
}
