import Foundation
import WorkspacesCore

/// Runs recycle_self, recycle_session and close_session. The sequence (gate, /clear, the new
/// conversation, the resume prompt, the check after it) is the one in WorkspacesCore
/// (RecycleEngine); this class only points it at the app's sessions.
@MainActor
final class Recycler {
    /// The sessions come back a moment after the app; then what a quit interrupted is finished.
    static let recoverDelay: TimeInterval = 10

    let log: RecycleLog
    private weak var model: AppModel?
    private let host: AppRecycleHost
    private let engine: RecycleEngine
    private let projectsRoot = AppRecycleHost.projectsRoot

    init(model: AppModel, log: RecycleLog = RecycleLog()) {
        self.model = model
        self.log = log
        host = AppRecycleHost(model: model)
        engine = RecycleEngine(host: host, log: log, git: "/usr/bin/git", actor: "o app", program: "Workspaces")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoverDelay) { [weak self] in
            self?.engine.recover()
        }
    }

    func isBusy(_ runtime: SessionRuntime) -> Bool { engine.isBusy(runtime.id) }

    /// The session was closed: nothing is waiting for it any more.
    func forget(_ id: UUID) { engine.forget(id) }

    // MARK: Tools

    /// recycle_self: checked now, run when the caller's turn ends (its own call is part of the turn).
    func requestSelf(_ caller: SessionRuntime) -> ToolResult {
        if caller.isTerminal { return Self.terminalRefusal }
        return engine.requestSelf(caller.id)
    }

    /// recycle_session: runs now, or after waking a hibernated session.
    func requestSession(_ target: SessionRuntime) -> ToolResult {
        guard model != nil else { return ToolResult(text: "O app está encerrando.", isError: true) }
        if target.isTerminal { return Self.terminalRefusal }
        return engine.requestSession(target.id)
    }

    private static let terminalRefusal = ToolResult(text: "Recusado: é um terminal, não uma sessão do Claude.", isError: true)

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
                                   handoff: worktree.frenteText.flatMap { Handoff.section(in: $0) },
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

    // MARK: From the model

    /// Every hook, after the app applied it.
    func hook(_ update: HookUpdate, runtime: SessionRuntime) {
        // A failed recycle stays on show until the session works again.
        if !isBusy(runtime), update.event == "UserPromptSubmit", runtime.recycle?.isFailure == true { runtime.recycle = nil }
        engine.hook(update, session: runtime.id)
    }

    /// The status line also tells when the conversation changed, in case the SessionStart hook is late.
    func statusLine(_ reading: StatusLineReading, runtime: SessionRuntime) {
        engine.statusLine(conversation: reading.sessionId, session: runtime.id)
    }

    /// SessionStart with source "clear": the Passagem, the old transcript and where the worktree stands.
    func sessionStartContext(for runtime: SessionRuntime) -> String? {
        engine.sessionStartContext(session: runtime.id)
    }
}

/// The app's sessions as the recycle sees them. Not isolated itself: the engine calls it on the
/// main queue, where every timer it sets runs too.
final class AppRecycleHost: RecycleHost {
    static let projectsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    var now: Date { Date() }

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }

    func subject(_ id: UUID) -> RecycleSubject? {
        MainActor.assumeIsolated {
            guard let model, let runtime = model.session(id), !runtime.isTerminal else { return nil }
            return RecycleSubject(
                label: model.displayLabel(runtime), folder: runtime.cwd ?? model.project(runtime.projectId)?.project.path,
                awake: runtime.host.isRunning && runtime.sleep != .hibernated, hibernated: runtime.sleep == .hibernated,
                status: runtime.status, conversation: runtime.claudeSessionId, hasConversation: runtime.hasConversation,
                pendingMessage: model.hasPendingPaste(id), contextTokens: model.tokens.context(runtime))
        }
    }

    func screen(_ id: UUID) -> [ScreenLine] {
        MainActor.assumeIsolated {
            guard let runtime = model?.session(id), runtime.host.isRunning, runtime.sleep != .hibernated else { return [] }
            let screen = runtime.host.screen(lines: 400)
            #if DEBUG
            if PromptScreen.inputIsEmpty(screen) != true {
                NSLog("recycle: input line not seen empty; bottom of screen:\n%@", screen.suffix(12).map(\.text).joined(separator: "\n"))
            }
            #endif
            return screen
        }
    }

    func processID(_ id: UUID) -> Int32? {
        MainActor.assumeIsolated { model?.session(id)?.host.pid }
    }

    func transcript(_ id: UUID, conversation: String) -> String? {
        MainActor.assumeIsolated {
            let hint = model?.session(id)?.transcriptPath
            return TranscriptLocator.find(conversation: conversation, hint: hint, root: Self.projectsRoot)
        }
    }

    func type(_ id: UUID, _ text: String) {
        MainActor.assumeIsolated { () -> Void in model?.session(id)?.host.type(text) }
    }

    func paste(_ id: UUID, _ text: String) {
        MainActor.assumeIsolated { () -> Void in model?.session(id)?.host.paste(text) }
    }

    func pressEnter(_ id: UUID) {
        MainActor.assumeIsolated { () -> Void in model?.session(id)?.host.pressReturn() }
    }

    func deleteFromStart(_ id: UUID, count: Int) {
        // Ctrl+A to the start of the line, then the Delete key (never Ctrl+D, which can end Claude).
        MainActor.assumeIsolated { () -> Void in
            model?.session(id)?.host.type("\u{01}" + String(repeating: "\u{1b}[3~", count: count))
        }
    }

    func wake(_ id: UUID) -> String? {
        MainActor.assumeIsolated {
            guard let model else { return "o app está encerrando" }
            model.wake(id)
            return nil
        }
    }

    func thaw(_ id: UUID) {
        MainActor.assumeIsolated { () -> Void in
            if model?.session(id)?.sleep == .frozen { model?.wake(id) }
        }
    }

    func show(_ id: UUID, _ progress: RecycleProgress?) {
        MainActor.assumeIsolated { () -> Void in model?.session(id)?.recycle = progress }
    }

    func tell(_ id: UUID, title: String, body: String, attention: Bool) {
        MainActor.assumeIsolated { () -> Void in
            guard let model, let runtime = model.session(id) else { return }
            if attention {
                runtime.attention = true
                model.updateBadge()
            }
            Notifier.shared.post(title: "\(title): \(model.displayLabel(runtime))", body: body, sessionId: id)
        }
    }

    func pullRequest(root: String, branch: String) -> String? {
        guard let gh = PullRequestLookup.locate(path: nil) else { return nil }
        return PullRequestLookup.find(gh: gh, root: root, branch: branch)
    }

    func log(_ text: String) {
        NSLog("recycle: %@", text)
    }
}
