import Foundation
import WorkspacesCore
import WorkspacesDaemon

// workspacesd: the Workspaces app without a screen, for a Linux server. Sessions run in tmux.
//   workspacesd serve                      the daemon (systemd --user runs this)
//   workspacesd mcp                        stdio MCP server for one session (Claude Code runs this)
//   workspacesd status                     every session
//   workspacesd open <pasta|projeto> [--prompt T] [--conta C] [--modelo M] [--worktree W]
//   workspacesd send <sessão> <texto>      pastes and presses Enter
//   workspacesd recycle <sessão>
//   workspacesd close <sessão>
//   workspacesd tool <nome> ['{json}']     any MCP tool, as no session

let usage = """
uso: workspacesd serve | mcp | status | open <pasta|projeto> [--prompt T] [--conta C] [--modelo M] [--worktree W]
     | send <sessão> <texto> | recycle <sessão> | close <sessão> | tool <nome> ['{json}']
"""

/// Files live in ~/.workspaces unless WORKSPACES_HOME says otherwise. The hook and the MCP bridge
/// find the socket through the same variable, set in every session's environment.
func home() -> URL {
    if let override = ProcessInfo.processInfo.environment["WORKSPACES_HOME"] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".workspaces", isDirectory: true)
}

func socketPath() -> String {
    setenv("WORKSPACES_HOME", home().path, 0)
    return AppPaths.socketFile.path
}

func fail(_ text: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(code)
}

func tool(_ name: String, _ arguments: [String: JSONValue]) -> Never {
    let json = String(decoding: JSONValue.object(arguments).encodedLine(), as: UTF8.self).trimmingCharacters(in: .newlines)
    exit(ToolCommand.run([name, json], socketPath: socketPath(), timeout: 60))
}

func serve() -> Never {
    let paths = Daemon.Paths(home: home())
    setenv("WORKSPACES_HOME", paths.home.path, 1)
    // argv[0] is a bare name when started through PATH; /proc says where the binary really is.
    let executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
    let hook = executable.deletingLastPathComponent().appendingPathComponent("workspaces-hook").path
    guard FileManager.default.isExecutableFile(atPath: hook) else { fail("falta o workspaces-hook ao lado do workspacesd (\(hook))") }
    let queue = DispatchQueue(label: "workspacesd")
    let daemon: Daemon = queue.sync {
        do {
            let serverFile = paths.server
            let server = (FileManager.default.contents(atPath: serverFile.path))
                .flatMap { try? JSONDecoder().decode(ServerConfig.self, from: $0) } ?? ServerConfig()
            let logFile = paths.eventLog
            let notifier = NtfyNotifier(server: server.ntfyServer, topic: server.ntfyTopic) { text in
                let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(line.utf8))
                    try? handle.close()
                }
            }
            let gh = PullRequestLookup.locate(path: ProcessInfo.processInfo.environment["PATH"])
            let daemon = try Daemon(paths: paths, helpers: .init(daemon: executable.path, hook: hook, gh: gh),
                                    terminal: TmuxTerminal(), scheduler: QueueScheduler(queue: queue), notifier: notifier,
                                    baseEnvironment: ProcessInfo.processInfo.environment)
            try daemon.start()
            return daemon
        } catch {
            fail("workspacesd não iniciou: \(error)", code: 1)
        }
    }
    let listener = IPCListener(path: AppPaths.socketFile.path, queue: queue) { daemon.handle($0) }
    do { try listener.start() } catch { fail("workspacesd não abriu o socket: \(error)", code: 1) }
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        source.setEventHandler {
            // The sessions stay in tmux; the next start adopts them.
            listener.stop()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
    FileHandle.standardError.write(Data("workspacesd ouvindo em \(AppPaths.socketFile.path)\n".utf8))
    dispatchMain()
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

switch command {
case "serve":
    serve()
case "mcp":
    MCPBridge.run(socketPath: socketPath())
case "status":
    tool("list_sessions", ["all_workspaces": .bool(true)])
case "open":
    guard let place = args.first else { fail(usage) }
    var arguments: [String: JSONValue] = [:]
    if place.hasPrefix("/") || place.hasPrefix("~") || place.hasPrefix(".") {
        arguments["path"] = .string(URL(fileURLWithPath: (place as NSString).expandingTildeInPath).standardizedFileURL.path)
    } else {
        arguments["project"] = .string(place)
    }
    var rest = args.dropFirst()
    let flags = ["--prompt": "prompt", "--conta": "account", "--modelo": "model", "--worktree": "worktree"]
    while let flag = rest.popFirst() {
        guard let key = flags[flag], let value = rest.popFirst() else { fail(usage) }
        arguments[key] = .string(value)
    }
    tool("open_session", arguments)
case "send":
    guard args.count >= 2 else { fail(usage) }
    tool("send_message", ["session": .string(args[0]), "text": .string(args.dropFirst().joined(separator: " "))])
case "recycle":
    guard args.count == 1 else { fail(usage) }
    tool("recycle_session", ["session": .string(args[0])])
case "close":
    guard args.count == 1 else { fail(usage) }
    tool("close_session", ["session": .string(args[0])])
case "tool":
    exit(ToolCommand.run(args, socketPath: socketPath(), timeout: 60))
default:
    fail(usage)
}
