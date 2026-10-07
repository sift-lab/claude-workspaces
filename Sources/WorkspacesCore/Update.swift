import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The app updates itself from the main branch of the repository it was built from: it builds the
// new commit in a worktree of its own, asks before restarting, and a detached helper swaps the
// bundle, checks that the new one came up and puts the previous one back when it did not.

/// What scripts/build-app.sh stamps into Info.plist: the commit and the repository it came from.
public struct BuildStamp: Equatable, Sendable {
    public static let commitKey = "WorkspacesCommit"
    public static let repositoryKey = "WorkspacesRepository"
    public static let dirtyKey = "WorkspacesDirty"

    public var commit: String
    public var repository: String
    /// Built with uncommitted changes, so it is the commit plus something else.
    public var dirty: Bool

    public init(commit: String, repository: String, dirty: Bool = false) {
        self.commit = commit
        self.repository = repository
        self.dirty = dirty
    }

    public init?(info: [String: Any]?) {
        guard let commit = info?[Self.commitKey] as? String, !commit.isEmpty,
              let repository = info?[Self.repositoryKey] as? String, !repository.isEmpty else { return nil }
        self.init(commit: commit, repository: repository, dirty: (info?[Self.dirtyKey] as? Bool) ?? false)
    }

    /// The stamp of an app bundle on disk, nil when it has none (built before the updater existed).
    public init?(bundle: URL) {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        self.init(info: info)
    }

    public var short: String { String(commit.prefix(7)) }
}

public enum UpdateCheck: Equatable, Sendable {
    case upToDate
    /// The target commit has everything the installed build has, and more.
    case available(String)
    /// The installed build has commits the main branch does not: building main would lose them.
    case installedAhead
}

public enum UpdateDecision {
    /// What to build: the local main, or origin/main after a fetch when it is ahead of the local one.
    /// `isAncestor(a, b)` is true when b contains a, nil when git does not know one of them.
    public static func target(main: String?, originMain: String?, isAncestor: (String, String) -> Bool?) -> String? {
        guard let main else { return originMain }
        guard let originMain, originMain != main else { return main }
        return isAncestor(main, originMain) == true ? originMain : main
    }

    public static func check(installed: String, target: String, isAncestor: (String, String) -> Bool?) -> UpdateCheck {
        if installed == target { return .upToDate }
        switch isAncestor(installed, target) {
        case true?: return .available(target)
        case false?: return .installedAhead
        // A commit the repository no longer has (rebased away): main is the reference.
        case nil: return .available(target)
        }
    }
}

/// The build waits for room: it runs next to Claude sessions on a machine that may have 8 GB.
public enum BuildGate {
    public static let minimumFreeMemoryPercent = 30
    public static let minimumFreeDiskBytes: Int64 = 4 * 1024 * 1024 * 1024

    public enum Result: Equatable, Sendable {
        case go
        case wait(String)
    }

    /// Reads "System-wide memory free percentage: 63%" from `memory_pressure`.
    public static func freeMemoryPercent(memoryPressureOutput text: String) -> Int? {
        for line in text.split(separator: "\n") where line.lowercased().contains("free percentage") {
            let digits = line.split(separator: ":").last?.filter(\.isNumber) ?? ""
            if let value = Int(digits) { return value }
        }
        return nil
    }

    public static func check(freeMemoryPercent: Int?, freeDiskBytes: Int64?) -> Result {
        guard let memory = freeMemoryPercent else { return .wait("não consegui ler a memória livre") }
        if memory <= minimumFreeMemoryPercent {
            return .wait("memória livre em \(memory)%, espero passar de \(minimumFreeMemoryPercent)%")
        }
        if let disk = freeDiskBytes, disk < minimumFreeDiskBytes {
            return .wait("disco com \(disk / 1_073_741_824) GB livres, espero ter \(minimumFreeDiskBytes / 1_073_741_824) GB")
        }
        return .go
    }
}

public enum CodeSignature {
    /// "TeamIdentifier=PP624GBC36" from `codesign -dv`; nil for ad-hoc ("not set") or unsigned.
    public static func teamIdentifier(codesignOutput text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }
}

/// The dialog texts. The sessions are named because restarting interrupts the ones in a turn.
public enum UpdatePrompt {
    public static let readyTitle = "Há uma versão nova do Workspaces"
    public static let upToDateTitle = "Você já está na versão mais recente"
    public static let restart = "Reiniciar agora"
    public static let later = "Depois"

    public static func readyBody(short: String, subject: String?, newCommits: Int?, working: Int, waiting: Int) -> String {
        var text = "A versão \(short) está pronta"
        if let subject, !subject.isEmpty { text += ": \(subject)" }
        text += "."
        if let newCommits, newCommits > 1 { text += " São \(newCommits) commits novos." }
        return text + "\n\n" + interruption(working: working, waiting: waiting)
    }

    public static func interruption(working: Int, waiting: Int) -> String {
        let total = max(0, working) + max(0, waiting)
        guard total > 0 else { return "Nenhuma sessão está trabalhando. Todas voltam com --resume quando o app reabrir." }
        var who: String
        if working > 0 {
            who = working == 1 ? "1 sessão está trabalhando" : "\(working) sessões estão trabalhando"
            if waiting > 0 { who += waiting == 1 ? " e 1 está esperando você" : " e \(waiting) estão esperando você" }
        } else {
            who = waiting == 1 ? "1 sessão está esperando você" : "\(waiting) sessões estão esperando você"
        }
        let what = total == 1 ? "Ela será interrompida e volta com --resume quando o app reabrir."
                              : "Elas serão interrompidas e voltam com --resume quando o app reabrir."
        return "\(who) agora. \(what)"
    }
}

/// Written by the app once it finished launching; the helper reads it to know the new build came up.
public struct UpdateHeartbeat: Codable, Equatable, Sendable {
    public var pid: Int32
    public var commit: String?
    public var time: Date

    public init(pid: Int32, commit: String?, time: Date) {
        self.pid = pid
        self.commit = commit
        self.time = time
    }

    public static func read(_ url: URL) -> UpdateHeartbeat? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateHeartbeat.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Where the update's files live, inside the app's support folder.
public struct UpdatePaths: Equatable, Sendable {
    public var directory: URL

    public init(directory: URL = AppPaths.updateDirectory) {
        self.directory = directory
    }

    /// The built app waiting for "Reiniciar agora".
    public var staged: URL { directory.appendingPathComponent("Workspaces.app", isDirectory: true) }
    /// The app that was installed before the last update.
    public var backup: URL { directory.appendingPathComponent("Workspaces-previous.app", isDirectory: true) }
    public var heartbeat: URL { directory.appendingPathComponent("heartbeat.json") }
    public var plan: URL { directory.appendingPathComponent("plan.json") }
    /// Commits that did not build or did not start: not offered again automatically.
    public var failed: URL { directory.appendingPathComponent("failed.json") }
    /// Workspaces whose windows were open, reopened after the restart.
    public var reopen: URL { directory.appendingPathComponent("reopen.json") }
    public var buildLog: URL { directory.appendingPathComponent("build.log") }
    public var applyLog: URL { directory.appendingPathComponent("apply.log") }
    /// A copy of the hook helper, run outside the bundle it replaces.
    public var helper: URL { directory.appendingPathComponent("updater") }

    public func failedCommits() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: failed.path),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    public func markFailed(_ commit: String) {
        var list = failedCommits()
        list.insert(commit)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(list.sorted()).write(to: failed, options: .atomic)
    }
}

/// What the app hands the detached helper.
public struct UpdatePlan: Codable, Equatable, Sendable {
    /// The running app, which quits right after starting the helper.
    public var appPID: Int32
    public var installed: String
    public var commit: String
    public var updateDirectory: String
    public var startTimeout: TimeInterval
    public var exitTimeout: TimeInterval

    public init(appPID: Int32, installed: String, commit: String, updateDirectory: String,
                startTimeout: TimeInterval = 20, exitTimeout: TimeInterval = 90) {
        self.appPID = appPID
        self.installed = installed
        self.commit = commit
        self.updateDirectory = updateDirectory
        self.startTimeout = startTimeout
        self.exitTimeout = exitTimeout
    }

    public var paths: UpdatePaths { UpdatePaths(directory: URL(fileURLWithPath: updateDirectory, isDirectory: true)) }
}

/// The helper's job, after the app quit: backup, swap, open, confirm, or put the previous app back.
public struct UpdateInstaller {
    public struct Environment {
        public var isAlive: (Int32) -> Bool
        public var open: (URL) -> Bool
        /// Ends every process running the executable inside this bundle.
        public var terminateApp: (URL) -> Void
        public var sleep: (TimeInterval) -> Void
        public var now: () -> Date
        public var notify: (_ title: String, _ body: String) -> Void
        public var log: (String) -> Void

        public init(isAlive: @escaping (Int32) -> Bool, open: @escaping (URL) -> Bool, terminateApp: @escaping (URL) -> Void,
                    sleep: @escaping (TimeInterval) -> Void, now: @escaping () -> Date,
                    notify: @escaping (String, String) -> Void, log: @escaping (String) -> Void) {
            self.isAlive = isAlive
            self.open = open
            self.terminateApp = terminateApp
            self.sleep = sleep
            self.now = now
            self.notify = notify
            self.log = log
        }
    }

    public enum Outcome: Equatable, Sendable {
        case installed
        /// The new build did not come up; the previous one is back in place.
        case rolledBack(String)
        /// Nothing was touched.
        case aborted(String)
    }

    /// After the heartbeat, the new app must still be alive this long later.
    public static let stayUp: TimeInterval = 3
    static let poll: TimeInterval = 0.5

    public let plan: UpdatePlan
    public let env: Environment

    public init(plan: UpdatePlan, env: Environment) {
        self.plan = plan
        self.env = env
    }

    public func run() -> Outcome {
        let fm = FileManager.default
        let paths = plan.paths
        let installed = URL(fileURLWithPath: plan.installed, isDirectory: true)

        guard waitForExit() else { return abort("o app não fechou em \(Int(plan.exitTimeout)) s; nada foi trocado", reopen: nil) }
        guard BuildStamp(bundle: paths.staged)?.commit == plan.commit else {
            return abort("a versão nova não está em \(paths.staged.path); nada foi trocado", reopen: installed)
        }

        let hadPrevious = fm.fileExists(atPath: installed.path)
        if hadPrevious {
            try? fm.removeItem(at: paths.backup)
            do {
                try fm.moveItem(at: installed, to: paths.backup)
            } catch {
                return abort("não consegui guardar o app atual (\(error.localizedDescription)); nada foi trocado", reopen: installed)
            }
            env.log("backup em \(paths.backup.path)")
        }
        do {
            try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: paths.staged, to: installed)
        } catch {
            return rollBack(installed, hadPrevious: hadPrevious, "não consegui pôr a versão nova no lugar (\(error.localizedDescription))")
        }
        env.log("instalado \(plan.commit)")

        let started = env.now()
        guard env.open(installed), let pid = waitForHeartbeat(since: started) else {
            return rollBack(installed, hadPrevious: hadPrevious, "a versão nova não abriu em \(Int(plan.startTimeout)) s")
        }
        env.sleep(Self.stayUp)
        guard env.isAlive(pid) else {
            return rollBack(installed, hadPrevious: hadPrevious, "a versão nova fechou logo depois de abrir")
        }
        env.log("aberto, pid \(pid)")
        env.notify("Workspaces atualizado", "Versão \(String(plan.commit.prefix(7))) aberta. As sessões voltam com --resume.")
        return .installed
    }

    private func waitForExit() -> Bool {
        let deadline = env.now().addingTimeInterval(plan.exitTimeout)
        while env.isAlive(plan.appPID) {
            if env.now() >= deadline { return false }
            env.sleep(Self.poll)
        }
        return true
    }

    /// The pid of the new app once it wrote a heartbeat with the expected commit.
    private func waitForHeartbeat(since started: Date) -> Int32? {
        let deadline = started.addingTimeInterval(plan.startTimeout)
        repeat {
            if let beat = UpdateHeartbeat.read(plan.paths.heartbeat), beat.commit == plan.commit,
               beat.time >= started.addingTimeInterval(-2), env.isAlive(beat.pid) {
                return beat.pid
            }
            env.sleep(Self.poll)
        } while env.now() < deadline
        return nil
    }

    /// The app already quit when this runs, so it is opened again unless it never closed.
    private func abort(_ reason: String, reopen: URL?) -> Outcome {
        env.log("cancelado: \(reason)")
        if let reopen { _ = env.open(reopen) }
        env.notify("Atualização do Workspaces cancelada", reason)
        return .aborted(reason)
    }

    private func rollBack(_ installed: URL, hadPrevious: Bool, _ reason: String) -> Outcome {
        let fm = FileManager.default
        let paths = plan.paths
        env.log("voltando: \(reason)")
        env.terminateApp(installed)
        plan.paths.markFailed(plan.commit)
        guard hadPrevious else {
            env.notify("Atualização do Workspaces falhou", "\(reason). Não havia versão anterior para voltar.")
            return .rolledBack(reason)
        }
        try? fm.removeItem(at: installed)
        do {
            try fm.moveItem(at: paths.backup, to: installed)
        } catch {
            env.notify("Atualização do Workspaces falhou", "\(reason), e a volta também: a versão anterior está em \(paths.backup.path).")
            return .rolledBack(reason)
        }
        _ = env.open(installed)
        env.notify("Atualização do Workspaces desfeita", "\(reason). Voltei a versão anterior.")
        return .rolledBack(reason)
    }
}

/// Processes whose executable lives inside an app bundle.
public enum BundleProcesses {
    public static func pids(runningFrom bundle: URL) -> [Int32] {
        let prefix = bundle.resolvingSymlinksInPath().path + "/Contents/MacOS/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        var found: [Int32] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != getpid() {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if String(cString: buffer).hasPrefix(prefix) { found.append(pid) }
        }
        return found
    }
}

public extension UpdateInstaller.Environment {
    /// The real one, for the helper: `open`, notifications through osascript, the log file.
    static func live(logFile: URL) -> UpdateInstaller.Environment {
        func run(_ path: String, _ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }
        func log(_ text: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
        return UpdateInstaller.Environment(
            isAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
            open: { url in run("/usr/bin/open", [url.path]) == 0 },
            terminateApp: { bundle in
                let pids = BundleProcesses.pids(runningFrom: bundle)
                for pid in pids { kill(pid, SIGTERM) }
                var waited = 0
                while waited < 50, pids.contains(where: { kill($0, 0) == 0 }) {
                    Thread.sleep(forTimeInterval: 0.2)
                    waited += 1
                }
                for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            now: { Date() },
            notify: { title, body in
                log("\(title): \(body)")
                let quote = { (s: String) in "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
                _ = run("/usr/bin/osascript", ["-e", "display notification \(quote(body)) with title \(quote(title))"])
            },
            log: log)
    }
}

/// Starts a program in a session of its own, so it outlives the app that started it and the app's
/// open files (sockets, terminals) are not inherited.
public enum DetachedProcess {
    public static func spawn(_ path: String, arguments: [String], output: URL) -> pid_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, output.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        return status == 0 ? pid : nil
    }
}
