import Foundation
import WorkspacesCore

/// The Workspaces app without a screen: Claude Code sessions in tmux, the same MCP tools, the
/// same hooks and the same recycle rule from WorkspacesCore. Not thread safe: everything runs on
/// one queue (the IPC server hops onto it), and tests call it directly.
public final class Daemon {
    public struct Paths {
        public var home: URL
        public var config: URL { home.appendingPathComponent("workspaces.json") }
        public var server: URL { home.appendingPathComponent("server.json") }
        public var sessions: URL { home.appendingPathComponent("server-sessions.json") }
        public var settings: URL { home.appendingPathComponent("claude-settings.json") }
        public var mcp: URL { home.appendingPathComponent("claude-mcp.json") }
        public var recycleLog: URL { home.appendingPathComponent("recycles.jsonl") }
        public var conversationLog: URL { home.appendingPathComponent("conversations.jsonl") }
        public var eventLog: URL { home.appendingPathComponent("workspacesd.log") }

        public init(home: URL) {
            self.home = home
        }
    }

    /// The executables the sessions call back: `workspacesd mcp` and `workspaces-hook`.
    public struct Helpers {
        public var daemon: String
        public var hook: String
        /// gh, for the open pull request in a recycle's handoff; nil leaves it out.
        public var gh: String?

        public init(daemon: String, hook: String, gh: String? = nil) {
            self.daemon = daemon
            self.hook = hook
            self.gh = gh
        }
    }

    public static let sleepTick: TimeInterval = 60
    /// After the reset the account needs a moment; then "continue" goes in.
    static let rateLimitGrace: TimeInterval = 60
    static let rateLimitFallback: TimeInterval = 30 * 60
    static let trustChecks = 10
    static let trustInterval: TimeInterval = 2

    let paths: Paths
    let helpers: Helpers
    let terminal: SessionTerminal
    let scheduler: Scheduler
    let notifier: Notifier
    /// The environment the sessions start with (PATH, HOME, LANG).
    let baseEnvironment: [String: String]
    private(set) var config: AppConfig
    private(set) var server: ServerConfig
    var sessions: [ServerSession] = []
    private(set) var recycler: ServerRecycler!
    private var readings: [String: LimitReadings] = [:]
    private var tickWork: ScheduledWork?

    public init(paths: Paths, helpers: Helpers, terminal: SessionTerminal, scheduler: Scheduler, notifier: Notifier,
                baseEnvironment: [String: String]) throws {
        self.paths = paths
        self.helpers = helpers
        self.terminal = terminal
        self.scheduler = scheduler
        self.notifier = notifier
        self.baseEnvironment = baseEnvironment
        let fm = FileManager.default
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        if fm.fileExists(atPath: paths.config.path) {
            config = try ConfigStore(url: paths.config).load()
        } else {
            // On the server close_session is for the despachante too, so nothing starts disabled.
            config = AppConfig(disabledTools: [])
            try ConfigStore(url: paths.config).save(config)
        }
        if let data = fm.contents(atPath: paths.server.path) {
            server = try JSONDecoder().decode(ServerConfig.self, from: data)
        } else {
            server = ServerConfig()
            try Self.write(server, to: paths.server)
        }
        if let data = fm.contents(atPath: paths.sessions.path) {
            let records = try JSONDecoder().decode([ServerSessionRecord].self, from: data)
            sessions = records.map { ServerSession(record: $0, now: scheduler.now) }
        }
        recycler = ServerRecycler(daemon: self, log: RecycleLog(url: paths.recycleLog))
    }

    /// Writes the files Claude Code is pointed at, adopts the sessions still running in tmux, marks
    /// the rest hibernated (they come back with --resume when opened or messaged) and finishes the
    /// recycles a restart interrupted.
    public func start() throws {
        try writeClaudeFiles()
        for session in sessions where !session.hibernated {
            if terminal.isRunning(session.terminalName) {
                session.status = .idle
            } else {
                session.record.hibernated = true
            }
        }
        saveSessions()
        recycler.recover()
        scheduleTick()
    }

    // MARK: Files

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    func writeClaudeFiles() throws {
        let hook = ClaudeLaunch.shellQuote(helpers.hook)
        var settings = ClaudeLaunch.settingsJSON(hookCommand: hook, statusLineCommand: hook + " statusline")
        // StopFailure tells when a turn ended on the account's limit, to continue after the reset.
        if case .object(var root) = settings, case .object(var hooks)? = root["hooks"], let entry = hooks["Stop"] {
            hooks["StopFailure"] = entry
            root["hooks"] = .object(hooks)
            settings = .object(root)
        }
        try settings.encodedLine().write(to: paths.settings, options: .atomic)
        try ClaudeLaunch.mcpConfigJSON(helperPath: helpers.daemon).encodedLine().write(to: paths.mcp, options: .atomic)
    }

    func saveSessions() {
        do {
            try Self.write(sessions.map(\.record), to: paths.sessions)
        } catch {
            log("não consegui gravar \(paths.sessions.path): \(error)")
        }
    }

    func saveConfig() {
        do {
            try ConfigStore(url: paths.config).save(config)
        } catch {
            log("não consegui gravar \(paths.config.path): \(error)")
        }
    }

    func log(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: scheduler.now)) \(text)\n"
        let url = paths.eventLog
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: Lookups

    func session(_ id: UUID?) -> ServerSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func project(of session: ServerSession) -> (workspace: Workspace, project: Project)? {
        for workspace in config.workspaces {
            if let project = workspace.projects.first(where: { $0.id == session.record.projectId }) { return (workspace, project) }
        }
        return nil
    }

    func folder(of session: ServerSession) -> String? {
        session.record.cwd ?? project(of: session)?.project.path
    }

    /// The project for a folder: the one at exactly that path, or a new one in the "Servidor" workspace.
    func projectFor(path: String) -> (workspace: Workspace, project: Project) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        for workspace in config.workspaces {
            if let project = workspace.projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }) {
                return (workspace, project)
            }
        }
        let project = Project(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        if let index = config.workspaces.firstIndex(where: { $0.name == "Servidor" }) {
            config.workspaces[index].projects.append(project)
        } else {
            config.workspaces.append(Workspace(name: "Servidor", projects: [project]))
        }
        saveConfig()
        return (config.workspaces.first { $0.projects.contains { $0.id == project.id } }!, project)
    }

    func isAwake(_ session: ServerSession) -> Bool {
        !session.hibernated && terminal.isRunning(session.terminalName)
    }

    // MARK: Starting and stopping

    /// Model names go to the command line: letters, digits and . - _ [ ] only.
    static func isValidModel(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 60 && name.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || ".-_[]".unicodeScalars.contains($0)
        }
    }

    func environment(for session: ServerSession) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "LANG", "LC_ALL", "USER", "SHELL", "TERM"] {
            if let value = baseEnvironment[key] { env[key] = value }
        }
        env["PATH"] = Self.searchPath(env["PATH"], home: baseEnvironment["HOME"] ?? NSHomeDirectory())
        env["CLAUDE_CONFIG_DIR"] = server.configDirectory(account: session.record.account)
        env[ClaudeLaunch.sessionEnvKey] = session.id.uuidString
        env[ClaudeLaunch.launchEnvKey] = String(session.record.launch)
        env["WORKSPACES_HOME"] = paths.home.path
        env[LimitReadingStore.accountEnvKey] = session.record.account
        return env
    }

    /// systemd and cron start with a short PATH; Claude Code lives in ~/.local/bin.
    static func searchPath(_ path: String?, home: String) -> String {
        var parts = (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":").map(String.init)
        let local = "\(home)/.local/bin"
        if !parts.contains(local) { parts.insert(local, at: 0) }
        return parts.joined(separator: ":")
    }

    /// Starts Claude in the session's terminal: a new conversation, or the saved one with --resume.
    func launch(_ session: ServerSession, prompt: String?) -> String? {
        guard let (_, project) = project(of: session) else { return "o projeto da sessão não existe mais" }
        let fm = FileManager.default
        let resumeId = session.conversation.resumable
        var folder = project.path
        var worktree = resumeId == nil ? session.record.worktree : nil
        if resumeId != nil, let cwd = session.record.cwd, fm.fileExists(atPath: cwd) { folder = cwd }
        // A worktree made by an earlier launch is reused, not created again.
        if let name = worktree {
            let standard = URL(fileURLWithPath: project.path).appendingPathComponent(".claude/worktrees/\(name)").path
            if let cwd = session.record.cwd, cwd != project.path, fm.fileExists(atPath: cwd) {
                folder = cwd
                worktree = nil
            } else if fm.fileExists(atPath: standard) {
                folder = standard
                worktree = nil
            }
        }
        var extra = project.claudeArguments
        if let model = session.record.model { extra += " --model " + ClaudeLaunch.shellQuote(model) }
        let options = ClaudeLaunch.Options(
            claudeCommand: config.claudeCommand, projectPath: folder, settingsFile: paths.settings.path,
            mcpConfigFile: paths.mcp.path, name: "\(project.name) \(session.label)", resumeId: resumeId,
            worktree: worktree, prompt: prompt, extraArguments: extra)
        session.record.launch += 1
        let env = environment(for: session)
        guard let argv = ClaudeLaunch.argv(options),
              let executable = ShellSupport.resolve(argv[0], path: env["PATH"]) else {
            return "não achei o comando \(config.claudeCommand) no PATH (\(env["PATH"] ?? ""))"
        }
        if terminal.isRunning(session.terminalName) { terminal.kill(session.terminalName) }
        do {
            try terminal.start(name: session.terminalName, folder: folder, environment: env,
                               argv: [executable] + argv.dropFirst())
        } catch {
            return "\(error)"
        }
        session.record.hibernated = false
        session.status = resumeId == nil ? .working : .idle
        session.lastChange = scheduler.now
        session.startedAt = scheduler.now
        saveSessions()
        watchFirstScreen(session, folder: folder, check: 1)
        log("abriu \(session.label) (\(session.shortId)) em \(folder), conta \(session.record.account)")
        return nil
    }

    /// Claude Code asks once per folder whether to trust it. Inside a trusted root the daemon says
    /// yes, as the person would; anywhere else the session waits and says why.
    private func watchFirstScreen(_ session: ServerSession, folder: String, check: Int) {
        let started = session.startedAt
        scheduler.after(Self.trustInterval) { [weak self, weak session] in
            guard let self, let session, session.startedAt == started, !session.hibernated else { return }
            let screen = self.terminal.capture(session.terminalName)
            if screen.contains("Yes, I trust this folder") {
                if self.server.trusts(folder) {
                    self.terminal.press(session.terminalName, key: "Down")
                    self.scheduler.after(0.3) { [weak self] in self?.terminal.pressEnter(session.terminalName) }
                    self.log("confiou na pasta \(folder) para \(session.label)")
                    return
                }
                session.status = .waiting
                session.message = "o Claude Code pergunta se confia em \(folder), fora das pastas de confiança do servidor"
                session.attention = true
                return
            }
            if PromptScreen.inputIsEmpty(ScreenParser.lines(screen)) != nil || check >= Self.trustChecks { return }
            self.watchFirstScreen(session, folder: folder, check: check + 1)
        }
    }

    func wake(_ session: ServerSession) -> String? {
        guard session.hibernated || !terminal.isRunning(session.terminalName) else { return nil }
        return launch(session, prompt: nil)
    }

    func hibernate(_ session: ServerSession) {
        session.record.hibernated = true
        saveSessions()
        terminal.kill(session.terminalName)
        log("hibernou \(session.label) (\(session.shortId))")
    }

    func close(_ session: ServerSession) {
        recycler.forget(session.id)
        terminal.kill(session.terminalName)
        sessions.removeAll { $0.id == session.id }
        saveSessions()
        log("fechou \(session.label) (\(session.shortId))")
    }

    /// Pastes text in the session's prompt and presses Enter; a hibernated one gets it once it is back.
    /// False when nothing runs there to receive it.
    func deliver(_ text: String, to session: ServerSession) -> Bool {
        if session.hibernated {
            session.pendingPaste = text
            if let failure = wake(session) {
                log("não acordou \(session.label): \(failure)")
                session.pendingPaste = nil
                return false
            }
            return true
        }
        guard terminal.isRunning(session.terminalName) else { return false }
        submit(text, to: session)
        return true
    }

    /// Bracketed paste, then Enter a moment later (the paste must land before the key).
    func submit(_ text: String, to session: ServerSession, after delay: TimeInterval = 0) {
        let name = session.terminalName
        scheduler.after(delay) { [weak self] in
            guard let self else { return }
            self.terminal.paste(name, text)
            self.scheduler.after(0.5) { [weak self] in self?.terminal.pressEnter(name) }
        }
    }

    // MARK: Requests from the helpers

    public func handle(_ request: IPCRequest) -> IPCResponse {
        let caller = request.session.flatMap(UUID.init(uuidString:)).flatMap { session($0) }
        switch request.kind {
        case .hook:
            var output = ""
            if let caller, let payload = request.payload,
               request.launch.flatMap(Int.init) ?? caller.record.launch == caller.record.launch {
                output = applyHook(payload, to: caller) ?? ""
            }
            return IPCResponse(ok: true, text: output)
        case .tools:
            return IPCResponse(ok: true, text: "", enabledTools: enabledTools)
        case .statusLine:
            if let caller, let payload = request.payload {
                receive(StatusLineReading.parse(payload, now: scheduler.now), from: caller)
            }
            return IPCResponse(ok: true, text: "")
        case .tool:
            let name = request.tool ?? ""
            // A session asks through MCP; a script (no session) may use every tool.
            if caller != nil, config.disabledTools.contains(name) {
                return IPCResponse(ok: false, text: "A ferramenta \(name) está desligada no workspaces.json do servidor.")
            }
            let result = runTool(name, request.arguments ?? .object([:]), caller: caller)
            return IPCResponse(ok: !result.isError, text: result.text)
        }
    }

    var enabledTools: [String] {
        ServerTools.all.map(\.name).filter { !config.disabledTools.contains($0) }
    }

    func applyHook(_ payload: JSONValue, to session: ServerSession) -> String? {
        guard let update = HookEvent.update(from: payload) else { return nil }
        let now = scheduler.now
        if let path = update.transcriptPath { session.transcriptPath = path }
        if update.status == .idle, let text = session.pendingPaste {
            session.pendingPaste = nil
            // SessionStart comes a moment before the prompt accepts input.
            submit(text, to: session, after: 1.5)
        }
        // Hibernating ends Claude on purpose: its SessionEnd must not mark the session as over.
        if let status = update.status, !session.hibernated {
            session.status = status
            session.lastChange = now
            session.message = status == .waiting ? update.message : nil
        }
        if update.event == "StopFailure" {
            // The turn ended on an API error: it is not working any more.
            session.status = .done
            session.lastChange = now
            stopFailure(payload, session: session)
        }
        if update.event == "UserPromptSubmit" {
            // A new turn: whatever asked for attention was answered, and the limit is behind.
            session.rateLimitedUntil = nil
            session.attention = false
        }
        if update.clearsActivity { session.activity = nil }
        let saved = session.record
        let resumable = session.conversation.resumable
        let current = session.conversation.current
        if session.conversation.apply(update) {
            ConversationLog.append(session: session.id, label: session.label, update: update, from: resumable,
                                   to: session.conversation.resumable, url: paths.conversationLog)
        }
        // A new conversation (after /clear) starts with its own context.
        if session.conversation.current != current { session.contextTokens = nil }
        if let cwd = update.cwd { session.record.cwd = cwd }
        session.record.claudeSessionId = session.conversation.resumable
        if session.record != saved { saveSessions() }

        var output: String?
        switch update.event {
        case "SessionStart" where update.source == "clear":
            output = recycler.sessionStartContext(for: session)
        case "PostToolUse", "UserPromptSubmit":
            output = handoffReminder(session, event: update.event)
        default:
            break
        }
        recycler.hook(update, session: session)
        return output
    }

    private func handoffReminder(_ session: ServerSession, event: String) -> String? {
        guard let conversation = session.claudeSessionId, !recycler.isBusy(session) else { return nil }
        var last = session.handoffReminder?.conversation == conversation ? session.handoffReminder?.tokens : nil
        let text = config.contextLimits.reminder(tokens: session.contextTokens, lastWarned: &last)
        session.handoffReminder = (conversation, last)
        return text.map { HookOutput.additionalContext(event: event, $0) }
    }

    func receive(_ reading: StatusLineReading, from session: ServerSession) {
        if let tokens = reading.contextTokens, tokens > 0 {
            session.contextTokens = tokens
            session.contextSize = reading.contextSize
        }
        if reading.fiveHour != nil || reading.sevenDay != nil { record(reading, account: session.record.account) }
        recycler.statusLine(reading, session: session)
    }

    // MARK: The account's limit

    func limitReadings(_ account: String) -> LimitReadings {
        if let cached = readings[account] { return cached }
        let loaded = LimitReadingStore(account: account, directory: paths.home).load()
        readings[account] = loaded
        return loaded
    }

    private func record(_ reading: StatusLineReading, account: String) {
        var saved = limitReadings(account)
        let before = saved
        if let r = reading.fiveHour { LimitReadings.record(r, in: &saved.fiveHour, now: scheduler.now) }
        if let r = reading.sevenDay { LimitReadings.record(r, in: &saved.sevenDay, now: scheduler.now) }
        readings[account] = saved
        // Only a new value is written; the same value seen again just moves its time.
        let changed = saved.fiveHour.count != before.fiveHour.count || saved.sevenDay.count != before.sevenDay.count
            || saved.fiveHour.last?.percent != before.fiveHour.last?.percent
            || saved.sevenDay.last?.percent != before.sevenDay.last?.percent
        if changed {
            do {
                try LimitReadingStore(account: account, directory: paths.home).save(saved)
            } catch {
                log("não consegui gravar as leituras de \(account): \(error)")
            }
        }
    }

    /// A turn that ended on the account's limit continues by itself when the limit resets.
    private func stopFailure(_ payload: JSONValue, session: ServerSession) {
        // The hooks reference names the field error_type; accept error too, in case a version sends that.
        guard (payload["error_type"] ?? payload["error"])?.stringValue == "rate_limit" else { return }
        let now = scheduler.now
        var until: Date
        if let seconds = payload["retry_after"]?.numberValue, seconds > 0 {
            until = now.addingTimeInterval(seconds)
        } else {
            // The reset of the meter that is full, from the account's readings.
            let saved = limitReadings(session.record.account)
            let full = [saved.fiveHour.last, saved.sevenDay.last].compactMap { $0 }
                .filter { $0.percent >= 100 && $0.resetsAt > now }.map(\.resetsAt)
            until = full.max() ?? now.addingTimeInterval(Self.rateLimitFallback)
        }
        until = until.addingTimeInterval(Self.rateLimitGrace)
        session.rateLimitedUntil = until
        log("\(session.label) bateu no limite da \(session.record.account); continua às \(until)")
        scheduler.after(until.timeIntervalSince(now)) { [weak self, weak session] in
            guard let self, let session, session.rateLimitedUntil == until else { return }
            self.continueAfterLimit(session)
        }
    }

    func continueAfterLimit(_ session: ServerSession) {
        session.rateLimitedUntil = nil
        guard self.session(session.id) != nil, session.status == .done || session.status == .idle else { return }
        if session.hibernated {
            _ = deliver("continue", to: session)
            return
        }
        // Only into an empty prompt: a draft there belongs to someone.
        guard PromptScreen.inputIsEmpty(ScreenParser.lines(terminal.capture(session.terminalName))) == true else {
            log("\(session.label): o limite reabriu, mas a caixa de entrada não está vazia; não mandei o continue")
            return
        }
        submit("continue", to: session)
        log("\(session.label): limite reaberto, mandei continue")
    }

    // MARK: Sleep

    private func scheduleTick() {
        tickWork = scheduler.after(Self.sleepTick) { [weak self] in
            self?.tick()
            self?.scheduleTick()
        }
    }

    /// Hibernates quiet sessions, as the app does with the ones nobody looks at. Nothing is frozen:
    /// a stopped process in tmux saves CPU only, and the server has CPU to spare.
    func tick() {
        let policy = SleepPolicy(freezeAfterMinutes: 0, hibernateAfterMinutes: config.hibernateAfterMinutes)
        let now = scheduler.now
        for session in sessions where !session.hibernated {
            guard terminal.isRunning(session.terminalName) else {
                if session.status != .ended {
                    session.status = .ended
                    session.lastChange = now
                }
                continue
            }
            guard !recycler.isBusy(session), session.rateLimitedUntil == nil, session.pendingPaste == nil else { continue }
            let facts = SleepPolicy.Session(
                status: session.status, attention: session.attention, visible: false,
                quietFor: now.timeIntervalSince(session.lastChange), state: .awake,
                hasConversation: session.hasConversation,
                runningCommand: terminal.pid(session.terminalName).map(ProcessTree.runsShell(under:)) ?? false)
            if policy.action(for: facts) == .hibernate { hibernate(session) }
        }
    }
}
