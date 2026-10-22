import Foundation

/// A Claude Code login the sessions run in. Each one has its own config folder, where Claude Code
/// keeps the login, so moving the sessions to another account is a relaunch, never a /login.
public struct ClaudeAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Also names the account's limit readings and `WORKSPACES_CONTA` ("conta1").
    public var name: String
    /// `CLAUDE_CONFIG_DIR`; empty is Claude Code's own default, ~/.claude.
    public var configDir: String

    public static let configDirEnvKey = "CLAUDE_CONFIG_DIR"

    public init(id: UUID = UUID(), name: String, configDir: String = "") {
        self.id = id
        self.name = name
        self.configDir = configDir
    }

    /// The folder with `~` expanded; nil for Claude Code's default.
    public var configPath: String? {
        let folder = configDir.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else { return nil }
        if folder == "~" { return NSHomeDirectory() }
        if folder.hasPrefix("~/") { return NSHomeDirectory() + String(folder.dropFirst()) }
        return folder
    }

    /// `base` with this account's config folder and name, for a Claude process and what it starts.
    public func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        env[Self.configDirEnvKey] = configPath
        env[LimitReadingStore.accountEnvKey] = name
        return env
    }

    /// Where Claude Code keeps this account's conversations. `--resume` only finds a conversation in
    /// the folder of the account that runs it, so accounts that share sessions must share this one.
    public var conversationsPath: String {
        let root = configPath ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: root).appendingPathComponent("projects").resolvingSymlinksInPath().path
    }
}

/// When the account the sessions run in is spent, and where to move them.
public enum AccountSwitch {
    public enum Advice: Equatable, Sendable {
        /// This account is free (or has no reading yet).
        case switchTo(String)
        /// Every other account is spent too; this one frees up first.
        case waitFor(String, until: Date)
    }

    /// A rate limit error counts for this long, for when the meter has not caught up.
    public static let failureWindow: TimeInterval = 10 * 60

    /// When the account frees up, if its 5 h window or its week reads 100% and has not reset.
    public static func spentUntil(_ readings: LimitReadings, now: Date) -> Date? {
        [readings.fiveHour.last, readings.sevenDay.last]
            .compactMap { $0 }
            .filter { $0.resetsAt > now && $0.percent >= 99.5 }
            .map(\.resetsAt)
            .max()
    }

    /// Nil while `active` still has room. `failedAt` is the last rate limit error a session of each
    /// account stopped on.
    public static func advice(active: String, accounts: [String], readings: [String: LimitReadings],
                              failedAt: [String: Date], now: Date) -> Advice? {
        func spent(_ name: String) -> Bool {
            spentUntil(readings[name] ?? LimitReadings(), now: now) != nil
                || failedAt[name].map { now.timeIntervalSince($0) < failureWindow } == true
        }
        guard spent(active) else { return nil }
        let others = accounts.filter { $0 != active }
        if let free = others.first(where: { !spent($0) }) { return .switchTo(free) }
        let soonest = others.compactMap { name in
            spentUntil(readings[name] ?? LimitReadings(), now: now).map { (name, $0) }
        }.min { $0.1 < $1.1 }
        return soonest.map { .waitFor($0.0, until: $0.1) }
    }
}
