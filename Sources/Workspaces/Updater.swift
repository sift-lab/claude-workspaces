import AppKit
import WorkspacesCore

/// Updates the app from the main branch of the repository it was built from, like any Mac app:
/// "Procurar atualizações…" in the app menu, the same check in silence at launch and every 30 min,
/// a build in the background in a worktree of its own, and a dialog when the new version is ready.
/// Nothing is applied without "Reiniciar agora"; the swap itself runs in a detached helper
/// (UpdateInstaller) that puts the previous app back if the new one does not come up.
@MainActor
final class Updater {
    static let checkInterval: TimeInterval = 30 * 60
    /// The first check waits for the sessions of the launch to settle.
    static let firstCheckDelay: TimeInterval = 60

    enum State: Equatable {
        case idle
        case checking
        /// Waiting for free memory or disk before building.
        case waiting(commit: String, reason: String)
        case building(String)
        case ready(Ready)
        case failed(commit: String?, reason: String)
    }

    struct Ready: Equatable {
        let commit: String
        let subject: String?
        let newCommits: Int?
    }

    private(set) var state: State = .idle
    let stamp = BuildStamp(info: Bundle.main.infoDictionary)
    private let paths = UpdatePaths()
    private weak var model: AppModel?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "workspaces.update", qos: .utility)
    /// The dialog went up for this commit in this run: the periodic check does not repeat it.
    private var offered: String?
    /// Commits whose build failed in this run: retried only by a manual check.
    private var buildFailures: Set<String> = []
    /// A manual check asked to hear back when the build it started ends.
    private var reportBuild = false
    /// "Procurar atualizações…" was chosen while a silent check ran: its answer is shown.
    private var reportCheck = false

    init(model: AppModel) {
        self.model = model
    }

    /// Why updating is off, or nil when it is on.
    var unavailable: String? {
        guard let stamp else { return "Este build não diz de que commit veio. Gere o app com scripts/build-app.sh." }
        guard FileManager.default.fileExists(atPath: stamp.repository + "/.git") else {
            return "Não achei o repositório \(stamp.repository), de onde este build veio."
        }
        if Bundle.main.bundlePath.hasPrefix(stamp.repository + "/") {
            return "Este app é o build/ do próprio repositório; só o app instalado se atualiza."
        }
        return nil
    }

    /// At launch: says the app came up (the helper waits for this) and schedules the checks.
    func start() {
        try? UpdateHeartbeat(pid: getpid(), commit: stamp?.commit, time: Date()).write(to: paths.heartbeat)
        if let staged = BuildStamp(bundle: paths.staged), staged.commit == stamp?.commit {
            try? FileManager.default.removeItem(at: paths.staged)
        }
        guard unavailable == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(manual: false) }
        }
        timer?.tolerance = 60
    }

    // MARK: Checking

    func check(manual: Bool) {
        if let reason = unavailable {
            if manual { tell("Não dá para procurar atualizações", reason) }
            return
        }
        switch state {
        case .checking:
            if manual { reportCheck = true }
            return
        case .waiting(let commit, let reason):
            if manual { reportBuild = true; tell("Há uma versão nova do Workspaces", "A versão \(short(commit)) vai ser compilada em segundo plano assim que houver espaço: \(reason). Aviso quando estiver pronta.") }
            return
        case .building(let commit):
            if manual { reportBuild = true; tell("Há uma versão nova do Workspaces", "Estou compilando a versão \(short(commit)) em segundo plano. Aviso quando estiver pronta.") }
            return
        case .idle, .ready, .failed:
            break
        }
        guard let stamp else { return }
        let previous = state
        state = .checking
        let environment = model?.toolEnvironment ?? ProcessInfo.processInfo.environment
        queue.async {
            let found = UpdateWork.inspect(stamp: stamp, environment: environment)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let report = manual || self.reportCheck
                    self.reportCheck = false
                    self.inspected(found, previous: previous, manual: report)
                }
            }
        }
    }

    private func inspected(_ found: UpdateWork.Inspection, previous: State, manual: Bool) {
        guard let stamp else { return }
        switch found.result {
        case .failure(let failure):
            state = previous
            if manual { tell("Não consegui procurar atualizações", failure.message) }
        case .success(.upToDate):
            state = .idle
            if manual { tell(UpdatePrompt.upToDateTitle, "Versão \(stamp.short), a mesma da main de \(stamp.repository).") }
        case .success(.installedAhead):
            state = .idle
            if manual { tell(UpdatePrompt.upToDateTitle, "A versão instalada (\(stamp.short)) tem commits que a main ainda não tem; não há o que atualizar.") }
        case .success(.available(let target)):
            let ready = Ready(commit: target, subject: found.subject, newCommits: found.newCommits)
            if paths.failedCommits().contains(target) {
                state = .idle
                if manual { tell(UpdatePrompt.upToDateTitle, "A versão \(short(target)) não abriu na última tentativa e foi desfeita. A próxima atualização vem com o próximo commit na main; o registro está em \(paths.applyLog.path).") }
                return
            }
            if BuildStamp(bundle: paths.staged)?.commit == target {
                state = .ready(ready)
                offer(ready, manual: manual)
                return
            }
            if buildFailures.contains(target), !manual {
                state = previous
                return
            }
            if manual {
                reportBuild = true
                tell("Há uma versão nova do Workspaces", "A versão \(short(target)) vai ser compilada em segundo plano. Aviso quando estiver pronta.")
            }
            build(ready)
        }
    }

    // MARK: Building

    private func build(_ ready: Ready) {
        guard let stamp else { return }
        state = .building(ready.commit)
        let environment = model?.toolEnvironment ?? ProcessInfo.processInfo.environment
        let paths = paths
        queue.async {
            let result = UpdateWork.build(commit: ready.commit, stamp: stamp, paths: paths, environment: environment) { reason in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.state = reason.map { .waiting(commit: ready.commit, reason: $0) } ?? .building(ready.commit)
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.built(ready, result) } }
        }
    }

    private func built(_ ready: Ready, _ result: Result<Void, UpdateWork.Failure>) {
        let manual = reportBuild
        reportBuild = false
        switch result {
        case .success:
            state = .ready(ready)
            offer(ready, manual: manual)
        case .failure(let failure):
            buildFailures.insert(ready.commit)
            state = .failed(commit: ready.commit, reason: failure.message)
            if manual { tell("A versão nova não compilou", "\(failure.message)\n\nO registro está em \(paths.buildLog.path).") }
        }
    }

    // MARK: Asking and restarting

    private func offer(_ ready: Ready, manual: Bool) {
        guard manual || offered != ready.commit, let model else { return }
        offered = ready.commit
        let counts = model.busySessions
        let alert = NSAlert()
        alert.messageText = UpdatePrompt.readyTitle
        alert.informativeText = UpdatePrompt.readyBody(short: short(ready.commit), subject: ready.subject, newCommits: ready.newCommits,
                                                       working: counts.working, waiting: counts.waiting)
        alert.addButton(withTitle: UpdatePrompt.restart)
        alert.addButton(withTitle: UpdatePrompt.later)
        present(alert, activate: manual) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // Sessions may have started working while the dialog was open: say so before cutting them.
            let now = model.busySessions
            if now.working + now.waiting > counts.working + counts.waiting {
                self.offer(ready, manual: true)
            } else {
                self.restartNow(ready)
            }
        }
    }

    private func restartNow(_ ready: Ready) {
        guard let model, BuildStamp(bundle: paths.staged)?.commit == ready.commit,
              let executable = Bundle.main.executablePath else {
            tell("Não consegui atualizar", "A versão nova não está mais em \(paths.staged.path). Procure atualizações de novo.")
            state = .idle
            return
        }
        let fm = FileManager.default
        let hook = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("workspaces-hook")
        let plan = UpdatePlan(appPID: getpid(), installed: Bundle.main.bundlePath, commit: ready.commit,
                              updateDirectory: paths.directory.path)
        do {
            try? fm.removeItem(at: paths.helper)
            try fm.copyItem(at: hook, to: paths.helper)
            try JSONEncoder().encode(plan).write(to: paths.plan, options: .atomic)
            try JSONEncoder().encode(model.openWorkspaceIds).write(to: paths.reopen, options: .atomic)
            try? fm.removeItem(at: paths.heartbeat)
        } catch {
            tell("Não consegui preparar a atualização", error.localizedDescription)
            return
        }
        guard DetachedProcess.spawn(paths.helper.path, arguments: ["apply-update", paths.plan.path], output: paths.applyLog) != nil else {
            tell("Não consegui preparar a atualização", "O auxiliar que troca o app não abriu.")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Dialogs

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        present(alert, activate: true) { _ in }
    }

    /// A sheet on a workspace window, so the app keeps running (timers, sessions) while it is open.
    /// An automatic offer does not take the focus from where the person is typing.
    private func present(_ alert: NSAlert, activate: Bool, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = model?.presentationWindow {
            if activate { NSApp.activate(ignoringOtherApps: true) }
            else if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            alert.beginSheetModal(for: window, completionHandler: then)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            then(alert.runModal())
        }
    }

    private func short(_ commit: String) -> String { String(commit.prefix(7)) }
}

/// The slow parts, off the main thread: git, the gate, the build and the checks on what it made.
enum UpdateWork {
    struct Failure: Error, Equatable {
        let message: String
    }

    struct Inspection {
        var result: Result<UpdateCheck, Failure>
        var subject: String?
        var newCommits: Int?
    }

    static let buildTimeout: TimeInterval = 45 * 60
    /// How long a build waits for room before giving up until the next check.
    static let gateTimeout: TimeInterval = 25 * 60

    static func inspect(stamp: BuildStamp, environment: [String: String]) -> Inspection {
        let repo = stamp.repository
        let remotes = run("/usr/bin/git", ["-C", repo, "remote"], environment: environment).output
        if remotes.split(separator: "\n").contains("origin") {
            // Only the remote-tracking branch moves; nothing checked out is touched.
            _ = run("/usr/bin/git", ["-C", repo, "fetch", "--quiet", "origin", "main"], environment: environment, timeout: 60)
        }
        let main = revision(repo, "refs/heads/main", environment)
        let origin = revision(repo, "refs/remotes/origin/main", environment)
        let isAncestor = { (a: String, b: String) in ancestor(repo, a, b, environment) }
        guard let target = UpdateDecision.target(main: main, originMain: origin, isAncestor: isAncestor) else {
            return Inspection(result: .failure(Failure(message: "O repositório \(repo) não tem a branch main.")))
        }
        let check = UpdateDecision.check(installed: stamp.commit, target: target, isAncestor: isAncestor)
        guard case .available = check else { return Inspection(result: .success(check)) }
        let subject = run("/usr/bin/git", ["-C", repo, "log", "-1", "--format=%s", target], environment: environment).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let count = Int(run("/usr/bin/git", ["-C", repo, "rev-list", "--count", "\(stamp.commit)..\(target)"], environment: environment)
            .output.trimmingCharacters(in: .whitespacesAndNewlines))
        return Inspection(result: .success(check), subject: subject.isEmpty ? nil : subject, newCommits: count)
    }

    /// `waiting` gets the reason while the gate holds the build, and nil once it starts.
    static func build(commit: String, stamp: BuildStamp, paths: UpdatePaths, environment: [String: String],
                      waiting: (String?) -> Void) -> Result<Void, Failure> {
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)

        let deadline = Date().addingTimeInterval(gateTimeout)
        while case .wait(let reason) = BuildGate.check(freeMemoryPercent: freeMemoryPercent(), freeDiskBytes: freeDiskBytes()) {
            guard Date() < deadline else { return .failure(Failure(message: "Sem espaço para compilar: \(reason).")) }
            waiting(reason)
            Thread.sleep(forTimeInterval: 60)
        }
        waiting(nil)

        let worktree = AppPaths.updateWorktree
        if let failure = prepare(worktree: worktree, repo: stamp.repository, commit: commit, environment: environment) {
            return .failure(failure)
        }

        var env = environment
        env["WORKSPACES_BUILD_JOBS"] = "2"
        env["WORKSPACES_REPOSITORY"] = stamp.repository
        for key in [ClaudeLaunch.sessionEnvKey, ClaudeLaunch.launchEnvKey, "WORKSPACES_HOME"] { env[key] = nil }
        fm.createFile(atPath: paths.buildLog.path, contents: Data("Compilando \(commit) em \(worktree.path)\n".utf8))
        // Low priority: utility QoS and nice, next to the sessions.
        let build = run("/usr/sbin/taskpolicy", ["-c", "utility", "/usr/bin/nice", "-n", "15", "/bin/zsh", "scripts/build-app.sh"],
                        environment: env, directory: worktree, timeout: buildTimeout, log: paths.buildLog)
        guard build.status == 0 else {
            return .failure(Failure(message: build.timedOut ? "A compilação passou de 45 min e parei." : "A compilação falhou (saída \(build.status))."))
        }

        let app = worktree.appendingPathComponent("build/Workspaces.app", isDirectory: true)
        guard BuildStamp(bundle: app)?.commit == commit else {
            return .failure(Failure(message: "O app compilado não diz ser o commit \(commit.prefix(7))."))
        }
        // Privacy grants follow the signing identity: an app signed by another one would lose them.
        let mine = team(of: URL(fileURLWithPath: Bundle.main.bundlePath))
        if let mine, team(of: app) != mine {
            return .failure(Failure(message: "A versão nova não foi assinada com o certificado do app instalado (\(mine)); as permissões do macOS se perderiam."))
        }
        try? fm.removeItem(at: paths.staged)
        do {
            try fm.moveItem(at: app, to: paths.staged)
        } catch {
            return .failure(Failure(message: "Não consegui guardar o app compilado: \(error.localizedDescription)"))
        }
        return .success(())
    }

    /// A detached checkout of `commit` in the update worktree, created on first use.
    private static func prepare(worktree: URL, repo: String, commit: String, environment: [String: String]) -> Failure? {
        let fm = FileManager.default
        if fm.fileExists(atPath: worktree.appendingPathComponent(".git").path) {
            let checkout = run("/usr/bin/git", ["-C", worktree.path, "checkout", "--quiet", "--detach", "--force", commit], environment: environment)
            guard checkout.status == 0 else { return Failure(message: "git checkout falhou no worktree: \(checkout.output)") }
            // Leftovers of an older build go; the .build cache stays so the next build is incremental.
            _ = run("/usr/bin/git", ["-C", worktree.path, "clean", "-ffdx", "--quiet", "-e", ".build"], environment: environment)
            return nil
        }
        try? fm.removeItem(at: worktree)
        try? fm.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = run("/usr/bin/git", ["-C", repo, "worktree", "prune"], environment: environment)
        let add = run("/usr/bin/git", ["-C", repo, "worktree", "add", "--quiet", "--detach", "--force", worktree.path, commit], environment: environment)
        return add.status == 0 ? nil : Failure(message: "git worktree add falhou: \(add.output)")
    }

    private static func revision(_ repo: String, _ ref: String, _ environment: [String: String]) -> String? {
        let result = run("/usr/bin/git", ["-C", repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}"], environment: environment)
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !value.isEmpty ? value : nil
    }

    /// True when `b` contains `a`; nil when git does not know one of them.
    private static func ancestor(_ repo: String, _ a: String, _ b: String, _ environment: [String: String]) -> Bool? {
        switch run("/usr/bin/git", ["-C", repo, "merge-base", "--is-ancestor", a, b], environment: environment).status {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    private static func team(of app: URL) -> String? {
        CodeSignature.teamIdentifier(codesignOutput: run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path], environment: [:]).output)
    }

    private static func freeMemoryPercent() -> Int? {
        BuildGate.freeMemoryPercent(memoryPressureOutput: run("/usr/bin/memory_pressure", [], environment: [:]).output)
    }

    private static func freeDiskBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    struct Output {
        var status: Int32
        var output: String
        var timedOut = false
    }

    /// Runs a tool and waits, stdout and stderr together; into `log` when given (the build).
    static func run(_ path: String, _ arguments: [String], environment: [String: String], directory: URL? = nil,
                    timeout: TimeInterval = 120, log: URL? = nil) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = environment.isEmpty ? ProcessInfo.processInfo.environment : environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        var logHandle: FileHandle?
        if let log, let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            logHandle = handle
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = pipe
            process.standardError = pipe
        }
        defer { try? logHandle?.close() }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return Output(status: -1, output: error.localizedDescription) }
        var data = Data()
        let reader = DispatchGroup()
        if logHandle == nil {
            reader.enter()
            DispatchQueue.global(qos: .utility).async {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                reader.leave()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // The whole build tree (zsh, swift-build, the compilers), not only the first process.
            var tree = [process.processIdentifier]
            var index = 0
            while index < tree.count, tree.count < 512 {
                tree += ProcessTree.children(of: tree[index])
                index += 1
            }
            for pid in tree { kill(pid, SIGTERM) }
            if done.wait(timeout: .now() + 10) == .timedOut {
                for pid in tree { kill(pid, SIGKILL) }
                done.wait()
            }
            reader.wait()
            return Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), timedOut: true)
        }
        reader.wait()
        return Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
