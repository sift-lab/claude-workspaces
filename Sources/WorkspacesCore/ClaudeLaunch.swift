import Foundation

/// Builds what a session needs to start: the helper files for Claude Code and the shell command.
public enum ClaudeLaunch {
    public static let sessionEnvKey = "WORKSPACES_SESSION"
    public static let launchEnvKey = "WORKSPACES_LAUNCH"

    /// Quotes a value for a POSIX shell.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Settings passed with `--settings`: every subscribed hook calls `<helper> hook`, and the status
    /// line calls `<helper> statusline` (which still prints the person's own status line, if any).
    /// The user's own settings stay untouched.
    public static func settingsJSON(helperPath: String) -> JSONValue {
        settingsJSON(hookCommand: shellQuote(helperPath) + " hook", statusLineCommand: shellQuote(helperPath) + " statusline")
    }

    /// Same, with the exact commands the hooks and the status line run.
    public static func settingsJSON(hookCommand: String, statusLineCommand: String? = nil) -> JSONValue {
        let command = JSONValue.string(hookCommand)
        let entry = JSONValue.array([.object(["hooks": .array([.object(["type": .string("command"), "command": command, "timeout": .number(5)])])])])
        var hooks: [String: JSONValue] = [:]
        for event in HookEvent.subscribed { hooks[event] = entry }
        var settings: [String: JSONValue] = ["hooks": .object(hooks)]
        if let statusLineCommand {
            settings["statusLine"] = .object(["type": .string("command"), "command": .string(statusLineCommand), "padding": .number(0)])
        }
        return .object(settings)
    }

    public static let sessionHeader = "X-Workspaces-Session"

    /// MCP config for one session: the app answers MCP over HTTP on localhost, so no helper process runs.
    /// The token keeps other local programs from calling the tools.
    public static func mcpHTTPConfigJSON(url: String, session: String, token: String) -> JSONValue {
        .object(["mcpServers": .object([
            "workspaces": .object([
                "type": .string("http"),
                "url": .string(url),
                "headers": .object([sessionHeader: .string(session), "Authorization": .string("Bearer \(token)")]),
            ]),
        ])])
    }

    /// MCP config passed with `--mcp-config`: a stdio server that is this same binary.
    public static func mcpConfigJSON(helperPath: String) -> JSONValue {
        .object(["mcpServers": .object([
            "workspaces": .object(["command": .string(helperPath), "args": .array([.string("mcp")])]),
        ])])
    }

    public struct Options: Equatable, Sendable {
        public var claudeCommand: String
        public var projectPath: String
        public var settingsFile: String
        public var mcpConfigFile: String
        public var name: String?
        public var resumeId: String?
        public var worktree: String?
        public var prompt: String?
        /// Shell fragment the person wrote in the project settings; not quoted on purpose.
        public var extraArguments: String

        public init(claudeCommand: String, projectPath: String, settingsFile: String, mcpConfigFile: String,
                    name: String? = nil, resumeId: String? = nil, worktree: String? = nil, prompt: String? = nil,
                    extraArguments: String = "") {
            self.claudeCommand = claudeCommand
            self.projectPath = projectPath
            self.settingsFile = settingsFile
            self.mcpConfigFile = mcpConfigFile
            self.name = name
            self.resumeId = resumeId
            self.worktree = worktree
            self.prompt = prompt
            self.extraArguments = extraArguments
        }
    }

    /// Arguments after the command, unquoted, for launching Claude without a shell.
    /// Nil when the command or the extra arguments need a real shell to be understood.
    public static func argv(_ o: Options) -> [String]? {
        guard let command = ShellSupport.words(o.claudeCommand), !command.isEmpty,
              let extra = ShellSupport.words(o.extraArguments) else { return nil }
        return command + ownArguments(o, extra: extra)
    }

    private static func ownArguments(_ o: Options, extra: [String]) -> [String] {
        var args = ["--settings", o.settingsFile, "--mcp-config", o.mcpConfigFile] + extra
        if let resume = o.resumeId {
            args += ["--resume", resume]
        } else {
            if let worktree = o.worktree { args += ["--worktree", worktree] }
            if let name = o.name { args += ["--name", name] }
            // "--" so a prompt that starts with a dash is never read as a flag.
            if let prompt = o.prompt, !prompt.isEmpty { args += ["--", prompt] }
        }
        return args
    }

    private static let ownFlags: Set<String> = ["--settings", "--mcp-config", "--resume", "--worktree", "--name", "--"]

    /// Fallback when `argv` is nil: the login shell runs this. When Claude exits the tab keeps a plain shell.
    public static func shellScript(_ o: Options) -> String {
        var args = [o.claudeCommand]
        let extra = o.extraArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        args += ownArguments(o, extra: []).map { ownFlags.contains($0) ? $0 : shellQuote($0) }
        if !extra.isEmpty { args.insert(extra, at: 5) }
        return "cd \(shellQuote(o.projectPath)) && " + args.joined(separator: " ") + "; exec \"${SHELL:-/bin/zsh}\" -l"
    }
}
