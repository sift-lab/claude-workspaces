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
    /// A whole screen, as tmux captures it; wins over `inputs`.
    var screens: [String: String] = [:]
    /// What Claude Code's input line holds: typing and pasting add to it at the end, C-a goes to
    /// its start, DC deletes there, Enter sends it (empties it), unless `enterKeepsInput` (a
    /// /clear that did not go).
    var inputs: [String: String] = [:]
    private var atStart: Set<String> = []
    var enterKeepsInput = false
    var started: [(name: String, folder: String, environment: [String: String], argv: [String])] = []

    func start(name: String, folder: String, environment: [String: String], argv: [String]) throws {
        started.append((name, folder, environment, argv))
        running.insert(name)
        events.append(.start(name))
    }
    func isRunning(_ name: String) -> Bool { running.contains(name) }
    func paste(_ name: String, _ text: String) {
        events.append(.paste(name, text))
        atStart.remove(name)
        inputs[name, default: ""] += text
    }
    func type(_ name: String, _ text: String) {
        events.append(.type(name, text))
        atStart.remove(name)
        inputs[name, default: ""] += text
    }
    func pressEnter(_ name: String) {
        events.append(.enter(name))
        if !enterKeepsInput, inputs[name] != nil { inputs[name] = "" }
    }
    func press(_ name: String, key: String) {
        events.append(.key(name, key))
        if key == "C-a" { atStart.insert(name) }
        if key == "DC", atStart.contains(name), var input = inputs[name], !input.isEmpty {
            input.removeFirst()
            inputs[name] = input
        }
    }
    func capture(_ name: String) -> String {
        if let screen = screens[name] { return screen }
        guard let input = inputs[name] else { return "" }
        return "\u{1B}[38;5;244m────────\n\u{1B}[39m❯\u{A0}\(input)\n\u{1B}[38;5;244m────────\n"
    }
    func typed(_ name: String) -> String? { inputs[name] }
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

    /// The process died: nothing it scheduled runs any more.
    func dropAll() { items.removeAll() }

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

    /// The title as a session writes it: the date and time it was written, local time.
    static func title(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH'h'mm"
        formatter.timeZone = .current
        return "## Passagem \(formatter.string(from: date))"
    }

    /// A FRENTE.md whose Passagem was written `age` seconds ago by its title; the file itself is new.
    func writePassagem(age: TimeInterval = 0, body: String = "PR aberto, falta o review.", before: String = "") throws {
        let text = "# Frente\n\n\(before)\(Harness.title(scheduler.now.addingTimeInterval(-age)))\n\(body)\n"
        try text.write(to: repo.appendingPathComponent("FRENTE.md"), atomically: true, encoding: .utf8)
        Harness.git(repo, ["commit", "-q", "-am", "passagem"])
    }

    /// The input line of Claude Code as tmux captures it.
    func screen(_ session: ServerSession, input: String) {
        terminal.screens[session.terminalName] = nil
        terminal.inputs[session.terminalName] = input
    }

    /// Lines appended to a conversation's .jsonl, as Claude Code writes them.
    func appendTranscript(_ conversation: String, _ lines: [JSONValue]) throws {
        let url = accountDir.appendingPathComponent("projects/p/\(conversation).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for line in lines { try handle.write(contentsOf: line.encodedLine()) }
    }

    var records: [RecycleRecord] { RecycleLog(url: daemon.paths.recycleLog).records() }

    /// The daemon stopped and started again on the same files, with the sessions still in tmux.
    func restart() throws -> Daemon {
        scheduler.dropAll()
        let again = try Daemon(paths: daemon.paths, helpers: daemon.helpers, terminal: terminal, scheduler: scheduler,
                               notifier: notifier, baseEnvironment: daemon.baseEnvironment)
        try again.start()
        return again
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
        #expect(reply.text.contains("é de 4") && reply.text.contains("nos últimos 30 min"))
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
        // Nothing is logged before the last look, right before Enter.
        #expect(h.records.isEmpty)
        h.scheduler.advance(by: 0.4)
        #expect(h.terminal.events.last == .enter(s.terminalName))
        let logged = try #require(h.records.first)
        #expect(logged.kind == .recycle)
        let file = try #require(logged.handoffFile)
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("PR aberto, falta o review."))

        let context = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        #expect(context.text.contains("PR aberto, falta o review."))
        // Where the worktree stands goes with it.
        #expect(context.text.contains("Ramo: "))
        #expect(context.text.contains("HEAD: ") && context.text.contains(" passagem"))
        h.scheduler.advance(by: 1.5)
        let transcript = h.accountDir.appendingPathComponent("projects/p/old.jsonl").path
        let prompt = Handoff.resumePrompt(handoffFile: file, oldTranscript: transcript)
        #expect(h.terminal.events.last == .paste(s.terminalName, prompt))
        h.scheduler.advance(by: 0.5)
        #expect(h.terminal.events.last == .enter(s.terminalName))
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "new", "prompt": .string(prompt)])
        #expect(h.records.map(\.kind) == [.recycle, .resumed])
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

    // MARK: The cases that broke a recycle

    /// A: the /clear ran after the 30 s. The recycle stays open, and the late conversation still
    /// gets the Passagem and the resume prompt; a /clear still in the input is taken back.
    @Test func lateClearStillGetsThePassagemAndTheResume() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.terminal.enterKeepsInput = true
        h.scheduler.advance(by: 0.4)
        h.scheduler.advance(by: 30)
        #expect(h.terminal.typed(s.terminalName) == "")
        #expect(h.terminal.events.filter { $0 == .key(s.terminalName, "DC") }.count == 6)
        #expect(h.records.map(\.kind) == [.recycle, .delayed])
        #expect(s.attention)
        h.terminal.enterKeepsInput = false

        h.scheduler.advance(by: 60)
        let context = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        #expect(context.text.contains("PR aberto, falta o review."))
        h.scheduler.advance(by: 2)
        guard case .paste(_, let prompt)? = h.terminal.events.dropLast().last else { Issue.record("sem retomada"); return }
        #expect(prompt.hasPrefix(Handoff.resumePromptStart))
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "new", "prompt": .string(prompt)])
        #expect(h.records.map(\.kind) == [.recycle, .delayed, .resumed])
    }

    /// A: past the late window the recycle ends as failed, said to the owner.
    @Test func clearThatNeverRunsFailsAfterTheWindow() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 16 * 60)
        #expect(h.records.map(\.kind) == [.recycle, .delayed, .failed])
        #expect(h.notifier.posts.contains { $0.0.hasPrefix("Reciclagem não terminou") })
    }

    /// B: a message that came by another way (Claude Code's own SendMessage) right before the
    /// recycle: the transcript shows it, and the recycle waits for the next end of turn.
    @Test func aMessageInTheTranscriptDefersTheRecycle() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        try h.appendTranscript("old", [["type": "assistant", "message": ["stop_reason": "end_turn"]]])
        #expect(h.call("recycle_self", from: s).ok)
        h.screen(s, input: "")
        _ = h.hook(s, ["hook_event_name": "Stop", "session_id": "old"])
        h.scheduler.advance(by: 1)
        try h.appendTranscript("old", [["type": "user", "message": ["content": "<teammate-message>pare</teammate-message>"]]])
        h.scheduler.advance(by: 2)
        #expect(!h.terminal.events.contains(.type(s.terminalName, "/clear")))
        #expect(h.records.map(\.kind) == [.deferred])
        #expect(s.recycle?.text == "reciclagem agendada para o fim do turno")
        #expect(h.notifier.posts.contains { $0.0.hasPrefix("Reciclagem adiada") })

        // The turn that message started ends: now it goes.
        try h.appendTranscript("old", [["type": "assistant", "message": ["stop_reason": "end_turn"]]])
        _ = h.hook(s, ["hook_event_name": "Stop", "session_id": "old"])
        h.scheduler.advance(by: 2.5)
        #expect(h.terminal.events.last == .type(s.terminalName, "/clear"))
    }

    /// B: the message lands between typing /clear and Enter: no Enter, the /clear is erased.
    @Test func aMessageBetweenTypingAndEnterTakesTheClearBack() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        try h.appendTranscript("old", [["type": "queue-operation", "operation": "enqueue"]])
        h.scheduler.advance(by: 0.4)
        #expect(!h.terminal.events.contains(.enter(s.terminalName)))
        #expect(h.terminal.typed(s.terminalName) == "")
        #expect(h.records.map(\.kind) == [.deferred])
        #expect(h.daemon.recycler.isBusy(s))
    }

    /// B: someone typed after the /clear in the moment before Enter: the /clear goes, their text stays.
    @Test func textTypedAfterTheClearKeepsTheTextOnly() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.terminal.inputs[s.terminalName, default: ""] += " e mais isto"
        h.scheduler.advance(by: 0.4)
        #expect(!h.terminal.events.contains(.enter(s.terminalName)))
        #expect(h.terminal.typed(s.terminalName) == " e mais isto")
        #expect(h.records.map(\.kind) == [.deferred])
    }

    /// C: the status line told of the new conversation before SessionStart: the context still goes.
    @Test func contextStillGoesWhenTheStatusLineCameFirst() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 0.4)
        _ = h.daemon.handle(IPCRequest(kind: .statusLine, session: s.id.uuidString, payload: ["session_id": "new"]))
        let context = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        #expect(context.text.contains("PR aberto, falta o review."))
    }

    /// C: a turn the hooks saw only working (a message by another way) and that ends without Stop
    /// (an API error) still lets the resume prompt go.
    @Test func resumeGoesAfterATurnThatEndsWithoutStop() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 0.4)
        _ = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        h.scheduler.advance(by: 1)
        _ = h.hook(s, ["hook_event_name": "PostToolUse", "session_id": "new"])
        h.scheduler.advance(by: 1)
        #expect(!h.terminal.events.contains { if case .paste = $0 { return true } else { return false } })
        _ = h.hook(s, ["hook_event_name": "StopFailure", "session_id": "new", "error_type": "server_error"])
        h.scheduler.advance(by: 61)
        guard case .paste(_, let prompt)? = h.terminal.events.dropLast().last else { Issue.record("sem retomada"); return }
        #expect(prompt.hasPrefix(Handoff.resumePromptStart))
    }

    /// C: the same, with the resume prompt already pasted and sent behind that message.
    @Test func resumeGoesAgainAfterATurnThatEndsWithoutStop() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 0.4)
        _ = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        h.scheduler.advance(by: 2)
        let pastes = h.terminal.events.filter { if case .paste = $0 { return true } else { return false } }.count
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "new", "prompt": "[recado] outra coisa"])
        _ = h.hook(s, ["hook_event_name": "StopFailure", "session_id": "new", "error_type": "server_error"])
        h.scheduler.advance(by: 61)
        #expect(h.terminal.events.filter { if case .paste = $0 { return true } else { return false } }.count == pastes + 1)
    }

    /// C: another message got in before the resume prompt. That is not a resume: the prompt goes
    /// when that turn ends.
    @Test func anotherPromptIsNotTheResume() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 0.4)
        _ = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        h.scheduler.advance(by: 1)
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "new", "prompt": "[recado] não espere o run, pare"])
        h.scheduler.advance(by: 60)
        #expect(h.records.map(\.kind) == [.recycle])
        #expect(!h.terminal.events.contains { if case .paste = $0 { return true } else { return false } })
        _ = h.hook(s, ["hook_event_name": "Stop", "session_id": "new"])
        h.scheduler.advance(by: 2.5)
        guard case .paste(_, let prompt)? = h.terminal.events.last else { Issue.record("sem retomada"); return }
        #expect(prompt.hasPrefix(Handoff.resumePromptStart))
        h.scheduler.advance(by: 0.5)
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "new", "prompt": .string(prompt)])
        #expect(h.records.map(\.kind) == [.recycle, .resumed])
    }

    /// D: the daemon restarts after the /clear. The phase comes back from disk, and the new
    /// conversation still gets the Passagem and the resume prompt.
    @Test func restartAfterTheClearFinishesTheRecycle() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 0.4)
        let again = try h.restart()
        let back = try #require(again.session(s.id))
        #expect(again.recycler.isBusy(back))
        let context = again.handle(IPCRequest(kind: .hook, session: s.id.uuidString,
                                              payload: ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"],
                                              launch: String(back.record.launch)))
        #expect(context.text.contains("PR aberto, falta o review."))
        h.scheduler.advance(by: 2)
        guard case .paste(_, let prompt)? = h.terminal.events.dropLast().last else { Issue.record("sem retomada"); return }
        _ = again.handle(IPCRequest(kind: .hook, session: s.id.uuidString,
                                    payload: ["hook_event_name": "UserPromptSubmit", "session_id": "new", "prompt": .string(prompt)],
                                    launch: String(back.record.launch)))
        #expect(h.records.map(\.kind) == [.recycle, .resumed])
    }

    /// D: a restart with /clear typed and not sent takes it back and says so.
    @Test func restartWithTheClearTypedTakesItBack() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        let again = try h.restart()
        #expect(h.terminal.typed(s.terminalName) == "")
        #expect(!h.terminal.events.contains(.enter(s.terminalName)))
        #expect(again.session(s.id).map { again.recycler.isBusy($0) } == false)
        #expect(h.notifier.posts.contains { $0.0.hasPrefix("Reciclagem não terminou") })
    }

    /// E: an old Passagem above a new one, edits after the call, and a Passagem too big for a hook.
    @Test func onlyTheLatestPassagemCopiedAtTheClear() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        try h.writePassagem(body: "nova", before: "\(Harness.title(h.scheduler.now.addingTimeInterval(-9 * 3600)))\nvelha: checkout --detach\n\n")
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "old"])
        #expect(h.call("recycle_self", from: s).ok)
        // Written after the call, before the turn ended: it goes too.
        try h.writePassagem(body: "nova, com o que mudou depois", before: "\(Harness.title(h.scheduler.now.addingTimeInterval(-9 * 3600)))\nvelha: checkout --detach\n\n")
        h.screen(s, input: "")
        _ = h.hook(s, ["hook_event_name": "Stop", "session_id": "old"])
        h.scheduler.advance(by: 3)
        let context = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"]).text
        #expect(context.contains("nova, com o que mudou depois"))
        #expect(!context.contains("velha"))
    }

    @Test func aBigPassagemGoesWholeByFile() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        let body = (1...600).map { "linha \($0) da passagem, com o detalhe que não pode faltar" }.joined(separator: "\n")
        try h.writePassagem(body: body)
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 0.4)
        let reply = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        let context = try #require(JSONValue.parse(Data(reply.text.utf8))?["hookSpecificOutput"]?["additionalContext"]?.stringValue)
        #expect(context.count <= Handoff.contextLimit)
        let file = try #require(h.records.first?.handoffFile)
        #expect(context.contains("Leia o arquivo \(file) inteiro"))
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("linha 600 da passagem"))
    }

    // MARK: The check after a resume

    private func resumed(_ h: Harness, _ s: ServerSession) throws -> String {
        try h.writePassagem()
        h.screen(s, input: "")
        #expect(h.call("recycle_session", ["session": .string(s.shortId)]).ok)
        h.scheduler.advance(by: 0.4)
        _ = h.hook(s, ["hook_event_name": "SessionStart", "session_id": "new", "source": "clear"])
        h.scheduler.advance(by: 2)
        guard case .paste(_, let prompt)? = h.terminal.events.dropLast().last else { throw CancellationError() }
        _ = h.hook(s, ["hook_event_name": "UserPromptSubmit", "session_id": "new", "prompt": .string(prompt),
                       "transcript_path": .string(h.accountDir.appendingPathComponent("projects/p/new.jsonl").path)])
        return prompt
    }

    @Test func aResumeThatWentToWorkIsConferida() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        let prompt = try resumed(h, s)
        try h.appendTranscript("new", [
            ["type": "user", "message": ["role": "user", "content": .string(prompt)]],
            ["type": "assistant", "message": ["content": .array([["type": "tool_use", "name": "Read", "input": ["file_path": "/x"]]])]],
        ])
        h.scheduler.advance(by: 5 * 60)
        let check = try #require(h.records.last)
        #expect(check.kind == .verified)
        #expect(check.verdict == .conferida)
    }

    @Test func aResumeThatDidNothingIsQuebrada() throws {
        let h = try Harness()
        let s = try h.openedSession(conversation: "old")
        let prompt = try resumed(h, s)
        try h.appendTranscript("new", [["type": "user", "message": ["role": "user", "content": .string(prompt)]]])
        s.attention = false
        h.scheduler.advance(by: 5 * 60)
        let check = try #require(h.records.last)
        #expect(check.verdict == .quebrada)
        #expect(check.reason?.contains("chamada de ferramenta") == true)
        #expect(s.attention)
        #expect(h.notifier.posts.contains { $0.0.hasPrefix("Retomada quebrada") })
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
