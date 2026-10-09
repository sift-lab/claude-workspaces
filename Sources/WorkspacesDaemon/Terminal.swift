import Foundation
import WorkspacesCore

/// What the daemon needs from the terminal a session runs in. tmux in production, a fake in tests.
public protocol SessionTerminal: AnyObject {
    /// Starts `argv` in a new terminal named `name`, in `folder`, with `environment` added.
    func start(name: String, folder: String, environment: [String: String], argv: [String]) throws
    func isRunning(_ name: String) -> Bool
    /// Pastes text as one bracketed paste (newlines stay literal), without Enter.
    func paste(_ name: String, _ text: String)
    /// Types text key by key, without Enter.
    func type(_ name: String, _ text: String)
    func pressEnter(_ name: String)
    /// Sends one named key ("Down", "Escape").
    func press(_ name: String, key: String)
    /// The visible screen, with attributes (`capture-pane -p -e`).
    func capture(_ name: String) -> String
    /// The process running in the terminal (Claude), if any.
    func pid(_ name: String) -> Int32?
    func kill(_ name: String)
}

public struct TerminalError: Error, CustomStringConvertible {
    public let description: String
}

/// tmux on the default server, so `tmux attach -t ws-<id>` shows a session to whoever logs in.
public final class TmuxTerminal: SessionTerminal {
    let tmux: String
    let width: Int
    let height: Int
    /// Longest a tmux command may take. They answer in milliseconds; past this the client is hung, and every
    /// request to the daemon waits behind it on the single queue.
    let timeout: TimeInterval
    /// Where each command's output goes for a moment (a capture is the whole Claude screen).
    let folder: URL

    public init(tmux: String = TmuxTerminal.locate(), width: Int = 200, height: Int = 50, timeout: TimeInterval = 5,
                folder: URL = TmuxTerminal.privateFolder()) {
        self.tmux = tmux
        self.width = width
        self.height = height
        self.timeout = timeout
        self.folder = folder
    }

    /// A folder only this user can enter: XDG_RUNTIME_DIR (0700, in memory) under systemd, else
    /// `workspacesd-<uid>` in the temporary directory. Never the shared /tmp itself: there another user can open
    /// an output file in the moment before its 0600 takes effect, and read the screen written to it afterwards.
    public static func privateFolder() -> URL {
        if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], isPrivate(runtime) {
            return URL(fileURLWithPath: runtime)
        }
        let own = FileManager.default.temporaryDirectory.appendingPathComponent("workspacesd-\(getuid())")
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        // Ours from an earlier run with looser permissions: closed again, or every command would be refused.
        // Someone else's stays as it is, and `isPrivate` refuses it.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: own.path),
           attributes[.type] as? FileAttributeType == .typeDirectory,
           (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: own.path)
        }
        return own
    }

    /// A real directory (not a link), ours, closed to group and others. Checked on every command, so a folder
    /// someone else made under the same name is refused instead of used.
    static func isPrivate(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else { return false }
        return mode & 0o077 == 0
    }

    public static func locate() -> String {
        ["/usr/bin/tmux", "/usr/local/bin/tmux", "/opt/homebrew/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/tmux"
    }

    /// "=name": the exact session, never a prefix of another one.
    private func target(_ name: String) -> String { "=\(name):" }

    /// The status of a command that did not end within `timeout`. Not "no such session": the session may be fine.
    public static let timedOut: Int32 = -2

    /// Runs one tmux command on the daemon's queue, and never waits past `timeout`.
    ///
    /// On 09/10 (11h54 and 15h13) the daemon hung for good inside `waitUntilExit`: the client had exited, sat
    /// unreaped as `[tmux: client] <defunct>`, and Foundation never noticed. So the wait here also reaps the child
    /// itself, and the output goes to private files, not pipes, so no process left behind can hold a read open.
    @discardableResult
    func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: String, error: String) {
        guard Self.isPrivate(folder.path) else {
            return (-1, "", "a pasta da saída do tmux não é só deste usuário: \(folder.path)")
        }
        let tag = UUID().uuidString.prefix(8)
        let outURL = folder.appendingPathComponent("workspacesd-tmux-\(tag).out")
        let errURL = folder.appendingPathComponent("workspacesd-tmux-\(tag).err")
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let privateFile: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: privateFile),
              FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: privateFile),
              let out = try? FileHandle(forWritingTo: outURL),
              let err = try? FileHandle(forWritingTo: errURL) else {
            return (-1, "", "não consegui criar a saída do tmux em \(folder.path)")
        }
        defer {
            try? out.close()
            try? err.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "\(error)") }
        let pid = process.processIdentifier
        if let inPipe, let input {
            // Off the queue, so a client that never reads cannot hold the wait below; and the throwing write, so
            // one that already left (EPIPE) cannot take the daemon down.
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        guard let status = waitForExit(process, pid: pid) else {
            // Only while the child is still ours: once Foundation has collected it, the pid may be someone else's.
            if process.isRunning { signalProcess(pid, SIGKILL) }
            reap(pid)
            return (Self.timedOut, "", "tmux \(arguments.first ?? "") não terminou em \(Int(timeout)) s")
        }
        let output = (try? Data(contentsOf: outURL)) ?? Data()
        let error = (try? Data(contentsOf: errURL)) ?? Data()
        return (status, String(decoding: output, as: UTF8.self),
                String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// After the SIGKILL: collects the child, so it does not stay `<defunct>` if Foundation misses this exit too.
    /// Bounded, never a blocking `waitpid`, so a child that will not die cannot hold the queue.
    private func reap(_ pid: Int32) {
        var status: Int32 = 0
        for _ in 0..<200 {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid || reaped == -1 { return }  // -1: Foundation already collected it
            usleep(5_000)
        }
    }

    /// The exit status, from Foundation or from reaping the child here; nil past the timeout.
    private func waitForExit(_ process: Process, pid: Int32) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return process.terminationStatus }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                // WIFEXITED and WEXITSTATUS are C macros Swift does not import.
                return status & 0x7f == 0 ? (status >> 8) & 0xff : -1
            }
            usleep(5_000)
        }
        return nil
    }

    public func start(name: String, folder: String, environment: [String: String], argv: [String]) throws {
        var arguments = ["new-session", "-d", "-s", name, "-x", String(width), "-y", String(height), "-c", folder]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(key)=\(value)"] }
        // More than one word: tmux runs them directly, without a shell, so nothing needs quoting.
        arguments += argv
        let result = run(arguments)
        guard result.status == 0 else { throw TerminalError(description: "tmux new-session falhou: \(result.error)") }
        // Keep the screen size fixed whoever attaches, so the capture always has the same shape.
        run(["set-option", "-t", target(name), "window-size", "manual"])
    }

    public func isRunning(_ name: String) -> Bool {
        // A hung tmux says nothing about the session. Taken as gone, it would hibernate a live session, or launch
        // a second one over it.
        let status = run(["has-session", "-t", "=\(name)"]).status
        return status == 0 || status == Self.timedOut
    }

    public func paste(_ name: String, _ text: String) {
        let buffer = "ws-\(UUID().uuidString.prefix(8))"
        guard run(["load-buffer", "-b", buffer, "-"], input: Data(text.utf8)).status == 0 else { return }
        // -p: bracketed paste when the program asked for it (Claude Code does); -d: drop the buffer.
        run(["paste-buffer", "-p", "-d", "-b", buffer, "-t", target(name)])
    }

    public func type(_ name: String, _ text: String) {
        run(["send-keys", "-t", target(name), "-l", text])
    }

    public func pressEnter(_ name: String) {
        run(["send-keys", "-t", target(name), "Enter"])
    }

    public func press(_ name: String, key: String) {
        run(["send-keys", "-t", target(name), key])
    }

    public func capture(_ name: String) -> String {
        let result = run(["capture-pane", "-p", "-e", "-t", target(name)])
        return result.status == 0 ? result.output : ""
    }

    public func pid(_ name: String) -> Int32? {
        let result = run(["display-message", "-p", "-t", target(name), "#{pane_pid}"])
        return result.status == 0 ? Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    public func kill(_ name: String) {
        run(["kill-session", "-t", "=\(name)"])
    }
}

/// The C `kill`, which `TmuxTerminal.kill(_:)` hides inside the class.
private func signalProcess(_ pid: Int32, _ signal: Int32) {
    _ = kill(pid, signal)
}

/// Processes under Claude, read from /proc: a shell there means a command is running.
enum ProcessTree {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    static func runsShell(under pid: Int32) -> Bool {
        children(of: pid).contains { shells.contains(command($0) ?? "") }
    }

    static func children(of pid: Int32) -> [Int32] {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/task/\(pid)/children", encoding: .utf8) else { return [] }
        return text.split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func command(_ pid: Int32) -> String? {
        (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
