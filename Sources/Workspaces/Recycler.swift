import Foundation
import WorkspacesCore

/// Runs recycle_self, recycle_session and close_session: the gate, the log, "/clear", the new
/// conversation and the fixed message. Any step that could lose context refuses or stops instead,
/// says why, and leaves the old conversation where it was.
@MainActor
final class Recycler {
    private enum Phase {
        /// recycle_self: waits for the caller's turn to end.
        case waitingForStop
        /// recycle_session on a hibernated session: waits for it to start again.
        case waitingForStart
        /// Logged and "/clear" sent: waits for the new conversation.
        case clearing(old: String, record: RecycleRecord)
        /// The new conversation exists; the fixed message was typed and Enter pressed.
        case resuming(new: String, record: RecycleRecord)
    }

    private struct Failure: Error {
        let message: String
    }

    /// When a turn ends Claude Code may still send messages the person queued; wait, then look again.
    static let settle: TimeInterval = 2.5
    static let clearTimeout: TimeInterval = 30
    static let resumeTimeout: TimeInterval = 30
    static let wakeTimeout: TimeInterval = 120

    let log: RecycleLog
    private weak var model: AppModel?
    private var phases: [UUID: Phase] = [:]
    private var timers: [UUID: DispatchWorkItem] = [:]
    private let projectsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)

    init(model: AppModel, log: RecycleLog = RecycleLog()) {
        self.model = model
        self.log = log
    }

    func isBusy(_ runtime: SessionRuntime) -> Bool { phases[runtime.id] != nil }

    /// The session was closed: nothing is waiting for it any more.
    func forget(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        phases[id] = nil
    }

    // MARK: Tools

    /// recycle_self: checked now, run when the caller's turn ends (its own call is part of the turn).
    func requestSelf(_ caller: SessionRuntime) -> ToolResult {
        if let refusal = basicRefusal(caller) { return refusal }
        if case .failure(let refusal) = RecycleGate.check(facts(for: caller), turnEnded: false) {
            return ToolResult(text: refusal.message, isError: true)
        }
        phases[caller.id] = .waitingForStop
        caller.recycle = .scheduled
        return ToolResult(text: "Reciclagem agendada. Quando este turno terminar, o app confere a trava de novo (Passagem do FRENTE.md salva nos últimos 30 min, git status limpo, caixa de entrada vazia), registra em recycles.jsonl, envia /clear e depois a mensagem fixa de retomada. Encerre o turno agora, sem mudar mais nada.")
    }

    /// recycle_session: runs now, or after waking a hibernated session.
    func requestSession(_ target: SessionRuntime) -> ToolResult {
        guard let model else { return ToolResult(text: "O app está encerrando.", isError: true) }
        if let refusal = basicRefusal(target) { return refusal }
        let label = model.displayLabel(target)
        if target.sleep == .hibernated {
            if case .failure(let refusal) = RecycleGate.check(facts(for: target), turnEnded: false) {
                return ToolResult(text: refusal.message, isError: true)
            }
            phases[target.id] = .waitingForStart
            target.recycle = .waking
            arm(target, after: Self.wakeTimeout) { [weak self, weak target] in
                guard let self, let target else { return }
                self.stop(target, "a sessão não voltou em 2 min depois de acordar; nada foi limpo", log: false)
            }
            model.wake(target.id)
            return ToolResult(text: "\(label) estava hibernando e está acordando. A reciclagem segue quando ela abrir, com a trava conferida de novo; acompanhe em list_sessions.")
        }
        if target.sleep == .frozen { model.wake(target.id) }
        switch begin(target) {
        case .failure(let failure):
            return ToolResult(text: failure.message, isError: true)
        case .success(let record):
            return ToolResult(text: "Registrado em recycles.jsonl e /clear enviado para \(label). A conversa anterior continua em \(record.oldTranscript ?? "?"). Quando a conversa nova começar, o app envia a mensagem fixa de retomada; acompanhe em list_sessions.")
        }
    }

    /// close_session: refused while the session works or waits, or with changes not committed. Logged first.
    func close(_ target: SessionRuntime) -> ToolResult {
        guard let model else { return ToolResult(text: "O app está encerrando.", isError: true) }
        guard !isBusy(target) else { return ToolResult(text: "Recusado: há uma reciclagem em andamento nesta sessão.", isError: true) }
        let folder = target.cwd ?? model.project(target.projectId)?.project.path
        let worktree = folder.map { WorktreeFacts.read(cwd: $0) } ?? WorktreeFacts(git: .failed("pasta da sessão desconhecida"))
        if let refusal = RecycleGate.checkClose(status: target.status, git: worktree.git) {
            return ToolResult(text: refusal.message, isError: true)
        }
        let conversation = target.hasConversation ? target.claudeSessionId : nil
        let transcript = conversation.flatMap { TranscriptLocator.find(conversation: $0, hint: target.transcriptPath, root: projectsRoot) }
        let record = RecycleRecord(kind: .close, session: target.id.uuidString, label: model.displayLabel(target), cwd: folder,
                                   frente: worktree.frenteText == nil ? nil : worktree.frentePath,
                                   oldConversation: conversation, oldTranscript: transcript,
                                   handoff: worktree.frenteText.flatMap(Handoff.section(in:)),
                                   contextTokens: model.tokens.context(target))
        do {
            try log.append(record)
        } catch {
            return ToolResult(text: "Recusado: não consegui registrar em \(log.url.path) (\(error.localizedDescription)); nada foi fechado.", isError: true)
        }
        let label = model.displayLabel(target)
        model.closeSession(target.id)
        let kept = transcript.map { " A conversa continua em \($0)." } ?? ""
        return ToolResult(text: "Fechei \(label) e registrei em recycles.jsonl.\(kept)")
    }

    private func basicRefusal(_ runtime: SessionRuntime) -> ToolResult? {
        if runtime.isTerminal { return ToolResult(text: "Recusado: é um terminal, não uma sessão do Claude.", isError: true) }
        if isBusy(runtime) { return ToolResult(text: "Recusado: já há uma reciclagem em andamento nesta sessão.", isError: true) }
        if !runtime.host.isRunning, runtime.sleep != .hibernated {
            return ToolResult(text: "Recusado: a sessão está encerrada.", isError: true)
        }
        if model?.hasPendingPaste(runtime.id) == true {
            return ToolResult(text: "Recusado: um recado espera para ser digitado nesta sessão, e iria junto com o /clear.", isError: true)
        }
        return nil
    }

    // MARK: The sequence

    /// Gate, log, then "/clear". Nothing is cleared unless the log line is on disk.
    private func begin(_ runtime: SessionRuntime) -> Result<RecycleRecord, Failure> {
        guard let model else { return .failure(Failure(message: "O app está encerrando.")) }
        guard runtime.host.isRunning, runtime.sleep == .awake else {
            return .failure(Failure(message: "Recusado: a sessão não está acordada."))
        }
        let facts = facts(for: runtime)
        let handoff: String
        switch RecycleGate.check(facts) {
        case .failure(let refusal): return .failure(Failure(message: refusal.message))
        case .success(let text): handoff = text
        }
        guard let old = facts.conversation, let transcript = facts.transcript else {
            return .failure(Failure(message: RecycleRefusal.noConversation.message))
        }
        let record = RecycleRecord(kind: .recycle, session: runtime.id.uuidString, label: model.displayLabel(runtime),
                                   cwd: runtime.cwd, frente: facts.worktree.frentePath, oldConversation: old,
                                   oldTranscript: transcript, handoff: handoff, contextTokens: model.tokens.context(runtime))
        do {
            try log.append(record)
        } catch {
            return .failure(Failure(message: "Recusado: não consegui registrar em \(log.url.path) (\(error.localizedDescription)); nada foi limpo."))
        }
        phases[runtime.id] = .clearing(old: old, record: record)
        runtime.recycle = .clearing
        runtime.host.type("/clear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak runtime] in
            guard let self, let runtime, case .clearing? = self.phases[runtime.id] else { return }
            runtime.host.pressReturn()
        }
        arm(runtime, after: Self.clearTimeout) { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.stop(runtime, "a conversa nova não começou em 30 s depois do /clear; a anterior continua em \(transcript)", log: true)
        }
        return .success(record)
    }

    /// Every hook, after the app applied it.
    func hook(_ update: HookUpdate, runtime: SessionRuntime) {
        guard let phase = phases[runtime.id] else {
            // A failed recycle stays on show until the session works again.
            if update.event == "UserPromptSubmit", runtime.recycle?.isFailure == true { runtime.recycle = nil }
            return
        }
        switch phase {
        case .waitingForStop, .waitingForStart:
            let trigger: String
            if case .waitingForStop = phase { trigger = "Stop" } else { trigger = "SessionStart" }
            if update.event == trigger {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self, weak runtime] in
                    guard let self, let runtime else { return }
                    self.runScheduled(runtime)
                }
            } else if update.status == .ended {
                stop(runtime, "a sessão terminou antes da reciclagem; nada foi limpo", log: false)
            }
        case .clearing(let old, let record):
            if update.event == "SessionStart", let new = update.claudeSessionId, new != old {
                newConversation(new, runtime: runtime, record: record)
            }
        case .resuming(let new, let record):
            if update.event == "UserPromptSubmit", update.claudeSessionId == nil || update.claudeSessionId == new {
                succeed(runtime, new: new, record: record)
            }
        }
    }

    /// The status line also tells when the conversation changed, in case the SessionStart hook is late.
    func statusLine(_ reading: StatusLineReading, runtime: SessionRuntime) {
        guard case .clearing(let old, let record)? = phases[runtime.id], let new = reading.sessionId, new != old else { return }
        newConversation(new, runtime: runtime, record: record)
    }

    /// SessionStart with source "clear": the Passagem and the old transcript, from recycles.jsonl.
    func sessionStartContext(for runtime: SessionRuntime) -> String? {
        guard let record = RecycleLog.pendingHandoff(in: log.records(), session: runtime.id.uuidString, now: Date()) else { return nil }
        return HookOutput.additionalContext(event: "SessionStart", Handoff.sessionStartContext(record))
    }

    private func runScheduled(_ runtime: SessionRuntime) {
        guard let phase = phases[runtime.id] else { return }
        switch phase {
        case .waitingForStop, .waitingForStart: break
        case .clearing, .resuming: return
        }
        // A message the person queued starts a new turn right after Stop: wait for the next one.
        guard runtime.status == .done || runtime.status == .idle else { return }
        cancelTimer(runtime.id)
        phases[runtime.id] = nil
        if runtime.sleep == .frozen { model?.wake(runtime.id) }
        if case .failure(let failure) = begin(runtime) {
            refuseScheduled(runtime, failure.message)
        }
    }

    private func newConversation(_ new: String, runtime: SessionRuntime, record: RecycleRecord) {
        cancelTimer(runtime.id)
        phases[runtime.id] = .resuming(new: new, record: record)
        runtime.recycle = .resuming
        let text = Handoff.resumePrompt(oldTranscript: record.oldTranscript ?? "")
        // SessionStart comes a moment before the prompt takes input.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak runtime] in
            guard let self, let runtime, case .resuming(let current, _)? = self.phases[runtime.id], current == new else { return }
            runtime.host.paste(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak runtime] in
                guard let self, let runtime, case .resuming(let current, _)? = self.phases[runtime.id], current == new else { return }
                runtime.host.pressReturn()
            }
        }
        arm(runtime, after: Self.resumeTimeout) { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.stop(runtime, "a mensagem de retomada foi digitada, mas não vi o envio em 30 s; confira a caixa de entrada da sessão", log: true)
        }
    }

    private func succeed(_ runtime: SessionRuntime, new: String, record: RecycleRecord) {
        cancelTimer(runtime.id)
        phases[runtime.id] = nil
        let done = RecycleRecord(kind: .resumed, session: record.session, label: record.label, cwd: record.cwd,
                                 frente: record.frente, oldConversation: record.oldConversation,
                                 oldTranscript: record.oldTranscript, newConversation: new)
        try? log.append(done)
        runtime.recycle = .done(Date())
    }

    /// Something after the request went wrong. The old conversation is untouched on disk either way.
    private func stop(_ runtime: SessionRuntime, _ reason: String, log logged: Bool) {
        guard let phase = phases.removeValue(forKey: runtime.id) else { return }
        cancelTimer(runtime.id)
        if logged {
            var record: RecycleRecord?
            switch phase {
            case .clearing(_, let r), .resuming(_, let r): record = r
            case .waitingForStop, .waitingForStart: record = nil
            }
            if var failed = record {
                failed.time = Date()
                failed.kind = .failed
                failed.handoff = nil
                failed.reason = reason
                try? log.append(failed)
            }
        }
        tellOwner(runtime, title: "Reciclagem não terminou", reason: reason)
    }

    /// A recycle_self that waited for its turn and was refused then: nobody else would see it.
    private func refuseScheduled(_ runtime: SessionRuntime, _ message: String) {
        let reason = message.hasPrefix("Recusado: ") ? String(message.dropFirst("Recusado: ".count)) : message
        try? log.append(RecycleRecord(kind: .refused, session: runtime.id.uuidString, label: model?.displayLabel(runtime),
                                      cwd: runtime.cwd, oldConversation: runtime.claudeSessionId, reason: reason))
        tellOwner(runtime, title: "Reciclagem recusada", reason: reason)
    }

    private func tellOwner(_ runtime: SessionRuntime, title: String, reason: String) {
        runtime.recycle = .failed(reason)
        runtime.attention = true
        model?.updateBadge()
        let label = model?.displayLabel(runtime) ?? runtime.label
        Notifier.shared.post(title: "\(title): \(label)", body: reason, sessionId: runtime.id)
    }

    // MARK: Facts and timers

    private func facts(for runtime: SessionRuntime) -> RecycleFacts {
        let folder = runtime.cwd ?? model?.project(runtime.projectId)?.project.path
        let worktree = folder.map { WorktreeFacts.read(cwd: $0) } ?? WorktreeFacts(git: .failed("pasta da sessão desconhecida"))
        let conversation = runtime.hasConversation ? runtime.claudeSessionId : nil
        let transcript = conversation.flatMap { TranscriptLocator.find(conversation: $0, hint: runtime.transcriptPath, root: projectsRoot) }
        let awake = runtime.host.isRunning && runtime.sleep == .awake
        let screen = awake ? runtime.host.snapshot(lines: 400) : []
        let prompt = awake ? PromptScreen.inputIsEmpty(screen) : nil
        #if DEBUG
        if prompt != true { NSLog("recycle: input line not seen empty; bottom of screen:\n%@", screen.suffix(12).joined(separator: "\n")) }
        #endif
        return RecycleFacts(worktree: worktree, status: runtime.status, conversation: conversation, transcript: transcript,
                            promptEmpty: prompt)
    }

    private func arm(_ runtime: SessionRuntime, after seconds: TimeInterval, _ action: @escaping () -> Void) {
        cancelTimer(runtime.id)
        let work = DispatchWorkItem(block: action)
        timers[runtime.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimer(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
    }
}
