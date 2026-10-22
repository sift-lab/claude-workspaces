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
    /// Phrase from `set_status`, or what the last tool did (PostToolUse).
    private(set) var activity: String?
    /// When `activity` was last set.
    private(set) var activityAt: Date?
    /// When the session last set its phrase with `set_status`; for a while the tools do not replace it.
    @ObservationIgnored var statusPhraseAt: Date?
    /// What the current task is about; nil until its first prompt and again after a /clear.
    var title: SessionTitle?
    /// Tab names of the tasks before a /clear, newest first.
    var titleHistory: [String] = []
    /// The prompt being named right now; shown in place of the title meanwhile.
    var titlePending: String?
    /// The first prompt of the conversation and the latest ones, for naming it again.
    @ObservationIgnored var prompts: [String] = []
    /// Increases with every naming, so an answer for a task that was cleared is dropped.
    @ObservationIgnored var titleRequest = 0
    /// The branch at the last look, to tell a name that follows the branch from one given by hand.
    @ObservationIgnored var branchSeen: String?
    /// Text from the last Notification hook (what Claude is waiting for).
    var message: String?
    /// Set by `notify` or an incoming `send_message`; cleared when the person opens the session.
    var attention = false
    var lastChange = Date()
    /// Last time it was on screen or woken; rest is counted from the later of this and lastChange.
    @ObservationIgnored var lastSeen = Date()
    /// Increases on every launch; hooks from an older process carry an older number.
    @ObservationIgnored var launch = 0
    /// The account the running Claude was started in; nil before the first launch.
    @ObservationIgnored var account: String?
    /// Which conversation Claude is in, and which one `claude --resume` opens; fed by every hook.
    var conversation = ConversationTracker(saved: nil)
    var claudeSessionId: String? { conversation.current }
    /// True once the conversation has a message; before that Claude has nothing to resume.
    var hasConversation: Bool { conversation.resumable != nil }
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
    /// The conversation's .jsonl, from the hooks.
    @ObservationIgnored var transcriptPath: String?
    /// Context at the last "escreva a Passagem" reminder, per conversation.
    @ObservationIgnored var handoffReminder: (conversation: String, tokens: Int?)?
    /// The conversation the 500 mil alarm already went off for.
    @ObservationIgnored var alarmedConversation: String?
    /// Where a recycle (recycle_self or recycle_session) stands.
    var recycle: RecycleProgress?

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

    func setActivity(_ phrase: String?) {
        activity = phrase
        activityAt = phrase == nil ? nil : Date()
    }

    /// Remembers a prompt: the first one of the conversation stays, then the latest three.
    func remember(prompt: String) {
        prompts.append(prompt)
        if prompts.count > 4 { prompts.remove(at: 1) }
    }

    /// Shown under the name: why it waits, or what it is doing.
    var detail: String {
        if sleep != .awake { return sleep == .frozen ? "Congelada, volta na hora ao abrir" : "Hibernando, retoma ao abrir" }
        if isTerminal { return status == .ended ? "Terminal encerrado" : "Terminal" }
        if let recycle, recycle.inProgress || recycle.isFailure { return recycle.text }
        if status == .waiting, let message { return message }
        if status == .working, let activity { return activity }
        return status.label
    }

    var shortId: String { String(id.uuidString.lowercased().prefix(8)) }
}

/// A recycle as the sidebar and list_sessions tell it.
extension RecycleProgress {
    var inProgress: Bool {
        switch self {
        case .scheduled, .waking, .clearing, .delayed, .resuming, .waitingTurn: return true
        case .done, .failed: return false
        }
    }

    var isFailure: Bool { if case .failed = self { return true } else { return false } }

    var text: String {
        switch self {
        case .scheduled: return "Reciclagem agendada para o fim do turno"
        case .waking: return "Reciclagem: acordando a sessão"
        case .clearing: return "Reciclagem: /clear enviado, esperando a conversa nova"
        case .delayed: return "Reciclagem: o /clear não respondeu, esperando"
        case .resuming: return "Reciclagem: mensagem de retomada enviada"
        case .waitingTurn: return "Reciclagem: a retomada espera o turno em curso"
        case .done(let date): return "Reciclada às \(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
        case .failed(let reason): return "Reciclagem não feita: \(reason)"
        }
    }
}
