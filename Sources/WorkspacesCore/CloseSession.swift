import Foundation

// close_session ends a session that finished its work. Never one in the middle of a turn, never
// one with changes not committed, and the conversation's transcript is logged before it closes.

// MARK: The worktree

public enum GitState: Equatable, Sendable {
    case clean
    /// `git status --porcelain` lines: tracked and modified, or untracked and not ignored.
    case dirty([String])
    case notRepository
    case failed(String)

    /// git status of the worktree around `cwd`, read only (no optional locks).
    public static func read(cwd: String, git: String = "/usr/bin/git") -> GitState {
        let top = GitProbe.run(git, ["-C", cwd, "rev-parse", "--show-toplevel"])
        guard top.status == 0 else {
            let notRepo = top.error.lowercased().contains("not a git repository")
            return notRepo ? .notRepository : .failed(top.error.isEmpty ? "git rev-parse saiu com \(top.status)" : top.error)
        }
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = GitProbe.run(git, ["-C", root, "status", "--porcelain"])
        guard status.status == 0 else {
            return .failed(status.error.isEmpty ? "git status saiu com \(status.status)" : status.error)
        }
        let blocking = GitProbe.blocking(status.output)
        return blocking.isEmpty ? .clean : .dirty(blocking)
    }
}

public enum GitProbe {
    /// Porcelain lines that keep a session from being closed: everything but ignored files.
    public static func blocking(_ porcelain: String) -> [String] {
        porcelain.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("!!") }
    }

    static func run(_ git: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", "\(error)") }
        // Read before waiting, so a large output never blocks on a full pipe.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self),
                String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: The gate

public enum CloseRefusal: Error, Equatable, Sendable {
    case midTurn(SessionStatus)
    case dirtyTree([String])
    case gitFailed(String)

    /// Never while the session works or waits, never with uncommitted changes. A folder outside
    /// git has nothing to commit, so it may close.
    public static func check(status: SessionStatus, git: GitState) -> CloseRefusal? {
        if status == .working || status == .waiting { return .midTurn(status) }
        switch git {
        case .clean, .notRepository: return nil
        case .dirty(let lines): return .dirtyTree(lines)
        case .failed(let error): return .gitFailed(error)
        }
    }

    public var message: String {
        switch self {
        case .midTurn(let status):
            return "Recusado: a sessão está no meio de um turno (\(status.label.lowercased())). Chame de novo quando ela estiver parada."
        case .dirtyTree(let lines):
            let shown = lines.prefix(8).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            let more = lines.count > 8 ? " e mais \(lines.count - 8)" : ""
            return "Recusado: a árvore tem mudanças sem commit (\(shown)\(more)). Faça commit, ou ponha no ignore o que for descartável, e chame de novo."
        case .gitFailed(let error):
            return "Recusado: o git status falhou (\(error)), então não dá para conferir que nada ficou sem commit."
        }
    }
}

// MARK: The log

/// One line of closes.jsonl. Append only: nothing in it, or in the transcripts it points to, is ever deleted.
public struct CloseRecord: Codable, Equatable, Sendable {
    public var time: Date
    /// The app's id for the session.
    public var session: String
    public var label: String?
    public var cwd: String?
    public var conversation: String?
    /// The conversation's .jsonl, where it stays after the close.
    public var transcript: String?
    public var contextTokens: Int?

    public init(time: Date = Date(), session: String, label: String? = nil, cwd: String? = nil,
                conversation: String? = nil, transcript: String? = nil, contextTokens: Int? = nil) {
        self.time = time
        self.session = session
        self.label = label
        self.cwd = cwd
        self.conversation = conversation
        self.transcript = transcript
        self.contextTokens = contextTokens
    }
}

public struct CloseLog: Sendable {
    public let url: URL

    public init(url: URL = AppPaths.closeLogFile) {
        self.url = url
    }

    /// Appends one line and flushes it to disk before returning. Throws rather than lose it.
    public func append(_ record: CloseRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Every record that parses; a broken line is skipped, never fatal.
    public func records() -> [CloseRecord] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(CloseRecord.self, from: Data($0)) }
    }
}
