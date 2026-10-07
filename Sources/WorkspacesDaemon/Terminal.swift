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

    public init(tmux: String = TmuxTerminal.locate(), width: Int = 200, height: Int = 50) {
        self.tmux = tmux
        self.width = width
        self.height = height
    }

    public static func locate() -> String {
        ["/usr/bin/tmux", "/usr/local/bin/tmux", "/opt/homebrew/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/tmux"
    }

    /// "=name": the exact session, never a prefix of another one.
    private func target(_ name: String) -> String { "=\(name):" }

    @discardableResult
    func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "\(error)") }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self),
                String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
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
        run(["has-session", "-t", "=\(name)"]).status == 0
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
