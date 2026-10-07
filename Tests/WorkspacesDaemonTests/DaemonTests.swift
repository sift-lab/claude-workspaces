import Foundation
import Testing
import WorkspacesCore
@testable import WorkspacesDaemon

// MARK: Fakes

final class FakeTerminal: SessionTerminal {
    enum Event: Equatable {
        case start(String), paste(String, String), type(String, String), enter(String), key(String, String), kill(String)
    }

    var events: [Event] = []
    var running: Set<String> = []
    var screens: [String: String] = [:]
    var started: [(name: String, folder: String, environment: [String: String], argv: [String])] = []

    func start(name: String, folder: String, environment: [String: String], argv: [String]) throws {
        started.append((name, folder, environment, argv))
        running.insert(name)
        events.append(.start(name))
    }
    func isRunning(_ name: String) -> Bool { running.contains(name) }
    func paste(_ name: String, _ text: String) { events.append(.paste(name, text)) }
    func type(_ name: String, _ text: String) { events.append(.type(name, text)) }
    func pressEnter(_ name: String) { events.append(.enter(name)) }
    func press(_ name: String, key: String) { events.append(.key(name, key)) }
    func capture(_ name: String) -> String { screens[name] ?? "" }
    func pid(_ name: String) -> Int32? { nil }
    func kill(_ name: String) {
        running.remove(name)
        events.append(.kill(name))
    }
}

final class ManualScheduler: Scheduler {
    private struct Item {
        let at: Date
        let order: Int
        let work: () -> Void
        let token: ScheduledWork
    }

    /// Starts at the real time: the gate compares it with the FRENTE.md's date on disk.
    var now = Date()
    private var items: [Item] = []
    private var counter = 0

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let token = ScheduledWork()
        counter += 1
        items.append(Item(at: now.addingTimeInterval(seconds), order: counter, work: work, token: token))
        return token
    }

    /// Runs everything due, in time order, including work scheduled along the way.
    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = items.filter({ $0.at <= end }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            items.removeAll { $0.order == next.order }
            now = max(now, next.at)
            if !next.token.cancelled { next.work() }
        }
        now = end
    }
}

final class FakeNotifier: Notifier {
    var posts: [(String, String)] = []
    func post(title: String, body: String) -> Bool {
        posts.append((title, body))
        return true
    }
}

// MARK: Harness

/// A daemon in a temporary folder with a git repo that keeps a FRENTE.md, and one account.
final class Harness {
    let root: URL
    let repo: URL
    let terminal = FakeTerminal()
    let scheduler = ManualScheduler()
    let notifier = FakeNotifier()
    let daemon: Daemon
    let accountDir: URL

    init(account: String = "acme1") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wsd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        repo = root.appendingPathComponent("src/repo", isDirectory: true)
        accountDir = root.appendingPathComponent("claude-\(account)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountDir.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let server = ServerConfig(accounts: [account: accountDir.path], defaultAccount: account,
                                  trustedRoots: [root.appendingPathComponent("src").path])
        try JSONEncoder().encode(server).write(to: home.appendingPathComponent("server.json"))
        Harness.git(repo, ["init", "-q"])
        Harness.git(repo, ["config", "user.email", "x@example.com"])
        Harness.git(repo, ["config", "user.name", "x"])
        try "# Frente\n".write(to: repo.appendingPathComponent("FRENTE.md"), atomically: true, encoding: .utf8)
        Harness.git(repo, ["add", "."])
        Harness.git(repo, ["commit", "-q", "-m", "c"])
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        daemon = try Daemon(paths: .init(home: home), helpers: .init(daemon: "/opt/x/workspacesd", hook: "/opt/x/workspaces-hook"),
                            terminal: terminal, scheduler: scheduler, notifier: notifier,
                            baseEnvironment: ["PATH": bin.path, "HOME": root.path])
        try daemon.start()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    static func git(_ dir: URL, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func call(_ tool: String, _ args: [String: JSONValue] = [:], from caller: ServerSession? = nil) -> IPCResponse {
        daemon.handle(IPCRequest(kind: .tool, session: caller?.id.uuidString, tool: tool, arguments: .object(args)))
    }

    func hook(_ session: ServerSession, _ payload: [String: JSONValue]) -> IPCResponse {
        daemon.handle(IPCRequest(kind: .hook, session: session.id.uuidString, payload: .object(payload),
                                 launch: String(session.record.launch)))
    }

    /// Opens a session in the repo and brings it to the end of a first turn, with a transcript on disk.
    func openedSession(conversation: String = "conv-1", extra: [String: JSONValue] = [:]) throws -> ServerSession {
        var args: [String: JSONValue] = ["path": .string(repo.path)]
        for (k, v) in extra { args[k] = v }
        let reply = call("open_session", args)
        #expect(reply.ok, "\(reply.text)")
        let session = try #require(daemon.sessions.last)
        let transcript = accountDir.appendingPathComponent("projects/p/\(conversation).jsonl")
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)
        _ = hook(session, ["hook_event_name": "SessionStart", "session_id": .string(conversation), "source": "startup", "cwd": .string(repo.path)])
        _ = hook(session, ["hook_event_name": "UserPromptSubmit", "session_id": .string(conversation), "transcript_path": .string(transcript.path)])
        _ = hook(session, ["hook_event_name": "Stop", "session_id": .string(conversation)])
        terminal.events.removeAll()
        return session
    }

    func writePassagem(age: TimeInterval = 0) throws {
        let frente = repo.appendingPathComponent("FRENTE.md")
        try "# Frente\n\n## Passagem\nPR aberto, falta o review.\n".write(to: frente, atomically: true, encoding: .utf8)
        Harness.git(repo, ["commit", "-q", "-am", "passagem"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: frente.path)
    }

    /// The input line of Claude Code as tmux captures it.
    func screen(_ session: ServerSession, input: String) {
        terminal.screens[session.terminalName] = "\u{1B}[38;5;244m────────\n\u{1B}[39m❯\u{A0}\(input)\n\u{1B}[38;5;244m────────\n"
    }
}

// MARK: Tests

@Suite(.serialized) struct OpenSessionTests {
    @Test func startsClaudeInTmuxWithTheAccountAndTheModel() throws {
        let h = try Harness()
        let reply = h.call("open_session", ["path": .string(h.repo.path), "model": "sonnet", "prompt": "Leia o FRENTE.md"])
        #expect(reply.ok, "\(reply.text)")
        let start = try #require(h.terminal.started.first)
        let session = try #require(h.daemon.sessions.first)
        #expect(start.name == "ws-\(session.shortId)")
        #expect(start.folder == h.repo.path)
        #expect(start.environment["CLAUDE_CONFIG_DIR"] == h.accountDir.path)
        #expect(start.environment["WORKSPACES_CONTA"] == "acme1")
        #expect(start.environment["WORKSPACES_SESSION"] == session.id.uuidString)
        #expect(start.environment["WORKSPACES_HOME"] == h.daemon.paths.home.path)
        #expect(start.environment["PATH"]?.contains("/.local/bin") == true)
        #expect(start.argv.first?.hasSuffix("/bin/claude") == true)
        #expect(start.argv.contains("--model") && start.argv.contains("sonnet"))
        #expect(Array(start.argv.suffix(2)) == ["--", "Leia o FRENTE.md"])
        #expect(start.argv.contains(h.daemon.paths.settings.path) && start.argv.contains(h.daemon.paths.mcp.path))
        #expect(reply.text.contains("acme1"))
    }

    @Test func refusesUnknownAccountBadModelAndMissingFolder() throws {
        let h = try Harness()
        #expect(!h.call("open_session", ["path": .string(h.repo.path), "account": "outra"]).ok)
        #expect(!h.call("open_session", ["path": .string(h.repo.path), "model": "x; rm -rf"]).ok)
        #expect(!h.call("open_session", ["path": .string("/tmp/nao-existe-\(UUID())")]).ok)
        #expect(!h.call("open_session", ["path": .string(h.repo.path), "worktree": "../fora"]).ok)
        #expect(h.terminal.started.isEmpty)
    }

    @Test func settingsHookStopFailureAndTheMCPRunsTheDaemon() throws {
        let h = try Harness()
        let settings = try #require(JSONValue.parse(try Data(contentsOf: h.daemon.paths.settings)))
        #expect(settings["hooks"]?["StopFailure"] != nil)
        #expect(settings["hooks"]?["Stop"] != nil)
        let mcp = try #require(JSONValue.parse(try Data(contentsOf: h.daemon.paths.mcp)))
        #expect(mcp["mcpServers"]?["workspaces"]?["command"] == "/opt/x/workspacesd")
    }

    @Test func trustsAFolderInsideATrustedRootOnly() throws {
        let h = try Harness()
        _ = h.call("open_session", ["path": .string(h.repo.path)])
        let session = try #require(h.daemon.sessions.first)
        h.terminal.screens[session.terminalName] = "Quick safety check\n❯ No, exit\n  Yes, I trust this folder\n"
        h.scheduler.advance(by: 3)
        #expect(h.terminal.events.contains(.key(session.terminalName, "Down")))
        #expect(h.terminal.events.last == .enter(session.terminalName))

        let outside = h.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        _ = h.call("open_session", ["path": .string(outside.path)])
        let other = try #require(h.daemon.sessions.last)
        h.terminal.screens[other.terminalName] = "Yes, I trust this folder\n"
        h.terminal.events.removeAll()
        h.scheduler.advance(by: 3)
        #expect(!h.terminal.events.contains(.key(other.terminalName, "Down")))
        #expect(other.status == .waiting)
    }
}

@Suite(.serialized) struct SendMessageTests {
    @Test func pastesWithTheSenderAndPressesEnter() throws {
        let h = try Harness()
        let a = try h.openedSession(conversation: "a")
        let b = try h.openedSession(conversation: "b")
        let reply = h.call("send_message", ["session": .string(b.shortId), "text": "olá"], from: a)
        #expect(reply.ok, "\(reply.text)")
        h.scheduler.advance(by: 0.1)
        #expect(h.terminal.events == [.paste(b.terminalName, "[recado de \(a.label)] olá")])
        h.scheduler.advance(by: 0.5)
        #expect(h.terminal.events.last == .enter(b.terminalName))
    }

    @Test func aScriptSendsWithoutPrefixAndCanUseDisabledTools() throws {
        let h = try Harness()
        let b = try h.openedSession()
        #expect(h.call("send_message", ["session": .string(b.shortId), "text": "oi"]).ok)
        h.scheduler.advance(by: 1)
        #expect(h.terminal.events == [.paste(b.terminalName, "oi"), .enter(b.terminalName)])
    }

    @Test func hibernatedSessionWakesWithResumeAndGetsItAfterStart() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "conv-9")
        h.daemon.hibernate(s)
        #expect(!h.terminal.isRunning(s.terminalName))
        #expect(h.call("send_message", ["session": .string(s.shortId), "text": "volta"]).ok)
        let restart = try #require(h.terminal.started.last)
        #expect(restart.argv.contains("--resume") && restart.argv.contains("conv-9"))
        h.scheduler.advance(by: 5)
        #expect(!h.terminal.events.contains(.paste(s.terminalName, "volta")))
        _ = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "conv-9", "source": "resume"])
        h.scheduler.advance(by: 2.1)
        #expect(h.terminal.events.suffix(2) == [.paste(s.terminalName, "volta"), .enter(s.terminalName)])
    }
}

@Suite(.serialized) struct RecycleTests {
    @Test func refusedWithoutPassagem() throws {
        let h = try Harness()
        let s = try h.openedSession()
        h.screen(s, input: "")
        let reply = h.call("recycle_session", ["session": .string(s.shortId)])
        #expect(!reply.ok)
        #expect(reply.text.contains("Passagem"))
        #expect(h.terminal.events.isEmpty)
    }

    @Test func refusedWithAnOldPassagem() throws {
        let h = try Harness()
        let s = try h.openedSession()
        try h.writePassagem(age: 45 * 60)
        h.screen(s, input: "")
        let reply = h.call("recycle_session", ["session": .string(s.shortId)])
        #expect(!reply.ok)
        #expect(reply.text.contains("foi salvo há 4") && reply.text.contains("nos últimos 30 min"))
        #expect(h.terminal.events.isEmpty)
    }

    @Test func refusedWithADirtyTree() throws {
        let h = try Harness()
        let s = try h.openedSession()
        try h.writePassagem()
        try "x".write(to: h.repo.appendingPathComponent("solto.txt"), atomically: true, encoding: .utf8)
        h.screen(s, input: "")
        let reply = h.call("recycle_session", ["session": .string(s.shortId)])
        #expect(!reply.ok)
        #expect(reply.text.contains("solto.txt"))
        #expect(h.terminal.events.isEmpty)
    }

    @Test func refusedWithTextTyped() throws {
        let h = try Harness()
        let s = try h.openedSession()
        try h.writePassagem()
        h.screen(s, input: "rascunho")
        let reply = h.call("recycle_session", ["session": .string(s.shortId)])
        #expect(!reply.ok)
        #expect(reply.text.contains("texto não enviado"))
        #expect(h.terminal.events.isEmpty)
    }

    @Test func acceptedClearsAndPastesTheResume() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        // The suggested next prompt, faint, is not a draft.
        h.screen(s, input: "\u{1B}[2mrode os testes\u{1B}[0m")
        let reply = h.call("recycle_session", ["session": .string(s.shortId)])
        #expect(reply.ok, "\(reply.text)")
        #expect(h.terminal.events == [.type(s.terminalName, "/clear")])
        h.scheduler.advance(by: 0.4)
        #expect(h.terminal.events.last == .enter(s.terminalName))

        let context = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        #expect(context.text.contains("PR aberto, falta o review."))
        h.scheduler.advance(by: 1.5)
        let transcript = h.accountDir.appendingPathComponent("projects/p/old.jsonl").path
        #expect(h.terminal.events.last == .paste(s.terminalName, Handoff.resumePrompt(oldTranscript: transcript)))
        h.scheduler.advance(by: 0.5)
        #expect(h.terminal.events.last == .enter(s.terminalName))
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "new"])
        #expect(RecycleLog(url: h.daemon.paths.recycleLog).records().map(\.kind) == [.recycle, .resumed])
        #expect(s.recycle?.text == "reciclada")
    }

    @Test func recycleSelfWaitsForTheTurnToEnd() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "old"])
        let reply = h.call("recycle_self", from: s)
        #expect(reply.ok, "\(reply.text)")
        #expect(h.terminal.events.isEmpty)
        h.screen(s, input: "")
        _ = h.hook(s, ["hook_event_name": "Stop", "session_id": "old"])
        h.scheduler.advance(by: 2.4)
        #expect(h.terminal.events.isEmpty)
        h.scheduler.advance(by: 0.2)
        #expect(h.terminal.events == [.type(s.terminalName, "/clear")])
    }

    @Test func recycleTakesNoText() throws {
        let h = try Harness()
        let s = try h.openedSession()
        #expect(!h.call("recycle_session", ["session": .string(s.shortId), "text": "outra coisa"]).ok)
    }
}

@Suite(.serialized) struct LimitTests {
    @Test func readingsGoToTheSessionsAccountFile() throws {
        let h = try Harness(account: "acme2")
        let s = try h.openedSession()
        let payload: JSONValue = .object([
            "session_id": "conv-1",
            "context_window": .object(["total_input_tokens": .number(312_000), "context_window_size": .number(1_000_000)]),
            "rate_limits": .object(["five_hour": .object(["used_percentage": .number(16), "resets_at": .number(1_800_010_000)])]),
        ])
        _ = h.daemon.handle(IPCRequest(kind: .statusLine, session: s.id.uuidString, payload: payload))
        let file = h.daemon.paths.home.appendingPathComponent("limit-readings-acme2.json")
        let saved = try JSONDecoder().decode(LimitReadings.self, from: Data(contentsOf: file))
        #expect(saved.fiveHour.map(\.percent) == [16])
        #expect(!FileManager.default.fileExists(atPath: h.daemon.paths.home.appendingPathComponent("limit-readings-conta1.json").path))
        let list = h.call("list_sessions", ["all_workspaces": true]).text
        #expect(list.contains("acme2"))
        #expect(list.contains("contexto 312k (precisa de passagem"))
    }

    @Test func rateLimitedTurnContinuesAfterTheReset() throws {
        let h = try Harness()
        let s = try h.openedSession()
        h.screen(s, input: "")
        _ = h.hook(s, ["hook_event_name": "StopFailure", "session_id": "conv-1", "error_type": "rate_limit", "retry_after": .number(600)])
        #expect(s.rateLimitedUntil != nil)
        #expect(h.call("list_sessions").text.contains("limite da conta"))
        h.scheduler.advance(by: 600)
        #expect(h.terminal.events.isEmpty)
        h.scheduler.advance(by: 60.2)
        #expect(h.terminal.events == [.paste(s.terminalName, "continue")])
        h.scheduler.advance(by: 0.5)
        #expect(h.terminal.events.last == .enter(s.terminalName))
    }

    @Test func otherFailuresDoNotContinue() throws {
        let h = try Harness()
        let s = try h.openedSession()
        h.screen(s, input: "")
        _ = h.hook(s, ["hook_event_name": "StopFailure", "session_id": "conv-1", "error_type": "server_error"])
        #expect(s.rateLimitedUntil == nil)
        #expect(s.status == .done)
        h.scheduler.advance(by: 3 * 3600)
        #expect(!h.terminal.events.contains(.paste(s.terminalName, "continue")))
    }

    @Test func aDraftIsNeverSentWithContinue() throws {
        let h = try Harness()
        let s = try h.openedSession()
        h.screen(s, input: "rascunho de alguém")
        _ = h.hook(s, ["hook_event_name": "StopFailure", "session_id": "conv-1", "error_type": "rate_limit", "retry_after": .number(10)])
        h.scheduler.advance(by: 120)
        #expect(h.terminal.events.isEmpty)
    }
}

@Suite(.serialized) struct SleepTests {
    @Test func quietSessionHibernatesAndBusyOneDoesNot() throws {
        let h = try Harness()
        let quiet = try h.openedSession(conversation: "q")
        let busy = try h.openedSession(conversation: "b")
        _ = h.hook(busy, ["hook_event_name": "UserPromptSubmit", "session_id": "b"])
        h.scheduler.advance(by: 31 * 60)
        #expect(quiet.hibernated)
        #expect(h.terminal.events.contains(.kill(quiet.terminalName)))
        #expect(!busy.hibernated)
        #expect(h.call("list_sessions").text.contains("hibernated"))
    }

    @Test func restartAdoptsRunningSessionsAndHibernatesTheRest() throws {
        let h = try Harness()
        let alive = try h.openedSession(conversation: "a")
        let gone = try h.openedSession(conversation: "g")
        h.terminal.running.remove(gone.terminalName)
        let again = try Daemon(paths: h.daemon.paths, helpers: h.daemon.helpers, terminal: h.terminal, scheduler: h.scheduler,
                               notifier: h.notifier, baseEnvironment: h.daemon.baseEnvironment)
        try again.start()
        #expect(again.session(alive.id)?.hibernated == false)
        #expect(again.session(gone.id)?.hibernated == true)
        #expect(again.session(gone.id)?.conversation.resumable == "g")
    }
}

@Suite(.serialized) struct CloseAndNotifyTests {
    @Test func closeRefusesDirtyTreeAndLogsWhenClean() throws {
        let h = try Harness()
        let s = try h.openedSession()
        try "x".write(to: h.repo.appendingPathComponent("solto.txt"), atomically: true, encoding: .utf8)
        #expect(!h.call("close_session", ["session": .string(s.shortId)]).ok)
        try FileManager.default.removeItem(at: h.repo.appendingPathComponent("solto.txt"))
        let reply = h.call("close_session", ["session": .string(s.shortId)])
        #expect(reply.ok, "\(reply.text)")
        #expect(h.daemon.sessions.isEmpty)
        #expect(h.terminal.events.contains(.kill(s.terminalName)))
        #expect(RecycleLog(url: h.daemon.paths.recycleLog).records().map(\.kind) == [.close])
    }

    @Test func notifyGoesToThePhone() throws {
        let h = try Harness()
        let s = try h.openedSession()
        #expect(h.call("notify", ["text": "PR aberto"], from: s).ok)
        #expect(h.notifier.posts.first?.1 == "PR aberto")
    }

    @Test func disabledToolIsRefusedToASessionOnly() throws {
        let h = try Harness()
        let s = try h.openedSession()
        var config = h.daemon.config
        config.disabledTools = ["notify"]
        try ConfigStore(url: h.daemon.paths.config).save(config)
        let again = try Daemon(paths: h.daemon.paths, helpers: h.daemon.helpers, terminal: h.terminal, scheduler: h.scheduler,
                               notifier: h.notifier, baseEnvironment: h.daemon.baseEnvironment)
        let caller = try #require(again.session(s.id))
        let refused = again.handle(IPCRequest(kind: .tool, session: caller.id.uuidString, tool: "notify", arguments: ["text": "x"]))
        #expect(!refused.ok)
        #expect(again.handle(IPCRequest(kind: .tools, session: nil)).enabledTools?.contains("notify") == false)
    }
}

// Literals only in the tests, to keep the payloads readable.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

@Suite(.serialized) struct ContextTests {
    @Test func aNewConversationForgetsTheOldContext() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        let payload: JSONValue = ["session_id": "old", "context_window": .object(["total_input_tokens": .number(312_000)])]
        _ = h.daemon.handle(IPCRequest(kind: .statusLine, session: s.id.uuidString, payload: payload))
        #expect(s.contextTokens == 312_000)
        _ = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        #expect(s.contextTokens == nil)
        #expect(!h.call("list_sessions").text.contains("312k"))
    }
}

@Suite(.serialized) struct ReviewFixTests {
    @Test func aMessagedSessionStillHibernatesAfterItsTurn() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "m")
        #expect(h.call("send_message", ["session": .string(s.shortId), "text": "faça X"]).ok)
        #expect(s.attention)
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "m"])
        _ = h.hook(s, ["hook_event_name": "Stop", "session_id": "m"])
        #expect(!s.attention)
        h.scheduler.advance(by: 31 * 60)
        #expect(s.hibernated)
    }

    @Test func refusedOpenLeavesNoProjectBehind() throws {
        let h = try Harness()
        let before = h.daemon.config.workspaces.flatMap(\.projects).count
        #expect(!h.call("open_session", ["path": .string(h.repo.path), "account": "ruim!"]).ok)
        #expect(!h.call("open_session", ["path": .string(h.repo.path), "model": "x y"]).ok)
        #expect(h.daemon.config.workspaces.flatMap(\.projects).count == before)
    }

    @Test func labelsNeverRepeatAfterAClose() throws {
        let h = try Harness()
        let first = try h.openedSession(conversation: "1")
        _ = try h.openedSession(conversation: "2")
        #expect(h.call("close_session", ["session": .string(first.shortId)]).ok)
        _ = try h.openedSession(conversation: "3")
        let labels = h.daemon.sessions.map(\.label)
        #expect(Set(labels).count == labels.count, "\(labels)")
    }

    @Test func rateLimitAlsoReadFromTheErrorField() throws {
        let h = try Harness()
        let s = try h.openedSession()
        _ = h.hook(s, ["hook_event_name": "StopFailure", "session_id": "conv-1", "error": "rate_limit"])
        #expect(s.rateLimitedUntil != nil)
    }

    @Test func messageToAHibernatedSessionSaysItIsQueued() throws {
        let h = try Harness()
        let s = try h.openedSession()
        h.daemon.hibernate(s)
        let reply = h.call("send_message", ["session": .string(s.shortId), "text": "oi"])
        #expect(reply.ok)
        #expect(reply.text.contains("estava hibernando"))
    }
}
