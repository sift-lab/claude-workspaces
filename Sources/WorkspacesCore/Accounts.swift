import Foundation

public extension Account {
    static let configEnvKey = "CLAUDE_CONFIG_DIR"

    /// The folder with `~` expanded, or nil for Claude Code's own.
    var expandedDirectory: String? {
        configDirectory.map { ($0 as NSString).expandingTildeInPath }
    }

    /// The environment a session of this account starts with: the folder in `CLAUDE_CONFIG_DIR`
    /// (the shell's own value for the default folder) and the name in `WORKSPACES_CONTA`.
    func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        if let folder = expandedDirectory { env[Self.configEnvKey] = folder }
        env[LimitReadingStore.accountEnvKey] = name
        return env
    }

    /// The folder Claude Code reads for this account.
    func folder(environment: [String: String], home: String = NSHomeDirectory()) -> String {
        expandedDirectory ?? environment[Self.configEnvKey] ?? "\(home)/.claude"
    }

    /// Where Claude Code keeps the login (`oauthAccount`): ~/.claude.json for its own folder,
    /// `.claude.json` inside any folder given in `CLAUDE_CONFIG_DIR`.
    func stateFile(environment: [String: String], home: String = NSHomeDirectory()) -> String {
        if expandedDirectory == nil, environment[Self.configEnvKey] == nil { return "\(home)/.claude.json" }
        return folder(environment: environment, home: home) + "/.claude.json"
    }

    /// The conversations (`--resume` reads them here).
    func projectsDirectory(environment: [String: String], home: String = NSHomeDirectory()) -> String {
        folder(environment: environment, home: home) + "/projects"
    }
}

public extension AppConfig {
    func account(named name: String?) -> Account? {
        guard let name else { return nil }
        return accounts.first { $0.name == name }
    }

    /// The default account, or the first one when the default was removed.
    var mainAccount: Account {
        account(named: defaultAccount) ?? accounts.first ?? Account(name: LimitReadingStore.defaultAccount)
    }

    /// The account a workspace's sessions run in when they name none.
    func account(of workspace: Workspace?) -> Account {
        account(named: workspace?.account) ?? mainAccount
    }

    /// The session's own account, or its workspace's. A name no longer in the list is skipped.
    func account(of workspace: Workspace?, session: SavedSession?) -> Account {
        account(named: session?.account) ?? account(of: workspace)
    }

    /// "conta2", "conta3": the first name no account uses or used. A name used before would bring
    /// back another login's readings; `taken` adds the names that have readings on disk.
    func nextAccountName(taken: Set<String> = []) -> String {
        let used = Set(accounts.map(\.name) + retiredAccounts.map(\.name)).union(taken)
        var n = 1
        while used.contains("conta\(n)") { n += 1 }
        return "conta\(n)"
    }

    /// Every projects folder a conversation may have been kept in: Claude Code's own, each
    /// account's, and those of the accounts taken out of the app.
    func projectsDirectories(environment: [String: String], home: String = NSHomeDirectory()) -> [String] {
        var seen = Set<String>()
        let all = ["\(home)/.claude/projects"] + (accounts + retiredAccounts).map { $0.projectsDirectory(environment: environment, home: home) }
        return all.filter { seen.insert(AccountFolder.resolved($0)).inserted }
    }
}

/// Who is logged in to an account, read from its `.claude.json`.
public enum AccountLogin {
    public static func email(stateFile: String) -> String? {
        guard let data = FileManager.default.contents(atPath: stateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = object["oauthAccount"] as? [String: Any],
              let email = login["emailAddress"] as? String, !email.isEmpty else { return nil }
        return email
    }
}

public enum AccountFolder {
    /// What a new account shares with Claude Code's own folder: settings, instructions, skills,
    /// plugins and the conversations. The login (`.claude.json`) stays its own.
    public static let shared = ["CLAUDE.md", "settings.json", "settings.local.json", "skills", "plugins", "agents",
                                "commands", "output-styles", "hooks", "projects", "file-history", "history.jsonl",
                                "paste-cache", "plans", "session-env", "tasks"]

    /// True when the folder does not exist or holds nothing but hidden Finder files.
    public static func isEmpty(_ path: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return true }
        return items.allSatisfy { $0 == ".DS_Store" }
    }

    /// Creates the folder and links into it each shared item `source` has. Only for an empty folder:
    /// nothing that exists is replaced. Returns the items linked.
    @discardableResult
    public static func prepare(_ path: String, sharingWith source: String) throws -> [String] {
        guard isEmpty(path) else { return [] }
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        var linked: [String] = []
        for item in shared {
            let from = source + "/" + item, to = path + "/" + item
            guard fm.fileExists(atPath: from), (try? fm.destinationOfSymbolicLink(atPath: to)) == nil,
                  !fm.fileExists(atPath: to) else { continue }
            try fm.createSymbolicLink(atPath: to, withDestinationPath: from)
            linked.append(item)
        }
        return linked
    }

    /// The same folder, symlinks resolved, so two accounts sharing `projects` compare equal.
    public static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// A conversation moving to an account that keeps its conversations elsewhere: `claude --resume`
/// only finds it in the account's own projects folder, so its freshest transcript is copied there.
public enum TranscriptSync {
    public struct Copy: Equatable, Sendable {
        public var from: String
        public var to: String
    }

    /// What has to be copied for `target` to resume the conversation as it was last written, in
    /// whichever folder: nil when `target` already has that version, or no folder has the conversation.
    public static func needed(_ id: String, target: String, folders: [String]) -> Copy? {
        guard let best = freshest(id, in: [target] + folders) else { return nil }
        let relative = String(AccountFolder.resolved(best.file).dropFirst(AccountFolder.resolved(best.projects).count + 1))
        let destination = target + "/" + relative
        // A folder shared with the source (a link) already shows the same file.
        if AccountFolder.resolved(destination) == AccountFolder.resolved(best.file) { return nil }
        if let here = stamp(destination), let there = stamp(best.file), here == there { return nil }
        return Copy(from: best.file, to: destination)
    }

    /// Copies the transcript and what its folder holds (agents, tool results). An older copy at the
    /// destination is replaced only when it is the start of the new one, as a conversation only
    /// grows; one that went another way is kept beside it, renamed `.antes-<moment>`. Nothing is deleted.
    public static func apply(_ copy: Copy, now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (copy.to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try place(copy.from, at: copy.to, now: now)
        let folder = (copy.from as NSString).deletingPathExtension, destination = (copy.to as NSString).deletingPathExtension
        guard let walker = fm.enumerator(atPath: folder) else { return }
        for case let item as String in walker {
            let from = folder + "/" + item, to = destination + "/" + item
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: from, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if let here = stamp(to), let there = stamp(from), here.modified >= there.modified { continue }
            try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try place(from, at: to, now: now)
        }
    }

    /// The newest copy of the conversation among the projects folders, by the time it was written.
    static func freshest(_ id: String, in folders: [String]) -> (file: String, projects: String)? {
        var best: (file: String, projects: String, stamp: Stamp)?
        for folder in folders {
            guard let file = TranscriptLocator.find(conversation: id, hint: nil, root: URL(fileURLWithPath: folder)),
                  let stamp = stamp(file) else { continue }
            if best.map({ stamp > $0.stamp }) ?? true { best = (file, folder, stamp) }
        }
        return best.map { ($0.file, $0.projects) }
    }

    struct Stamp: Equatable, Comparable {
        var modified: Date
        var size: UInt64
        static func < (a: Stamp, b: Stamp) -> Bool { (a.modified, a.size) < (b.modified, b.size) }
    }

    static func stamp(_ path: String) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        return Stamp(modified: modified, size: size)
    }

    /// Copies next to the destination first, so a copy that fails halfway never replaces anything.
    private static func place(_ from: String, at to: String, now: Date) throws {
        let fm = FileManager.default
        let staging = to + ".copiando"
        try? fm.removeItem(atPath: staging)
        try fm.copyItem(atPath: from, toPath: staging)
        if fm.fileExists(atPath: to) {
            if !isPrefix(to, of: from) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                try fm.moveItem(atPath: to, toPath: to + ".antes-" + formatter.string(from: now))
            } else {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: to), withItemAt: URL(fileURLWithPath: staging))
                return
            }
        }
        try fm.moveItem(atPath: staging, toPath: to)
    }

    /// True when the file at `a` is the beginning of the one at `b`.
    static func isPrefix(_ a: String, of b: String) -> Bool {
        guard let first = FileHandle(forReadingAtPath: a), let second = FileHandle(forReadingAtPath: b) else { return false }
        defer { try? first.close(); try? second.close() }
        while true {
            let chunk = (try? first.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { return true }
            guard let other = try? second.read(upToCount: chunk.count), other == chunk else { return false }
        }
    }
}

/// Which account each conversation ran in, and since when. A conversation moved to another
/// account keeps what it spent before in the first one. Kept on disk, so a restart keeps it too.
public struct ConversationAccounts: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        public var since: Date
        public var account: String
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var spans: [Span]
        public var seen: Date
    }

    public var conversations: [String: Entry]

    public init(conversations: [String: Entry] = [:]) {
        self.conversations = conversations
    }

    /// Returns true when what is kept changed: a conversation not seen before, or another account.
    @discardableResult
    public mutating func record(_ conversation: String, account: String, at date: Date = Date()) -> Bool {
        guard var entry = conversations[conversation] else {
            conversations[conversation] = Entry(spans: [Span(since: date, account: account)], seen: date)
            return true
        }
        entry.seen = max(entry.seen, date)
        let moved = entry.spans.last?.account != account
        if moved { entry.spans.append(Span(since: date, account: account)) }
        conversations[conversation] = entry
        return moved
    }

    /// The account it ran in at `date`; before the first span, the first one.
    public func account(of conversation: String, at date: Date) -> String? {
        guard let spans = conversations[conversation]?.spans, let first = spans.first else { return nil }
        return spans.last { $0.since <= date }?.account ?? first.account
    }

    /// When the conversation starts and stops counting for `account`, for the ledger's sums.
    public func changes(_ conversation: String, for account: String) -> [LedgerFilter.Change]? {
        conversations[conversation]?.spans.map { LedgerFilter.Change(from: $0.since.timeIntervalSince1970, counts: $0.account == account) }
    }

    /// Forgets conversations not seen since `date`.
    public mutating func prune(before date: Date) {
        conversations = conversations.filter { $0.value.seen >= date }
    }
}
