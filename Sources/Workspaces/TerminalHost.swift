import AppKit
import Darwin
import SwiftTerm

/// Owns one session's terminal view and the process running in it. Lives as long as the session,
/// so switching sessions or closing the window never kills the process.
final class TerminalHost: NSObject, LocalProcessTerminalViewDelegate {
    static let scrollbackLines = 3000

    let view: LocalProcessTerminalView
    var onTerminated: (() -> Void)?
    private(set) var isRunning = false
    private(set) var isFrozen = false

    override init() {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(white: 0.83, alpha: 1)
        view.caretColor = NSColor(white: 0.96, alpha: 1)
        view.optionAsMetaKey = true
        view.getTerminal().changeScrollback(Self.scrollbackLines)
    }

    var pid: pid_t? {
        guard isRunning, let process = view.process, process.shellPid > 0 else { return nil }
        return process.shellPid
    }

    private static func terminalEnvironment(_ base: [String: String]) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Workspaces"
        if env["LANG"] == nil { env["LANG"] = "pt_BR.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Starts a program directly, without a shell in between.
    func start(executable: String, arguments: [String], environment: [String: String], directory: String) {
        view.startProcess(executable: executable, args: arguments, environment: Self.terminalEnvironment(environment),
                          execName: nil, currentDirectory: directory)
        isRunning = true
        isFrozen = false
    }

    /// Fallback for commands that need shell syntax: the login shell runs `script`.
    func start(script: String, environment: [String: String]) {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(executable: shell, args: ["-l", "-i", "-c", script], environment: Self.terminalEnvironment(environment))
        isRunning = true
        isFrozen = false
    }

    /// Stops the whole process group (Claude and its MCP servers). Returns false if nothing ran.
    @discardableResult
    func freeze() -> Bool {
        guard let pid, !isFrozen else { return false }
        guard signalTree(pid, SIGSTOP) else { return false }
        isFrozen = true
        return true
    }

    func thaw() {
        guard let pid, isFrozen else { return }
        signalTree(pid, SIGCONT)
        isFrozen = false
    }

    /// Signals the process group and every descendant: when a login shell runs Claude, job
    /// control puts Claude in a group of its own, so the group alone would miss it.
    @discardableResult
    private func signalTree(_ root: pid_t, _ sig: Int32) -> Bool {
        var pids = [root]
        var index = 0
        while index < pids.count, pids.count < 256 {
            pids += ProcessTree.children(of: pids[index])
            index += 1
        }
        let ok = killpg(root, sig) == 0
        for pid in pids { kill(pid, sig) }
        return ok || kill(root, 0) == 0
    }

    /// Drops the scrollback, keeping the screen. Used when hibernating: Claude prints the
    /// conversation again when it resumes, so the history would only hold memory.
    func releaseHistory() {
        view.getTerminal().changeScrollback(0)
    }

    func restoreHistory() {
        view.getTerminal().changeScrollback(Self.scrollbackLines)
    }

    /// Pastes text into the prompt without submitting it (bracketed paste keeps newlines literal).
    func paste(_ text: String) {
        view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
    }

    /// Types text as the keyboard would, for a slash command. Only the recycle uses it, with fixed text.
    func type(_ text: String) {
        view.send(txt: text)
    }

    /// Enter: sends what is in the prompt. Only the recycle uses it, after its own fixed text.
    func pressReturn() {
        view.send(txt: "\r")
    }

    /// Writes to the screen only, not to the process.
    func show(_ text: String) {
        view.feed(text: text)
    }

    func terminate() {
        guard isRunning, let pid else { isRunning = false; return }
        // A stopped process keeps SIGTERM pending; wake it so it can exit cleanly.
        thaw()
        signalTree(pid, SIGTERM)
        view.terminate()
        isRunning = false
        // SwiftTerm stops watching the child on terminate, so reap it here (no zombies), and
        // force it if it ignores SIGTERM.
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(5)
            var status: Int32 = 0
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            killpg(pid, SIGKILL)
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// The last non-empty lines on screen, for the grid.
    func snapshot(lines count: Int) -> [String] {
        let terminal = view.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            // Claude positions text with cursor moves, leaving empty cells; they are spaces on screen.
            let line = terminal.getLine(row: row)?.translateToString(trimRight: true, characterProvider: { cell in
                let ch = cell.getCharacter()
                return ch == "\u{0}" ? " " : ch
            }) ?? ""
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        return Array(lines.suffix(count))
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        isFrozen = false
        DispatchQueue.main.async { self.onTerminated?() }
    }
}

enum ProcessTree {
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh"]

    /// True when a shell runs anywhere under `pid`: Claude runs every Bash tool call and
    /// background task in one, while its MCP servers usually are not shells.
    static func runsShell(under pid: pid_t) -> Bool {
        var stack = children(of: pid)
        var seen = Set<pid_t>()
        while let current = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            if shells.contains(name(of: current)) { return true }
            stack += children(of: current)
        }
        return false
    }

    static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        // The return value is a count on some releases and a byte size on others; the zeroed
        // buffer makes that irrelevant.
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        _ = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.filter { $0 > 0 }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }
}
