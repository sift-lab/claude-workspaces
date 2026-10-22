import AppKit
import Observation
import SwiftUI
import WorkspacesCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            saveConfig()
            // The meter follows the account sessions start in, however it changed.
            tokens.useAccount(activeAccount.name)
        }
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
    /// recycle_self, recycle_session and close_session. Set at the end of init.
    @ObservationIgnored private(set) var recycler: Recycler!
    /// The tab and the title of each task, `/titulo` and Renomear. Set at the end of init.
    @ObservationIgnored private(set) var titler: SessionTitler!
    /// Moves the sessions to another Claude Code account. Set at the end of init.
    @ObservationIgnored private(set) var accounts: AccountSwitcher!
    /// The plugin with `/workspaces:titulo` was written and goes to every session.
    @ObservationIgnored private var pluginReady = false
    /// "Procurar atualizações…" and the silent checks. Started once the app finished launching.
    @ObservationIgnored private(set) var updater: Updater!
    /// Workspaces whose windows were open before an update restarted the app.
    @ObservationIgnored private var pendingReopen: [UUID] = []
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
        recycler = Recycler(model: self)
        titler = SessionTitler(model: self)
        accounts = AccountSwitcher(model: self)
        updater = Updater(model: self)
        pendingReopen = Self.takeReopenList()
        tokens.useAccount(activeAccount.name)
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

    /// The account named by the app's own `WORKSPACES_CONTA`, or conta1: Claude Code's default login
    /// when no accounts are set.
    nonisolated static let environmentAccount = LimitReadingStore.accountName(
        ProcessInfo.processInfo.environment[LimitReadingStore.accountEnvKey])

    /// The account sessions start in.
    var activeAccount: ClaudeAccount { config.currentAccount(fallback: Self.environmentAccount) }

    /// A new account in the settings: "conta1" in Claude Code's default folder, then "conta2"...
    /// The first one is the login in use, under the name it already had, so nothing moves.
    func addAccount() {
        guard !config.accounts.isEmpty else {
            var first = config
            first.accounts = [ClaudeAccount(name: Self.environmentAccount)]
            first.activeAccount = Self.environmentAccount
            config = first
            return
        }
        var n = config.accounts.count + 1
        while config.accounts.contains(where: { $0.name == "conta\(n)" }) { n += 1 }
        config.accounts.append(ClaudeAccount(name: "conta\(n)"))
    }

    /// A name must be valid for a file name and unique; anything else is ignored.
    func renameAccount(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard LimitReadingStore.isValidAccount(name), !config.accounts.contains(where: { $0.name == name }),
              let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        let old = config.accounts[i].name
        // The readings and the sessions go with the name, and the config changes in one write.
        tokens.renameAccount(old, to: name)
        accounts.renamed(old, to: name)
        for runtime in sessions where runtime.account == old { runtime.account = name }
        var renamed = config
        if activeAccount.name == old { renamed.activeAccount = name }
        renamed.accounts[i].name = name
        config = renamed
    }

    /// `--resume` finds a conversation only in the folder of the account that runs it, so every
    /// account must keep its conversations in the same place.
    func setAccountFolder(_ id: UUID, to folder: String) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        var account = config.accounts[i]
        account.configDir = folder.trimmingCharacters(in: .whitespaces)
        if let other = config.accounts.first(where: { $0.id != id }), other.conversationsPath != account.conversationsPath {
            accounts.tell("A pasta não foi usada",
                          "Ela guarda as conversas em \(account.conversationsPath) e a \(other.name), em \(other.conversationsPath). Aponte a pasta projects dela para \(other.conversationsPath) e tente de novo.")
            return
        }
        config.accounts[i] = account
    }

    /// The account in use stays: its sessions would have nowhere to go.
    func removeAccount(_ id: UUID) {
        guard let account = config.accounts.first(where: { $0.id == id }), account.name != activeAccount.name else { return }
        config.accounts.removeAll { $0.id == id }
    }

    func session(_ id: UUID?) -> SessionRuntime? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func sessions(inProject id: UUID) -> [SessionRuntime] { sessions.filter { $0.projectId == id } }

    /// The name in the sidebar, numbered when several sessions of a project share it ("main (2)").
    func displayLabel(_ session: SessionRuntime) -> String {
        let name = tabName(session)
        let same = sessions(inProject: session.projectId).filter { tabName($0) == name }
        guard same.count > 1, let index = same.firstIndex(where: { $0.id == session.id }), index > 0 else { return name }
        return "\(name) (\(index + 1))"
    }

    /// The task's tab name, the prompt being named meanwhile, or the branch when the task has no title.
    func tabName(_ session: SessionRuntime) -> String {
        if let title = session.title { return title.tab }
        if session.isTerminal { return session.label }
        if let pending = session.titlePending, !pending.isEmpty { return SessionTitle.clean(pending, limit: SessionTitle.tabLimit) }
        return session.hasConversation || session.status == .ended ? session.label : "Nova sessão"
    }

    /// The sidebar row's tooltip: the whole title, the branch, what it is doing and the tasks before.
    func tooltip(_ session: SessionRuntime) -> String {
        var lines = [session.title?.full, session.label, session.detail].compactMap { $0 }
        if !session.titleHistory.isEmpty { lines.append("Antes: " + session.titleHistory.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
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
        if let name = pendingOpen?.lowercased() {
            pendingOpen = nil
            return config.workspaces.first { $0.name.lowercased() == name }?.id
        }
        guard !pendingReopen.isEmpty else { return nil }
        return pendingReopen.removeFirst()
    }

    // MARK: Update

    /// The login shell's environment for git and the build, or the app's own until it is known.
    var toolEnvironment: [String: String] { loginEnvironment ?? ProcessInfo.processInfo.environment }

    /// Sessions a restart would interrupt now.
    var busySessions: (working: Int, waiting: Int) {
        let live = sessions.filter { !$0.isTerminal && $0.host.isRunning }
        return (live.filter { $0.status == .working }.count, live.filter { $0.status == .waiting }.count)
    }

    /// Workspaces with a window open, reopened after an update.
    var openWorkspaceIds: [UUID] {
        var seen = Set<UUID>()
        return windowActions.values.compactMap { entry in
            guard let window = entry.window, window.isVisible, seen.insert(entry.actions.workspaceId).inserted else { return nil }
            return entry.actions.workspaceId
        }
    }

    /// Where an update dialog goes as a sheet: the workspace window in front, or any visible one.
    var presentationWindow: NSWindow? {
        if let key = NSApp.keyWindow, windowActions[ObjectIdentifier(key)] != nil, key.attachedSheet == nil { return key }
        return windowActions.values.compactMap(\.window).first { $0.isVisible && $0.attachedSheet == nil }
    }

    /// After an update the windows usually come back with macOS's window restoration; the ones that
    /// did not are opened here, a moment after the first window, so a restored one is not doubled.
    func reopenAfterUpdate() {
        guard !pendingReopen.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let missing = self.pendingReopen.filter { !self.startedWorkspaces.contains($0) && self.workspace($0) != nil }
            self.pendingReopen = []
            for id in missing { self.openWindow?(id: "workspace", value: id) }
        }
    }

    private static func takeReopenList() -> [UUID] {
        let url = UpdatePaths().reopen
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
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

    /// `mode` overrides the project's setting (where new sessions open) for this one.
    @discardableResult
    func newSession(projectId: UUID, worktree: String? = nil, prompt: String? = nil, mode: NewSessionMode? = nil) -> SessionRuntime? {
        guard let (workspace, project) = project(projectId) else { return nil }
        let id = UUID()
        var worktreeName = worktree
        if worktreeName == nil, (mode ?? project.newSessionMode) == .worktree {
            worktreeName = "ws-" + String(id.uuidString.lowercased().prefix(6))
        }
        let label = worktreeName ?? Git.branch(at: project.path) ?? project.name
        let saved = SavedSession(id: id, label: label, worktree: worktreeName)
        updateProject(projectId) { $0.savedSessions.append(saved) }
        return launch(saved: saved, project: project, workspaceId: workspace.id, prompt: prompt)
    }

    /// ⌘T: a new Claude session in the worktree `other` works in; in the project's own checkout it
    /// opens as the project is set (its folder or a new worktree).
    @discardableResult
    func newSession(besides other: SessionRuntime) -> SessionRuntime? {
        guard let (workspace, project) = project(other.projectId) else { return nil }
        // Before its first hook a worktree session has no cwd yet; its worktree is where Claude Code makes it.
        let seen = other.cwd ?? other.worktree.map { URL(fileURLWithPath: project.path).appendingPathComponent(".claude/worktrees/\($0)").path }
        guard let folder = seen.flatMap({ Git.otherCheckout(of: project.path, seenFrom: $0) }) else {
            return newSession(projectId: project.id)
        }
        // A worktree name makes the launch reuse the folder in `cwd` instead of creating a worktree.
        let name = other.worktree ?? URL(fileURLWithPath: folder).lastPathComponent
        let saved = SavedSession(id: UUID(), label: Git.branch(at: folder) ?? name, worktree: name, cwd: folder)
        updateProject(project.id) { $0.savedSessions.append(saved) }
        return launch(saved: saved, project: project, workspaceId: workspace.id)
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
        runtime.conversation = ConversationTracker(saved: saved.claudeSessionId)
        runtime.cwd = saved.cwd
        runtime.title = saved.title
        runtime.titleHistory = saved.titleHistory
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
        let resumeId = runtime.conversation.resumable
        let resuming = resumeId != nil
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
            resumeId: resumeId,
            worktree: worktree,
            prompt: prompt,
            extraArguments: project.claudeArguments,
            pluginDir: pluginReady ? AppPaths.pluginDirectory.path : nil
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
        // The account's config folder holds its login; WORKSPACES_CONTA says which account the session's
        // usage belongs to, for scripts that read it (the obra's despachante).
        let account = activeAccount
        var env = account.environment(loginEnvironment)
        runtime.account = account.name
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
        if runtime.hasConversation { hibernate(runtime) }
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
            runtime.conversation = ConversationTracker(saved: summary.id)
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

    /// Ends Claude and starts it again on the same conversation, in the account sessions start in now.
    func relaunch(_ runtime: SessionRuntime, note: String) {
        guard let (_, project) = project(runtime.projectId), let pid = runtime.host.pid else { return }
        // Ending it on purpose: the session is not over, and the old process's SessionEnd is dropped.
        runtime.launch += 1
        let id = runtime.id, launch = runtime.launch
        runtime.host.onTerminated = nil
        runtime.host.terminate()
        runtime.host.show("\r\n\u{1b}[2m(\(note))\u{1b}[0m\r\n")
        Task { @MainActor [weak self] in
            // The old process goes first, so two never write the same conversation.
            var waited = 0
            while kill(pid, 0) == 0, waited < 60 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard let self, let runtime = self.session(id), runtime.launch == launch, !runtime.host.isRunning else { return }
            self.start(runtime, project: project, prompt: nil)
        }
    }

    /// Starts an ended session again in the same place, resuming the conversation when known.
    func restart(_ id: UUID) {
        guard let runtime = session(id), !runtime.host.isRunning, let (_, project) = project(runtime.projectId) else { return }
        start(runtime, project: project, prompt: nil)
    }

    func closeSession(_ id: UUID) {
        guard let runtime = session(id) else { return }
        recycler.forget(id)
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

    func persist(_ runtime: SessionRuntime) {
        updateProject(runtime.projectId) { project in
            guard let i = project.savedSessions.firstIndex(where: { $0.id == runtime.id }) else { return }
            project.savedSessions[i].label = runtime.label
            project.savedSessions[i].title = runtime.title
            project.savedSessions[i].titleHistory = runtime.titleHistory
            // Nil right after a /clear, until the new conversation has a message: a relaunch then
            // starts clean instead of reopening the conversation that was cleared.
            project.savedSessions[i].claudeSessionId = runtime.conversation.resumable
            project.savedSessions[i].cwd = runtime.cwd
        }
    }

    // MARK: Helpers' requests

    private func handle(_ request: IPCRequest) -> IPCResponse {
        let caller = request.session.flatMap(UUID.init(uuidString:)).flatMap { session($0) }
        switch request.kind {
        case .hook:
            // A hook from a process that was already replaced (a hibernated one exiting late) is dropped.
            // The reply's text, when not empty, is JSON the hook prints for Claude Code.
            var output = ""
            if let caller, let payload = request.payload, request.launch.flatMap(Int.init) ?? caller.launch == caller.launch {
                output = applyHook(payload, to: caller) ?? ""
            }
            return IPCResponse(ok: true, text: output)
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
                recycler.statusLine(reading, runtime: caller)
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

    /// A recado typed only once a hibernated session is back.
    func hasPendingPaste(_ id: UUID) -> Bool { pendingPaste[id] != nil }

    /// Applies a hook and returns what the hook should print for Claude Code, if anything.
    private func applyHook(_ payload: JSONValue, to runtime: SessionRuntime) -> String? {
        guard let update = HookEvent.update(from: payload) else { return nil }
        if let path = update.transcriptPath { runtime.transcriptPath = path }
        // `/titulo` is answered here and its prompt blocked: no turn starts, so nothing else changes.
        if update.event == "UserPromptSubmit", let prompt = update.prompt, TitleCommand.parse(prompt) != nil {
            return titler.promptSubmitted(prompt, runtime: runtime)
        }
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
        if update.clearsActivity {
            runtime.setActivity(nil)
            runtime.statusPhraseAt = nil
        }
        // A phrase the session set on purpose (set_status) holds for two minutes over what the tools say.
        if let phrase = update.activity, runtime.statusPhraseAt.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
            runtime.setActivity(phrase)
        }
        let resumable = runtime.conversation.resumable
        if runtime.conversation.apply(update) {
            ConversationLog.append(session: runtime.id, label: runtime.label, update: update,
                                   from: resumable, to: runtime.conversation.resumable)
        }
        if let cwd = update.cwd, !samePath(cwd, runtime.cwd) {
            // The name follows the branch only when it was a branch name; a name the person
            // gave ("automação na QA") stays.
            let previous = runtime.cwd ?? project(runtime.projectId)?.project.path
            let wasBranch = previous.flatMap(Git.branch(at:)) == runtime.label || runtime.label == runtime.worktree
            runtime.cwd = cwd
            let branch = Git.branch(at: cwd)
            if wasBranch, let branch { runtime.label = branch }
            runtime.branchSeen = branch
        } else if update.endsTurn || update.event == "SessionStart" {
            followBranch(runtime)
        }
        persist(runtime)
        if runtime.status == .waiting, before != .waiting { announceWaiting(runtime) }
        updateBadge()
        if runtime.status != before { updateKeepAwake() }

        var output: String?
        switch update.event {
        case "SessionStart" where update.source == "clear":
            titler.cleared(runtime)
            output = recycler.sessionStartContext(for: runtime)
        case "UserPromptSubmit":
            if let prompt = update.prompt { _ = titler.promptSubmitted(prompt, runtime: runtime) }
            output = handoffReminder(runtime, event: update.event)
        case "PostToolUse":
            output = handoffReminder(runtime, event: update.event)
        default:
            break
        }
        recycler.hook(update, runtime: runtime)
        if update.event == "StopFailure" { accounts.turnFailed(update.failure, runtime: runtime) }
        // A session left in the old account moves once its turn is over, after the hook has answered.
        if let account = runtime.account, account != activeAccount.name, runtime.status == .done || runtime.status == .idle {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.accounts.moveSessions()
            }
        }
        return output
    }

    /// The name follows the branch while it is the branch's (or the worktree's) name: a checkout
    /// in the middle of a session shows at the end of the turn. A name given by hand stays.
    private func followBranch(_ runtime: SessionRuntime) {
        guard !runtime.isTerminal, let folder = runtime.cwd ?? project(runtime.projectId)?.project.path else { return }
        // Off the main thread: it runs at the end of every turn of every session.
        let id = runtime.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let branch = Git.branch(at: folder) else { return }
            DispatchQueue.main.async {
                guard let self, let runtime = self.session(id), branch != runtime.branchSeen else { return }
                if runtime.label == runtime.branchSeen || runtime.label == runtime.worktree { runtime.label = branch }
                runtime.branchSeen = branch
                self.persist(runtime)
            }
        }
    }

    var contextLimits: ContextLimits { config.contextLimits }

    /// Above the limit, the session is told to write its Passagem: once on crossing, then every 50 mil.
    private func handoffReminder(_ runtime: SessionRuntime, event: String) -> String? {
        guard !runtime.isTerminal, let conversation = runtime.claudeSessionId, !recycler.isBusy(runtime) else { return nil }
        var last = runtime.handoffReminder?.conversation == conversation ? runtime.handoffReminder?.tokens : nil
        let text = contextLimits.reminder(tokens: tokens.context(runtime), lastWarned: &last)
        runtime.handoffReminder = (conversation, last)
        return text.map { HookOutput.additionalContext(event: event, $0) }
    }

    /// Above 500 mil: one notification per conversation, and the mark turns red. The model is never
    /// switched and nothing is compacted on purpose: compaction summarizes and loses detail.
    func checkContextAlarms() {
        let limits = contextLimits
        for runtime in sessions where !runtime.isTerminal {
            guard let conversation = runtime.claudeSessionId, runtime.alarmedConversation != conversation,
                  let context = tokens.context(runtime), limits.level(context) == .alarm else { continue }
            runtime.alarmedConversation = conversation
            let projectName = project(runtime.projectId)?.project.name ?? ""
            Notifier.shared.post(
                title: "\(displayLabel(runtime)) passou de \(TokenFormat.tokens(limits.alarm)) de contexto",
                body: "\(projectName): contexto em \(TokenFormat.tokens(context)). A sessão precisa escrever a Passagem no FRENTE.md e chamar recycle_self.",
                sessionId: runtime.id)
        }
    }

    func announceWaiting(_ runtime: SessionRuntime, text: String? = nil) {
        guard config.notifyWhenWaiting, !NSApp.isActive || text != nil else { return }
        let projectName = project(runtime.projectId)?.project.name ?? ""
        Notifier.shared.post(title: "\(displayLabel(runtime)) está esperando você",
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
        accounts.moveSessions()
        accounts.check()
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
        pluginReady = (try? TitlePlugin.write(to: AppPaths.pluginDirectory)) != nil
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
        let out = revParse(["--abbrev-ref", "HEAD"], at: path)
        return out == "HEAD" ? nil : out
    }

    /// The project's folder in the checkout `folder` belongs to, when that is another checkout of the
    /// same repository (a worktree); nil when it is the project's own checkout, another repository or outside git.
    static func otherCheckout(of project: String, seenFrom folder: String) -> String? {
        guard let top = revParse(["--show-toplevel"], at: folder),
              let projectTop = revParse(["--show-toplevel"], at: project), top != projectTop,
              let common = revParse(["--path-format=absolute", "--git-common-dir"], at: folder),
              common == revParse(["--path-format=absolute", "--git-common-dir"], at: project) else { return nil }
        let resolved = URL(fileURLWithPath: project).resolvingSymlinksInPath().path
        guard resolved == projectTop || resolved.hasPrefix(projectTop + "/") else { return nil }
        let target = top + resolved.dropFirst(projectTop.count)
        return FileManager.default.fileExists(atPath: target) ? target : nil
    }

    private static func revParse(_ arguments: [String], at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) ? nil : out
    }
}
