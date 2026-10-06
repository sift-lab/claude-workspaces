import Foundation
import Observation
import WorkspacesCore

/// A live session: its terminal plus what the hooks and MCP calls have told us.
@Observable
final class SessionRuntime: Identifiable {
    let id: UUID
    let workspaceId: UUID
    let projectId: UUID
    /// A plain shell opened by the person, not a Claude session.
    let isTerminal: Bool
    var label: String
    var status: SessionStatus = .working
    /// Phrase from `set_status`.
    var activity: String?
    /// Text from the last Notification hook (what Claude is waiting for).
    var message: String?
    /// Set by `notify` or an incoming `send_message`; cleared when the person opens the session.
    var attention = false
    var lastChange = Date()
    /// Last time it was on screen or woken; rest is counted from the later of this and lastChange.
    @ObservationIgnored var lastSeen = Date()
    /// Increases on every launch; hooks from an older process carry an older number.
    @ObservationIgnored var launch = 0
    var claudeSessionId: String?
    /// True once a prompt was sent; before that Claude has saved nothing to resume.
    var hasConversation = false
    var worktree: String?
    var cwd: String?
    var snapshot: [String] = []
    /// Frozen or hibernated while nobody looks at it; opening it wakes it.
    var sleep: SleepState = .awake
    /// Claude exited and the person opened a plain shell in its place; never put to sleep.
    var shellOnly = false
    /// Memory and CPU of Claude and everything under it; refreshed while a window is open.
    var usage: Usage = .zero
    /// What the session held when it went to hibernate: what hibernating gave back.
    var freedByHibernation: UInt64 = 0
    /// The conversation the 500 mil alarm already went off for.
    @ObservationIgnored var alarmedConversation: String?

    @ObservationIgnored let host = TerminalHost()

    init(id: UUID, workspaceId: UUID, projectId: UUID, label: String, worktree: String?, isTerminal: Bool = false) {
        self.id = id
        self.workspaceId = workspaceId
        self.projectId = projectId
        self.isTerminal = isTerminal
        self.label = label
        self.worktree = worktree
    }

    var needsYou: Bool { status == .waiting || attention }

    /// Shown under the name: why it waits, or what it is doing.
    var detail: String {
        if sleep != .awake { return sleep == .frozen ? "Congelada, volta na hora ao abrir" : "Hibernando, retoma ao abrir" }
        if isTerminal { return status == .ended ? "Terminal encerrado" : "Terminal" }
        if status == .waiting, let message { return message }
        if status == .working, let activity { return activity }
        return status.label
    }

    var shortId: String { String(id.uuidString.lowercased().prefix(8)) }
}

