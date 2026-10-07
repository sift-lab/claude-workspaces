import Foundation
import WorkspacesCore

/// recycle_self, recycle_session and close_session on the server: the sequence is the one in
/// WorkspacesCore (RecycleEngine), with tmux as the terminal. Any step that could lose context
/// waits or stops instead, says why, and leaves the old conversation where it was.
final class ServerRecycler: RecycleHost {
    let log: RecycleLog
    private unowned let daemon: Daemon
    private(set) var engine: RecycleEngine!

    init(daemon: Daemon, log: RecycleLog) {
        self.daemon = daemon
        self.log = log
        engine = RecycleEngine(host: self, log: log, git: Self.git, actor: "o servidor", program: "workspacesd")
    }

    private var terminal: SessionTerminal { daemon.terminal }

    func isBusy(_ session: ServerSession) -> Bool { engine.isBusy(session.id) }

    func forget(_ id: UUID) { engine.forget(id) }

    // MARK: Tools

    func requestSelf(_ caller: ServerSession) -> ToolResult { engine.requestSelf(caller.id) }

    func requestSession(_ target: ServerSession) -> ToolResult { engine.requestSession(target.id) }

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
        let record = RecycleRecord(time: daemon.scheduler.now, kind: .close, session: target.id.uuidString, label: target.label, cwd: folder,
                                   frente: worktree.frenteText == nil ? nil : worktree.frentePath,
                                   oldConversation: conversation, oldTranscript: transcript,
                                   handoff: worktree.frenteText.flatMap { Handoff.section(in: $0, now: daemon.scheduler.now) },
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

    // MARK: From the daemon

    func hook(_ update: HookUpdate, session: ServerSession) {
        // A failed recycle stays on show until the session works again.
        if !isBusy(session), update.event == "UserPromptSubmit", session.recycle?.isFailure == true { session.recycle = nil }
        engine.hook(update, session: session.id)
    }

    func statusLine(_ reading: StatusLineReading, session: ServerSession) {
        engine.statusLine(conversation: reading.sessionId, session: session.id)
    }

    func sessionStartContext(for session: ServerSession) -> String? {
        engine.sessionStartContext(session: session.id)
    }

    func recover() { engine.recover() }

    // MARK: RecycleHost

    var now: Date { daemon.scheduler.now }

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let token = daemon.scheduler.after(seconds, work)
        return { token.cancel() }
    }

    func subject(_ id: UUID) -> RecycleSubject? {
        guard let session = daemon.session(id) else { return nil }
        return RecycleSubject(label: session.label, folder: daemon.folder(of: session), awake: daemon.isAwake(session),
                              hibernated: session.hibernated, status: session.status, conversation: session.claudeSessionId,
                              hasConversation: session.hasConversation, pendingMessage: session.pendingPaste != nil,
                              contextTokens: session.contextTokens)
    }

    func screen(_ id: UUID) -> [ScreenLine] {
        guard let session = daemon.session(id), daemon.isAwake(session) else { return [] }
        return ScreenParser.lines(terminal.capture(session.terminalName))
    }

    func processID(_ id: UUID) -> Int32? {
        daemon.session(id).flatMap { terminal.pid($0.terminalName) }
    }

    func transcript(_ id: UUID, conversation: String) -> String? {
        daemon.session(id).flatMap { locate(conversation, session: $0) }
    }

    func type(_ id: UUID, _ text: String) { withTerminal(id) { terminal.type($0, text) } }

    func paste(_ id: UUID, _ text: String) { withTerminal(id) { terminal.paste($0, text) } }

    func pressEnter(_ id: UUID) { withTerminal(id) { terminal.pressEnter($0) } }

    func deleteFromStart(_ id: UUID, count: Int) {
        withTerminal(id) { name in
            terminal.press(name, key: "C-a")
            for _ in 0..<count { terminal.press(name, key: "DC") }
        }
    }

    func wake(_ id: UUID) -> String? {
        guard let session = daemon.session(id) else { return "a sessão não existe mais" }
        return daemon.wake(session)
    }

    func thaw(_ id: UUID) {}

    func show(_ id: UUID, _ progress: RecycleProgress?) {
        daemon.session(id)?.recycle = progress
    }

    func tell(_ id: UUID, title: String, body: String, attention: Bool) {
        guard let session = daemon.session(id) else {
            daemon.log("\(title): \(body)")
            return
        }
        if attention { session.attention = true }
        _ = daemon.notifier.post(title: "\(title): \(session.label)", body: body)
        daemon.log("\(title): \(session.label): \(body)")
    }

    func pullRequest(root: String, branch: String) -> String? {
        guard let gh = daemon.helpers.gh else { return nil }
        return PullRequestLookup.find(gh: gh, root: root, branch: branch)
    }

    func log(_ text: String) { daemon.log(text) }

    // MARK: Lookups

    static let git = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    private func withTerminal(_ id: UUID, _ action: (String) -> Void) {
        guard let session = daemon.session(id) else { return }
        action(session.terminalName)
    }

    private func locate(_ conversation: String, session: ServerSession) -> String? {
        let root = URL(fileURLWithPath: daemon.server.configDirectory(account: session.record.account))
            .appendingPathComponent("projects", isDirectory: true)
        return TranscriptLocator.find(conversation: conversation, hint: session.transcriptPath, root: root)
    }
}
