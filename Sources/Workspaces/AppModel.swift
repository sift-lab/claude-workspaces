import AppKit
import Observation
import SwiftUI
import WorkspacesCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var config: AppConfig {
        didSet { if config != oldValue { saveConfig() } }
    }
    private(set) var sessions: [SessionRuntime] = []
    /// Refreshed every 30 s: relative times only show minutes, so nothing redraws every second.
    private(set) var now = Date()
    private(set) var serverError: String?
    /// Set when the config file could not be read; saving is then disabled so it is never overwritten.
    private(set) var configError: String?
    /// A window for this workspace should select this session.
    var focusRequest: (workspace: UUID, session: UUID)?
    /// Asks open windows to switch between one session and the grid (used by the screenshot mode).
    var requestedMode: DetailMode?

    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored var openSettings: OpenSettingsAction?
    @ObservationIgnored private var server: IPCServer?
    @ObservationIgnored private var mcpServer: MCPHTTPServer?
    @ObservationIgnored private let mcpToken = UUID().uuidString + UUID().uuidString
    /// Nil until the login shell's environment is known (read once at launch).
    @ObservationIgnored private var loginEnvironment: [String: String]?
    @ObservationIgnored private var mcpSettled = false
    @ObservationIgnored private var pendingStarts: [() -> Void] = []
    /// Text for a hibernated session, typed once it is back at its prompt.
    @ObservationIgnored private var pendingPaste: [UUID: String] = [:]
    /// Session each open window shows in "Uma" mode; those never sleep.
    @ObservationIgnored private var visibleByWindow: [UUID: UUID] = [:]
    @ObservationIgnored private var gridViewers = 0
    @ObservationIgnored private var slowTimer: Timer?
    @ObservationIgnored private let keepAwake = KeepAwake()
    @ObservationIgnored private var usageTimer: Timer?
    @ObservationIgnored private let usageMonitor = UsageMonitor()
    @ObservationIgnored private var usageViewers = 0
    /// The app process itself, for the total on the usage screen.
    private(set) var appUsage: Usage = .zero
    /// Tokens the sessions spend and the account's limit.
    let tokens = TokenMonitor()
    @ObservationIgnored private var snapshotTimer: Timer?
    @ObservationIgnored private let store = ConfigStore()
    @ObservationIgnored private let helperPath: String
    @ObservationIgnored private var startedWorkspaces: Set<UUID> = []

    private init() {
        helperPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        do {
            config = try store.load()
        } catch {
            config = AppConfig()
            configError = "Não consegui ler \(store.url.path): \(error.localizedDescription)"
        }
        do {
            try AppPaths.ensureSupportDirectory()
            try writeClaudeFiles()
            let server = IPCServer(path: AppPaths.socketFile.path) { [weak self] request in
                self?.handle(request) ?? IPCResponse(ok: false, text: "app encerrando")
            }
            try server.start()
            self.server = server
        } catch {
            serverError = "\(error)"
        }
        let mcp = MCPHTTPServer(token: mcpToken) { [weak self] session, message in
            self?.handleMCP(session: session, message: message)
        }
        mcpServer = mcp
        mcp.start { [weak self] ok in
            if !ok { self?.mcpServer = nil }
            self?.mcpSettled = true
            self?.runPendingStarts()
        }
        LoginEnvironment.capture { [weak self] env in
            self?.loginEnvironment = env
            self?.runPendingStarts()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowTick() }
        }
        slowTimer?.tolerance = 5
        Notifier.shared.setUp { [weak self] sessionId in self?.focus(sessionId: sessionId) }
        tokens.start(model: self)
        Orphans.reap(settingsPath: AppPaths.claudeSettingsFile.path)
        ScreenshotMode.start(model: self)
        TokenShots.start(model: self)
    }

    func shutdown() {
        flushSave()
        for session in sessions { session.host.terminate() }
        server?.stop()
        mcpServer?.stop()
    }

    private func runPendingStarts() {
        guard loginEnvironment != nil, mcpSettled else { return }
        let starts = pendingStarts
        pendingStarts = []
        for start in starts { start() }
    }

    // MARK: Lookup

    func workspace(_ id: UUID) -> Workspace? { config.workspaces.first { $0.id == id } }

    func project(_ id: UUID) -> (workspace: Workspace, project: Project)? {
        for workspace in config.workspaces {
            if let project = workspace.projects.first(where: { $0.id == id }) { return (workspace, project) }
        }
        return nil
    }

    func session(_ id: UUID?) -> SessionRuntime? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func sessions(inProject id: UUID) -> [SessionRuntime] { sessions.filter { $0.projectId == id } }

    /// The label, numbered when several sessions of a project share it ("main (2)").
    func displayLabel(_ session: SessionRuntime) -> String {
        let same = sessions(inProject: session.projectId).filter { $0.label == session.label }
        guard same.count > 1, let index = same.firstIndex(where: { $0.id == session.id }), index > 0 else { return session.label }
        return "\(session.label) (\(index + 1))"
    }
    func sessions(inWorkspace id: UUID) -> [SessionRuntime] { sessions.filter { $0.workspaceId == id } }
    var sessionsNeedingYou: [SessionRuntime] { sessions.filter(\.needsYou).sorted { $0.lastChange > $1.lastChange } }

    /// `--open <name>` on the command line picks the first window's workspace.
    @ObservationIgnored private var pendingOpen: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    func takePendingOpen() -> UUID? {
        guard let name = pendingOpen?.lowercased() else { return nil }
        pendingOpen = nil
        return config.workspaces.first { $0.name.lowercased() == name }?.id
    }

    // MARK: Workspaces and projects

    func addWorkspace(named name: String) -> Workspace {
        let workspace = Workspace(name: name)
        config.workspaces.append(workspace)
        return workspace
    }

    func removeWorkspace(_ id: UUID) {
        for session in sessions(inWorkspace: id) { closeSession(session.id) }
        config.workspaces.removeAll { $0.id == id }
        startedWorkspaces.remove(id)
    }

    func updateWorkspace(_ id: UUID, _ change: (inout Workspace) -> Void) {
        guard let index = config.workspaces.firstIndex(where: { $0.id == id }) else { return }
        change(&config.workspaces[index])
    }

    func updateProject(_ id: UUID, _ change: (inout Project) -> Void) {
        for w in config.workspaces.indices {
            if let p = config.workspaces[w].projects.firstIndex(where: { $0.id == id }) {
                change(&config.workspaces[w].projects[p])
                return
            }
        }
    }

    func addProject(path: String, to workspaceId: UUID) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        updateWorkspace(workspaceId) { $0.projects.append(Project(name: name, path: path)) }
    }

    func removeProject(_ id: UUID) {
        for session in sessions(inProject: id) { closeSession(session.id) }
        for w in config.workspaces.indices { config.workspaces[w].projects.removeAll { $0.id == id } }
    }

    /// Called when a workspace window appears: resumes saved sessions or opens the configured count.
    func startWorkspace(_ id: UUID) {
        guard !startedWorkspaces.contains(id), let workspace = workspace(id) else { return }
        startedWorkspaces.insert(id)
        for project in workspace.projects where sessions(inProject: project.id).isEmpty {
            if config.reopenSessions, !project.savedSessions.isEmpty {
                for saved in project.savedSessions { launch(saved: saved, project: project, workspaceId: id) }
            } else {
                for _ in 0..<max(0, project.sessionsOnOpen) { _ = newSession(projectId: project.id) }
            }
        }
    }

    // MARK: Sessions

    @discardableResult
    func newSession(projectId: UUID, worktree: String? = nil, prompt: String? = nil) -> SessionRuntime? {
        guard let (workspace, project) = project(projectId) else { return nil }
        let id = UUID()
        var worktreeName = worktree
        if worktreeName == nil, project.newSessionMode == .worktree {
            worktreeName = "ws-" + String(id.uuidString.lowercased().prefix(6))
        }
        let label = worktreeName ?? Git.branch(at: project.path) ?? project.name
        let saved = SavedSession(id: id, label: label, worktree: worktreeName)
        updateProject(projectId) { $0.savedSessions.append(saved) }
        return launch(saved: saved, project: project, workspaceId: workspace.id, prompt: prompt)
    }

    /// A plain login shell in the project, or in `folder` (a session's worktree), listed with the sessions.
    @discardableResult
    func newTerminal(projectId: UUID, folder: String? = nil) -> SessionRuntime? {
        guard let (workspace, project) = project(projectId) else { return nil }
        let folder = folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? project.path
        let place = Git.branch(at: folder) ?? URL(fileURLWithPath: folder).lastPathComponent
        let saved = SavedSession(id: UUID(), label: "Terminal · \(place)", cwd: folder, terminal: true)
        updateProject(projectId) { $0.savedSessions.append(saved) }
        return launch(saved: saved, project: project, workspaceId: workspace.id)
    }

    @discardableResult
    private func launch(saved: SavedSession, project: Project, workspaceId: UUID, prompt: String? = nil) -> SessionRuntime {
        let runtime = SessionRuntime(id: saved.id, workspaceId: workspaceId, projectId: project.id,
                                     label: saved.label, worktree: saved.worktree, isTerminal: saved.terminal)
        runtime.claudeSessionId = saved.claudeSessionId
        runtime.hasConversation = saved.claudeSessionId != nil
        runtime.cwd = saved.cwd
        sessions.append(runtime)
        start(runtime, project: project, prompt: prompt)
        return runtime
    }

    private func start(_ runtime: SessionRuntime, project: Project, prompt: String?) {
        guard let loginEnvironment, mcpSettled else {
            runtime.status = .working
            pendingStarts.append { [weak self, weak runtime] in
                guard let self, let runtime, self.session(runtime.id) != nil else { return }
                self.start(runtime, project: project, prompt: prompt)
            }
            return
        }
        if runtime.isTerminal {
            let folder = runtime.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? project.path
            startShell(runtime, in: folder, environment: loginEnvironment)
            return
        }
        let resuming = runtime.hasConversation && runtime.claudeSessionId != nil
        var folder = project.path
        var worktree = resuming ? nil : runtime.worktree
        if resuming, let cwd = runtime.cwd, FileManager.default.fileExists(atPath: cwd) { folder = cwd }
        // A worktree made by an earlier launch is reused, not created again.
        if let name = worktree, let existing = existingWorktree(named: name, runtime: runtime, project: project) {
            folder = existing
            worktree = nil
        }
        let options = ClaudeLaunch.Options(
            claudeCommand: config.claudeCommand,
            projectPath: folder,
            settingsFile: AppPaths.claudeSettingsFile.path,
            mcpConfigFile: mcpConfigFile(for: runtime.id),
            name: "\(project.name) \(runtime.label)",
            resumeId: resuming ? runtime.claudeSessionId : nil,
            worktree: worktree,
            prompt: prompt,
            extraArguments: project.claudeArguments
        )
        runtime.status = resuming ? .idle : .working
        runtime.sleep = .awake
        runtime.shellOnly = false
        runtime.lastChange = Date()
        runtime.lastSeen = Date()
        runtime.launch += 1
        runtime.host.onTerminated = { [weak self, weak runtime] in
            guard let runtime else { return }
            // Hibernating ends the process on purpose; the session is not over.
            guard runtime.sleep != .hibernated else { return }
            runtime.status = .ended
            runtime.lastChange = Date()
            self?.updateBadge()
        }
        var env = loginEnvironment
        env[ClaudeLaunch.sessionEnvKey] = runtime.id.uuidString
        env[ClaudeLaunch.launchEnvKey] = String(runtime.launch)
        if let home = ProcessInfo.processInfo.environment["WORKSPACES_HOME"] { env["WORKSPACES_HOME"] = home }
        // Straight to Claude when the command is plain words; the login shell only when it is not.
        if let argv = ClaudeLaunch.argv(options), let executable = ShellSupport.resolve(argv[0], path: env["PATH"]) {
            runtime.host.start(executable: executable, arguments: Array(argv.dropFirst()), environment: env, directory: folder)
        } else {
            runtime.host.start(script: ClaudeLaunch.shellScript(options), environment: env)
        }
    }

    private func existingWorktree(named name: String, runtime: SessionRuntime, project: Project) -> String? {
        let fm = FileManager.default
        if let cwd = runtime.cwd, cwd != project.path, fm.fileExists(atPath: cwd) { return cwd }
        let standard = URL(fileURLWithPath: project.path).appendingPathComponent(".claude/worktrees/\(name)").path
        return fm.fileExists(atPath: standard) ? standard : nil
    }

    /// Per-session file so the MCP request carries the session id; falls back to the stdio helper.
    private func mcpConfigFile(for id: UUID) -> String {
        guard let url = mcpServer?.url else { return AppPaths.mcpConfigFile.path }
        let dir = AppPaths.supportDirectory.appendingPathComponent("sessions", isDirectory: true)
        let file = dir.appendingPathComponent("\(id.uuidString).json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = ClaudeLaunch.mcpHTTPConfigJSON(url: url, session: id.uuidString, token: mcpToken)
            try json.encodedLine().write(to: file, options: .atomic)
            chmod(file.path, 0o600)
            return file.path
        } catch {
            return AppPaths.mcpConfigFile.path
        }
    }

    /// After Claude exits: a login shell in the same place, like a Terminal tab would leave.
    func openShell(_ id: UUID) {
        guard let runtime = session(id), !runtime.host.isRunning, let loginEnvironment,
              let (_, project) = project(runtime.projectId) else { return }
        let folder = runtime.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? project.path
        startShell(runtime, in: folder, environment: loginEnvironment)
    }

    private func startShell(_ runtime: SessionRuntime, in folder: String, environment: [String: String]) {
        runtime.shellOnly = true
        runtime.sleep = .awake
        runtime.status = .idle
        runtime.lastChange = Date()
        runtime.lastSeen = Date()
        if runtime.isTerminal {
            runtime.host.onTerminated = { [weak self, weak runtime] in
                guard let runtime else { return }
                runtime.status = .ended
                runtime.lastChange = Date()
                self?.updateBadge()
            }
        }
        runtime.host.start(executable: environment["SHELL"] ?? "/bin/zsh", arguments: ["-l"],
                           environment: environment, directory: folder)
    }

    // MARK: Sleep

    /// Windows report the session they show; showing a session wakes it.
    func setVisible(window: UUID, session id: UUID?) {
        // Only windows showing a session count; a grid or a closed window is removed.
        if let previous = visibleByWindow[window], previous != id { session(previous)?.lastSeen = Date() }
        visibleByWindow[window] = id
        if let id { wake(id) }
        updateUsageSampling()
    }

    // MARK: Usage

    func usageAppeared() {
        usageViewers += 1
        updateUsageSampling()
    }

    func usageDisappeared() {
        usageViewers = max(0, usageViewers - 1)
        updateUsageSampling()
    }

    /// Samples every 3 s, only while someone can see a number: an open session or the usage screen.
    private func updateUsageSampling() {
        let wanted = usageViewers > 0 || !visibleByWindow.isEmpty
        if wanted, usageTimer == nil {
            sampleUsage()
            usageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleUsage() }
            }
            usageTimer?.tolerance = 1
        } else if !wanted {
            usageTimer?.invalidate()
            usageTimer = nil
        }
    }

    private func sampleUsage() {
        // The usage screen needs everyone; otherwise only the sessions on screen.
        let targets = usageViewers > 0 ? sessions : sessions.filter { Set(visibleByWindow.values).contains($0.id) }
        for runtime in targets {
            let value = runtime.host.pid.map(usageMonitor.usage(ofTree:)) ?? .zero
            if value != runtime.usage { runtime.usage = value }
        }
        if usageViewers > 0 { appUsage = usageMonitor.usageOfThisApp() }
    }

    /// Manual rest from the usage screen or the session menu. Never for a session open in a window.
    func sleepNow(_ id: UUID) {
        guard let runtime = session(id), runtime.host.isRunning, !runtime.shellOnly,
              !Set(visibleByWindow.values).contains(id) else { return }
        if runtime.hasConversation, runtime.claudeSessionId != nil { hibernate(runtime) }
        else if runtime.host.freeze() { runtime.sleep = .frozen }
    }

    /// Measured now, for callers outside the sampling cycle (list_sessions).
    func currentUsage(_ runtime: SessionRuntime) -> Usage {
        runtime.host.pid.map(usageMonitor.usage(ofTree:)) ?? .zero
    }

    /// Screenshot mode only: sessions read from the transcripts become rows, never started.
    /// Returns the first one added.
    func addPreviewSessions(_ summaries: [SessionSummary]) -> SessionRuntime? {
        var first: SessionRuntime?
        var seen = Set(sessions.compactMap(\.claudeSessionId))
        for summary in summaries where !seen.contains(summary.id) {
            guard let cwd = summary.cwd, let (workspace, project) = config.project(containing: cwd) else { continue }
            seen.insert(summary.id)
            let runtime = SessionRuntime(id: UUID(), workspaceId: workspace.id, projectId: project.id,
                                         label: summary.branch ?? project.name, worktree: nil)
            runtime.claudeSessionId = summary.id
            runtime.hasConversation = true
            runtime.status = .idle
            sessions.append(runtime)
            if first == nil { first = runtime }
        }
        return first
    }

    // MARK: Front window actions (⌘T, ⇧⌘T)

    /// Weak, so a closed window is released and its entry dropped.
    private struct WindowEntry {
        weak var window: NSWindow?
        let actions: WorkspaceActions
    }

    @ObservationIgnored private var windowActions: [ObjectIdentifier: WindowEntry] = [:]

    func register(_ actions: WorkspaceActions, for window: NSWindow) {
        windowActions = windowActions.filter { $0.value.window != nil }
        windowActions[ObjectIdentifier(window)] = WindowEntry(window: window, actions: actions)
    }

    /// The workspace window in front, or the last one used when another window (Consumo) is in front.
    var frontWindowActions: WorkspaceActions? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let window = candidate, let entry = windowActions[ObjectIdentifier(window)], entry.window === window { return entry.actions }
        }
        return NSApp.orderedWindows.lazy.compactMap { self.windowActions[ObjectIdentifier($0)]?.actions }.first
    }

    func isOnScreen(_ id: UUID) -> Bool { Set(visibleByWindow.values).contains(id) }

    private func hibernate(_ runtime: SessionRuntime) {
        if let pid = runtime.host.pid { runtime.freedByHibernation = usageMonitor.usage(ofTree: pid).memory }
        runtime.snapshot = runtime.host.snapshot(lines: 6)
        runtime.sleep = .hibernated
        runtime.usage = .zero
        runtime.host.terminate()
        runtime.host.releaseHistory()
        runtime.host.show("\r\n\u{1b}[2m(hibernando: a conversa volta ao abrir esta sessão)\u{1b}[0m")
    }

    func gridAppeared() {
        gridViewers += 1
        refreshSnapshots()
        guard snapshotTimer == nil else { return }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSnapshots() }
        }
    }

    func gridDisappeared() {
        gridViewers = max(0, gridViewers - 1)
        if gridViewers == 0 {
            snapshotTimer?.invalidate()
            snapshotTimer = nil
        }
    }

    private func refreshSnapshots() {
        for session in sessions where session.sleep == .awake {
            let lines = session.host.snapshot(lines: 6)
            if lines != session.snapshot { session.snapshot = lines }
        }
    }

    func wake(_ id: UUID) {
        guard let runtime = session(id) else { return }
        runtime.lastSeen = Date()
        switch runtime.sleep {
        case .awake: return
        case .frozen:
            runtime.host.thaw()
            runtime.sleep = .awake
        case .hibernated:
            guard let (_, project) = project(runtime.projectId) else { return }
            runtime.freedByHibernation = 0
            runtime.host.restoreHistory()
            runtime.host.show("\u{1b}[2J\u{1b}[H\u{1b}[2mRetomando a conversa...\u{1b}[0m\r\n")
            start(runtime, project: project, prompt: nil)
        }
    }

    private var sleepPolicy: SleepPolicy {
        SleepPolicy(freezeAfterMinutes: config.freezeAfterMinutes, hibernateAfterMinutes: config.hibernateAfterMinutes)
    }

    private func applySleepPolicy() {
        let visible = Set(visibleByWindow.values)
        let policy = sleepPolicy
        for runtime in sessions where !runtime.shellOnly && runtime.host.isRunning {
            let facts = SleepPolicy.Session(
                status: runtime.status, attention: runtime.attention, visible: visible.contains(runtime.id),
                quietFor: now.timeIntervalSince(max(runtime.lastChange, runtime.lastSeen)), state: runtime.sleep,
                hasConversation: runtime.hasConversation,
                runningCommand: runtime.host.pid.map(ProcessTree.runsShell(under:)) ?? false)
            switch policy.action(for: facts) {
            case .none: break
            case .freeze:
                if runtime.host.freeze() { runtime.sleep = .frozen }
            case .hibernate:
                hibernate(runtime)
            }
        }
    }

    /// Starts an ended session again in the same place, resuming the conversation when known.
    func restart(_ id: UUID) {
        guard let runtime = session(id), !runtime.host.isRunning, let (_, project) = project(runtime.projectId) else { return }
        start(runtime, project: project, prompt: nil)
    }

    func closeSession(_ id: UUID) {
        guard let runtime = session(id) else { return }
        runtime.sleep = .awake
        runtime.host.terminate()
        pendingPaste[id] = nil
        try? FileManager.default.removeItem(at: AppPaths.supportDirectory.appendingPathComponent("sessions/\(id.uuidString).json"))
        sessions.removeAll { $0.id == id }
        updateProject(runtime.projectId) { $0.savedSessions.removeAll { $0.id == id } }
        updateBadge()
    }

    func markSeen(_ id: UUID) {
        guard let runtime = session(id), runtime.attention else { return }
        runtime.attention = false
        updateBadge()
    }

    func focus(sessionId: UUID) {
        guard let runtime = session(sessionId) else { return }
        focusRequest = (runtime.workspaceId, sessionId)
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "workspace", value: runtime.workspaceId)
    }

    func openWorkspaceWindow(_ id: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "workspace", value: id)
    }

    private func persist(_ runtime: SessionRuntime) {
        updateProject(runtime.projectId) { project in
            guard let i = project.savedSessions.firstIndex(where: { $0.id == runtime.id }) else { return }
            project.savedSessions[i].label = runtime.label
            if runtime.hasConversation { project.savedSessions[i].claudeSessionId = runtime.claudeSessionId }
            project.savedSessions[i].cwd = runtime.cwd
        }
    }

    // MARK: Helpers' requests

    private func handle(_ request: IPCRequest) -> IPCResponse {
        let caller = request.session.flatMap(UUID.init(uuidString:)).flatMap { session($0) }
        switch request.kind {
        case .hook:
            // A hook from a process that was already replaced (a hibernated one exiting late) is dropped.
            if let caller, let payload = request.payload, request.launch.flatMap(Int.init) ?? caller.launch == caller.launch {
                applyHook(payload, to: caller)
            }
            return IPCResponse(ok: true, text: "")
        case .tools:
            let enabled = WorkspaceTools.all.map(\.name).filter { !config.disabledTools.contains($0) }
            return IPCResponse(ok: true, text: "", enabledTools: enabled)
        case .statusLine:
            if let caller, let payload = request.payload {
                let reading = StatusLineReading.parse(payload)
                #if DEBUG
                NSLog("status line from %@: context %@, five hour %@", caller.label, String(describing: reading.contextTokens),
                      String(describing: reading.fiveHour?.percent))
                #endif
                tokens.receive(reading, from: caller)
            }
            return IPCResponse(ok: true, text: "")
        case .tool:
            let name = request.tool ?? ""
            if config.disabledTools.contains(name) {
                return IPCResponse(ok: false, text: "A ferramenta \(name) está desligada nos ajustes do Workspaces.")
            }
            let result = ToolRunner(model: self, caller: caller).run(name, request.arguments ?? .object([:]))
            return IPCResponse(ok: !result.isError, text: result.text)
        }
    }

    private func handleMCP(session: String?, message: JSONValue) -> JSONValue? {
        let caller = session.flatMap(UUID.init(uuidString:)).flatMap { self.session($0) }
        let server = MCPServer(
            enabledTools: { [config] in WorkspaceTools.all.map(\.name).filter { !config.disabledTools.contains($0) } },
            callTool: { [weak self] name, arguments in
                guard let self else { return ToolResult(text: "app encerrando", isError: true) }
                if self.config.disabledTools.contains(name) {
                    return ToolResult(text: "A ferramenta \(name) está desligada nos ajustes do Workspaces.", isError: true)
                }
                return ToolRunner(model: self, caller: caller).run(name, arguments)
            })
        return server.handle(message)
    }

    /// Types text into a session's prompt, waking it first; a hibernated one gets it once it is back.
    /// Returns false when nothing runs there to receive it.
    @discardableResult
    func deliver(_ text: String, to runtime: SessionRuntime) -> Bool {
        guard runtime.host.isRunning || runtime.sleep == .hibernated else { return false }
        switch runtime.sleep {
        case .awake:
            runtime.host.paste(text)
        case .frozen:
            wake(runtime.id)
            runtime.host.paste(text)
        case .hibernated:
            pendingPaste[runtime.id] = text
            wake(runtime.id)
        }
        return true
    }

    private func applyHook(_ payload: JSONValue, to runtime: SessionRuntime) {
        guard let update = HookEvent.update(from: payload) else { return }
        if update.status == .idle, let text = pendingPaste.removeValue(forKey: runtime.id) {
            // SessionStart comes a moment before the prompt accepts input.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak runtime] in runtime?.host.paste(text) }
        }
        let before = runtime.status
        // Hibernating ends Claude on purpose: its SessionEnd must not mark the session as over.
        if let status = update.status, runtime.sleep != .hibernated {
            runtime.status = status
            runtime.lastChange = Date()
            runtime.message = status == .waiting ? update.message : nil
        }
        if update.clearsActivity { runtime.activity = nil }
        if let id = update.claudeSessionId { runtime.claudeSessionId = id }
        if update.startsConversation { runtime.hasConversation = true }
        if let cwd = update.cwd, !samePath(cwd, runtime.cwd) {
            // The name follows the branch only when it was a branch name; a name the person
            // gave ("automação na QA") stays.
            let previous = runtime.cwd ?? project(runtime.projectId)?.project.path
            let wasBranch = previous.flatMap(Git.branch(at:)) == runtime.label || runtime.label == runtime.worktree
            runtime.cwd = cwd
            if wasBranch, let branch = Git.branch(at: cwd) { runtime.label = branch }
        }
        persist(runtime)
        if runtime.status == .waiting, before != .waiting { announceWaiting(runtime) }
        updateBadge()
        if runtime.status != before { updateKeepAwake() }
    }

    func announceWaiting(_ runtime: SessionRuntime, text: String? = nil) {
        guard config.notifyWhenWaiting, !NSApp.isActive || text != nil else { return }
        let projectName = project(runtime.projectId)?.project.name ?? ""
        Notifier.shared.post(title: "\(runtime.label) está esperando você",
                             body: text ?? [projectName, runtime.message].compactMap { $0 }.joined(separator: ": "),
                             sessionId: runtime.id)
    }

    func updateBadge() {
        let count = sessionsNeedingYou.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func slowTick() {
        now = Date()
        applySleepPolicy()
        updateKeepAwake()
    }

    private func updateKeepAwake() {
        let working = sessions.filter { !$0.isTerminal && $0.host.isRunning && $0.sleep == .awake && $0.status == .working }
        let facts = working.map { runtime in
            KeepAwakePolicy.Session(status: runtime.status, quietFor: Date().timeIntervalSince(runtime.lastChange),
                                    runningCommand: runtime.host.pid.map(ProcessTree.runsShell(under:)) ?? false)
        }
        keepAwake.hold(KeepAwakePolicy().holds(facts))
    }

    // MARK: Files

    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    /// Coalesces bursts of changes (typing, several hooks) into one write.
    private func saveConfig() {
        guard configError == nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? self.store.save(self.config)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushSave() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        if configError == nil { try? store.save(config) }
    }

    private func writeClaudeFiles() throws {
        // The small hook binary starts in a few ms; the app binary is the fallback.
        let hook = URL(fileURLWithPath: helperPath).deletingLastPathComponent().appendingPathComponent("workspaces-hook").path
        let settings = FileManager.default.isExecutableFile(atPath: hook)
            ? ClaudeLaunch.settingsJSON(hookCommand: ClaudeLaunch.shellQuote(hook),
                                        statusLineCommand: ClaudeLaunch.shellQuote(hook) + " statusline")
            : ClaudeLaunch.settingsJSON(helperPath: helperPath)
        try settings.encodedLine().write(to: AppPaths.claudeSettingsFile, options: .atomic)
        try ClaudeLaunch.mcpConfigJSON(helperPath: helperPath).encodedLine().write(to: AppPaths.mcpConfigFile, options: .atomic)
    }
}

/// Sessions left behind by an earlier run that crashed: Claude processes adopted by launchd
/// that carry this app's settings file. Only those are touched.
enum Orphans {
    static func reap(settingsPath: String) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axww", "-o", "pid=,ppid=,args="]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            var orphans: [pid_t] = []
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = pid_t(parts[0]), parts[1] == "1",
                      parts[2].contains("--settings \(settingsPath)") else { continue }
                orphans.append(pid)
            }
            for pid in orphans {
                // A frozen one ignores SIGTERM until continued.
                killpg(pid, SIGCONT)
                killpg(pid, SIGTERM)
            }
            guard !orphans.isEmpty else { return }
            Thread.sleep(forTimeInterval: 3)
            for pid in orphans where kill(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
    }
}

/// Equal paths after resolving symlinks (/tmp and /private/tmp are the same folder).
private func samePath(_ a: String, _ b: String?) -> Bool {
    guard let b else { return false }
    return URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
}

enum Git {
    /// Current branch of the repository at `path`, or nil outside git.
    static func branch(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) || out == "HEAD" ? nil : out
    }
}
