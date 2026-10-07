import Foundation

/// Where the app keeps its files. Everything lives under Application Support.
public enum AppPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WORKSPACES_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Workspaces", isDirectory: true)
    }

    public static var configFile: URL { supportDirectory.appendingPathComponent("workspaces.json") }
    /// Unix socket paths are capped at 104 bytes; a long support path falls back to a short one in /tmp.
    public static var socketFile: URL {
        let preferred = supportDirectory.appendingPathComponent("ipc.sock")
        if preferred.path.utf8.count < 100 { return preferred }
        var hash: UInt64 = 1469598103934665603
        for byte in supportDirectory.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return URL(fileURLWithPath: "/tmp/workspaces-\(getuid())-\(String(hash, radix: 36)).sock")
    }
    public static var claudeSettingsFile: URL { supportDirectory.appendingPathComponent("claude-settings.json") }
    public static var mcpConfigFile: URL { supportDirectory.appendingPathComponent("claude-mcp.json") }
    /// Every recycle and close_session, one JSON line each, never rewritten.
    public static var recycleLogFile: URL { supportDirectory.appendingPathComponent("recycles.jsonl") }
    /// Every change of the conversation a session resumes, one JSON line each.
    public static var conversationLogFile: URL { supportDirectory.appendingPathComponent("conversations.jsonl") }
    /// The self-update: the staged build, its log, the backup of the previous app and the heartbeat.
    public static var updateDirectory: URL { supportDirectory.appendingPathComponent("update", isDirectory: true) }
    /// The git worktree the update is built in, never the one being developed. Caches, without the
    /// space of "Application Support" in its path; next to the support folder when that is overridden.
    public static var updateWorktree: URL {
        if ProcessInfo.processInfo.environment["WORKSPACES_HOME"] != nil {
            return supportDirectory.appendingPathComponent("update-wt", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Workspaces/update-wt", isDirectory: true)
    }

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = AppPaths.configFile) {
        self.url = url
    }

    /// A missing file is an empty config; a broken file is an error so it is never silently overwritten.
    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
