import Foundation
import WorkspacesCore

/// Runs work later on the daemon's queue. Tests move the time by hand.
public protocol Scheduler: AnyObject {
    var now: Date { get }
    /// Returns a token that cancels the work.
    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork
}

public final class ScheduledWork {
    private(set) var cancelled = false
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void = {}) {
        self.onCancel = onCancel
    }

    public func cancel() {
        cancelled = true
        onCancel()
    }
}

public final class QueueScheduler: Scheduler {
    let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public var now: Date { Date() }

    @discardableResult
    public func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return ScheduledWork { item.cancel() }
    }
}

/// What the daemon keeps about a session across restarts, in `server-sessions.json`.
public struct ServerSessionRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var workspaceId: UUID
    public var projectId: UUID
    /// Where Claude runs now; for a worktree session, the worktree.
    public var cwd: String?
    /// Name of the worktree Claude Code made for it (`--worktree`), if any.
    public var worktree: String?
    public var account: String
    public var model: String?
    /// The conversation to reopen with `--resume`.
    public var claudeSessionId: String?
    public var launch: Int
    public var hibernated: Bool

    public init(id: UUID = UUID(), label: String, workspaceId: UUID, projectId: UUID, cwd: String? = nil,
                worktree: String? = nil, account: String, model: String? = nil, claudeSessionId: String? = nil,
                launch: Int = 0, hibernated: Bool = false) {
        self.id = id
        self.label = label
        self.workspaceId = workspaceId
        self.projectId = projectId
        self.cwd = cwd
        self.worktree = worktree
        self.account = account
        self.model = model
        self.claudeSessionId = claudeSessionId
        self.launch = launch
        self.hibernated = hibernated
    }
}

/// Where a recycle is, as list_sessions shows it.
extension RecycleProgress {
    var text: String {
        switch self {
        case .scheduled: return "reciclagem agendada para o fim do turno"
        case .waking: return "acordando para reciclar"
        case .clearing: return "reciclando: /clear enviado"
        case .delayed: return "reciclando: o /clear não respondeu, esperando"
        case .resuming: return "reciclando: retomada enviada"
        case .waitingTurn: return "reciclando: retomada espera o turno em curso"
        case .done: return "reciclada"
        case .failed(let reason): return "reciclagem falhou: \(reason)"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A session while the daemon runs.
final class ServerSession {
    var record: ServerSessionRecord
    var status: SessionStatus = .idle
    var activity: String?
    var message: String?
    var attention = false
    var lastChange: Date
    var conversation: ConversationTracker
    var transcriptPath: String?
    /// Exact context from the status line.
    var contextTokens: Int?
    var contextSize: Int?
    var recycle: RecycleProgress?
    /// A recado for a hibernated session, typed once it is back.
    var pendingPaste: String?
    /// The account hit its limit in this session's last turn: "continue" is sent after this moment.
    var rateLimitedUntil: Date?
    var handoffReminder: (conversation: String, tokens: Int?)?
    /// When the session last started, to answer Claude Code's first screens (folder trust).
    var startedAt: Date?

    init(record: ServerSessionRecord, now: Date) {
        self.record = record
        lastChange = now
        conversation = ConversationTracker(saved: record.claudeSessionId)
    }

    var id: UUID { record.id }
    var label: String { record.label }
    var shortId: String { String(id.uuidString.lowercased().prefix(8)) }
    /// The tmux session.
    var terminalName: String { "ws-\(shortId)" }
    var hibernated: Bool { record.hibernated }
    var claudeSessionId: String? { conversation.current }
    var hasConversation: Bool { conversation.resumable != nil }
}

/// The server's own settings, in `server.json` next to `workspaces.json`.
public struct ServerConfig: Codable, Equatable, Sendable {
    /// Config folder (`CLAUDE_CONFIG_DIR`) of each account; a missing one is `~/.claude-<account>`.
    public var accounts: [String: String]
    public var defaultAccount: String
    /// ntfy topic for `notify`; nil turns notifications into log lines only.
    public var ntfyTopic: String?
    public var ntfyServer: String
    /// Folders under these may be trusted on Claude Code's first screen without a person.
    public var trustedRoots: [String]

    public init(accounts: [String: String] = [:], defaultAccount: String = LimitReadingStore.defaultAccount,
                ntfyTopic: String? = nil, ntfyServer: String = "https://ntfy.sh", trustedRoots: [String]? = nil) {
        self.accounts = accounts
        self.defaultAccount = defaultAccount
        self.ntfyTopic = ntfyTopic
        self.ntfyServer = ntfyServer
        let home = NSHomeDirectory()
        self.trustedRoots = trustedRoots ?? ["\(home)/src", "\(home)/obra"]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfig()
        accounts = try c.decodeIfPresent([String: String].self, forKey: .accounts) ?? defaults.accounts
        defaultAccount = try c.decodeIfPresent(String.self, forKey: .defaultAccount) ?? defaults.defaultAccount
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic)
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? defaults.ntfyServer
        trustedRoots = try c.decodeIfPresent([String].self, forKey: .trustedRoots) ?? defaults.trustedRoots
    }

    public func configDirectory(account: String, home: String = NSHomeDirectory()) -> String {
        accounts[account] ?? "\(home)/.claude-\(account)"
    }

    /// True when `folder` is one of the trusted roots or inside one.
    public func trusts(_ folder: String) -> Bool {
        let path = URL(fileURLWithPath: folder).standardizedFileURL.path
        return trustedRoots.contains { root in
            let root = URL(fileURLWithPath: root).standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}
