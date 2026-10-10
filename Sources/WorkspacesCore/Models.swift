import Foundation

public enum NewSessionMode: String, Codable, CaseIterable, Sendable {
    /// Runs in the project folder itself.
    case folder
    /// Asks Claude Code for a fresh git worktree (`claude -w`).
    case worktree
}

/// A session the app remembers so it can be resumed with `claude --resume`.
public struct SavedSession: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var claudeSessionId: String?
    public var worktree: String?
    /// Last folder Claude reported; a worktree session must be resumed from there.
    public var cwd: String?
    /// A plain shell instead of Claude, reopened in `cwd`.
    public var terminal: Bool
    /// The account this session runs in; nil follows its workspace.
    public var account: String?

    public init(id: UUID, label: String, claudeSessionId: String? = nil, worktree: String? = nil, cwd: String? = nil,
                terminal: Bool = false, account: String? = nil) {
        self.id = id
        self.label = label
        self.claudeSessionId = claudeSessionId
        self.worktree = worktree
        self.cwd = cwd
        self.terminal = terminal
        self.account = account
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        claudeSessionId = try c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
}

/// A Claude Code login: a config folder (`CLAUDE_CONFIG_DIR`) with its own credentials.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    /// "conta1", "conta2": names the limit readings file and `WORKSPACES_CONTA`.
    public var name: String
    /// Nil is Claude Code's own folder (~/.claude), with `CLAUDE_CONFIG_DIR` left as the shell has it.
    /// Never set to ~/.claude itself: Claude Code would look for another login in the keychain.
    public var configDirectory: String?

    public var id: String { name }

    public init(name: String, configDirectory: String? = nil) {
        self.name = name
        self.configDirectory = configDirectory
    }
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var newSessionMode: NewSessionMode
    public var sessionsOnOpen: Int
    /// Appended to every `claude` command of this project, as written (e.g. `--add-dir ../api`).
    public var claudeArguments: String
    public var savedSessions: [SavedSession]

    public init(id: UUID = UUID(), name: String, path: String, newSessionMode: NewSessionMode = .folder,
                sessionsOnOpen: Int = 1, claudeArguments: String = "", savedSessions: [SavedSession] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.newSessionMode = newSessionMode
        self.sessionsOnOpen = sessionsOnOpen
        self.claudeArguments = claudeArguments
        self.savedSessions = savedSessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        newSessionMode = try c.decodeIfPresent(NewSessionMode.self, forKey: .newSessionMode) ?? .folder
        sessionsOnOpen = try c.decodeIfPresent(Int.self, forKey: .sessionsOnOpen) ?? 1
        claudeArguments = try c.decodeIfPresent(String.self, forKey: .claudeArguments) ?? ""
        savedSessions = try c.decodeIfPresent([SavedSession].self, forKey: .savedSessions) ?? []
    }
}

public struct Workspace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var projects: [Project]
    /// The account its sessions run in; nil is the app's default account.
    public var account: String?

    public init(id: UUID = UUID(), name: String, projects: [Project] = [], account: String? = nil) {
        self.id = id
        self.name = name
        self.projects = projects
        self.account = account
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var workspaces: [Workspace]
    public var notifyWhenWaiting: Bool
    public var reopenSessions: Bool
    public var disabledTools: [String]
    /// Command used to start Claude Code; resolved by the login shell, so `claude` is enough.
    public var claudeCommand: String
    /// Minutes before a quiet, hidden session is frozen (SIGSTOP); 0 turns it off.
    public var freezeAfterMinutes: Int
    /// Minutes before it is hibernated (process ended, resumed on open); 0 turns it off.
    public var hibernateAfterMinutes: Int
    /// Context (tokens) above which a session "precisa de passagem".
    public var handoffContextTokens: Int
    /// The Claude Code logins sessions can run in; never empty.
    public var accounts: [Account]
    /// The account of a workspace that names none.
    public var defaultAccount: String
    /// Accounts taken out of the app: their folders are still searched for a conversation to
    /// resume, and their names are never given to another login.
    public var retiredAccounts: [Account]

    public static let defaultDisabledTools = ["close_session"]
    /// Claude Code's own folder, named by `WORKSPACES_CONTA` when the app runs with it (the one
    /// account the app knew before accounts were listed), conta1 otherwise.
    public static var defaultAccounts: [Account] {
        [Account(name: LimitReadingStore.accountName(ProcessInfo.processInfo.environment[LimitReadingStore.accountEnvKey]))]
    }

    public init(workspaces: [Workspace] = [], notifyWhenWaiting: Bool = true, reopenSessions: Bool = true,
                disabledTools: [String] = AppConfig.defaultDisabledTools, claudeCommand: String = "claude",
                freezeAfterMinutes: Int = 2, hibernateAfterMinutes: Int = 30,
                handoffContextTokens: Int = ContextLimits.defaultHandoff,
                accounts: [Account] = AppConfig.defaultAccounts, defaultAccount: String? = nil, retiredAccounts: [Account] = []) {
        self.workspaces = workspaces
        self.notifyWhenWaiting = notifyWhenWaiting
        self.reopenSessions = reopenSessions
        self.disabledTools = disabledTools
        self.claudeCommand = claudeCommand
        self.freezeAfterMinutes = freezeAfterMinutes
        self.hibernateAfterMinutes = hibernateAfterMinutes
        self.handoffContextTokens = handoffContextTokens
        self.accounts = accounts.isEmpty ? AppConfig.defaultAccounts : accounts
        self.defaultAccount = defaultAccount ?? self.accounts[0].name
        self.retiredAccounts = retiredAccounts
    }

    public var contextLimits: ContextLimits { ContextLimits(handoff: handoffContextTokens) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        notifyWhenWaiting = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenWaiting) ?? true
        reopenSessions = try c.decodeIfPresent(Bool.self, forKey: .reopenSessions) ?? true
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? AppConfig.defaultDisabledTools
        claudeCommand = try c.decodeIfPresent(String.self, forKey: .claudeCommand) ?? "claude"
        freezeAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .freezeAfterMinutes) ?? 2
        hibernateAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .hibernateAfterMinutes) ?? 30
        handoffContextTokens = try c.decodeIfPresent(Int.self, forKey: .handoffContextTokens) ?? ContextLimits.defaultHandoff
        let accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        self.accounts = accounts.isEmpty ? AppConfig.defaultAccounts : accounts
        defaultAccount = try c.decodeIfPresent(String.self, forKey: .defaultAccount) ?? self.accounts[0].name
        retiredAccounts = try c.decodeIfPresent([Account].self, forKey: .retiredAccounts) ?? []
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case waiting, working, done, idle, ended

    public var label: String {
        switch self {
        case .waiting: return "Esperando você"
        case .working: return "Trabalhando"
        case .done: return "Concluído"
        case .idle: return "Parado"
        case .ended: return "Encerrada"
        }
    }

    /// Sort order in lists: what needs the person first.
    public var rank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        case .ended: return 4
        }
    }
}

public extension AppConfig {
    /// The project a folder belongs to: the most specific one. A project that is the home folder
    /// only claims the home folder itself, or every folder on the Mac would be in it.
    func project(containing folder: String, home: String = NSHomeDirectory()) -> (workspace: Workspace, project: Project)? {
        var best: (workspace: Workspace, project: Project, length: Int)?
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        for workspace in workspaces {
            for project in workspace.projects {
                let path = project.path.count > 1 && project.path.hasSuffix("/") ? String(project.path.dropLast()) : project.path
                let inside = folder == path || (path != home && folder.hasPrefix(path + "/"))
                if inside, path.count > (best?.length ?? -1) { best = (workspace, project, path.count) }
            }
        }
        return best.map { ($0.workspace, $0.project) }
    }
}
