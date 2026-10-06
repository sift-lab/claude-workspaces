import Foundation
import Testing
@testable import WorkspacesCore

@Suite struct HookEventTests {
    private func payload(_ event: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string("abc"), "cwd": .string("/tmp/x")]
        o.merge(extra) { _, new in new }
        return .object(o)
    }

    @Test func notificationMeansWaitingWithMessage() {
        let update = HookEvent.update(from: payload("Notification", extra: ["message": .string("Claude needs your permission to use Bash")]))
        #expect(update?.status == .waiting)
        #expect(update?.message == "Claude needs your permission to use Bash")
        #expect(update?.claudeSessionId == "abc")
        #expect(update?.cwd == "/tmp/x")
    }

    @Test func eventsMapToStates() {
        #expect(HookEvent.update(from: payload("SessionStart"))?.status == .idle)
        #expect(HookEvent.update(from: payload("UserPromptSubmit"))?.status == .working)
        #expect(HookEvent.update(from: payload("UserPromptSubmit"))?.clearsActivity == true)
        #expect(HookEvent.update(from: payload("PostToolUse"))?.status == .working)
        #expect(HookEvent.update(from: payload("Stop"))?.status == .done)
        #expect(HookEvent.update(from: payload("SessionEnd"))?.status == .ended)
    }

    @Test func unknownEventKeepsStateButCarriesIds() {
        let update = HookEvent.update(from: payload("PreCompact"))
        #expect(update?.status == nil)
        #expect(update?.claudeSessionId == "abc")
    }

    @Test func payloadWithoutEventIsIgnored() {
        #expect(HookEvent.update(from: .object([:])) == nil)
    }

    @Test func everySubscribedEventHasAState() {
        for event in HookEvent.subscribed {
            #expect(HookEvent.update(from: payload(event))?.status != nil, "\(event)")
        }
    }
}

@Suite struct MCPServerTests {
    private func request(_ method: String, id: Int = 1, params: JSONValue = .object([:])) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    private func toolNames(_ reply: JSONValue?) -> [String] {
        guard case .array(let tools)? = reply?["result"]?["tools"] else { return [] }
        return tools.compactMap { $0["name"]?.stringValue }
    }

    @Test func initializeEchoesKnownVersion() {
        let server = MCPServer(enabledTools: { nil }, callTool: { _, _ in ToolResult(text: "") })
        let reply = server.handle(request("initialize", params: .object(["protocolVersion": .string("2025-06-18")])))
        #expect(reply?["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(reply?["result"]?["capabilities"]?["tools"] != nil)
    }

    @Test func initializeFallsBackForUnknownVersion() {
        let server = MCPServer(enabledTools: { nil }, callTool: { _, _ in ToolResult(text: "") })
        let reply = server.handle(request("initialize", params: .object(["protocolVersion": .string("1999-01-01")])))
        #expect(reply?["result"]?["protocolVersion"] == .string(MCPServer.supportedVersions[0]))
    }

    @Test func notificationsGetNoReply() {
        let server = MCPServer(enabledTools: { nil }, callTool: { _, _ in ToolResult(text: "") })
        #expect(server.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])) == nil)
    }

    @Test func listRespectsEnabledTools() {
        let server = MCPServer(enabledTools: { ["set_status"] }, callTool: { _, _ in ToolResult(text: "") })
        #expect(toolNames(server.handle(request("tools/list"))) == ["set_status"])
    }

    @Test func listShowsAllWhenAppUnreachable() {
        let server = MCPServer(enabledTools: { nil }, callTool: { _, _ in ToolResult(text: "") })
        #expect(toolNames(server.handle(request("tools/list"))).count == WorkspaceTools.all.count)
    }

    @Test func callForwardsNameAndArguments() {
        var seen: (String, JSONValue)?
        let server = MCPServer(enabledTools: { nil }, callTool: { name, args in
            seen = (name, args)
            return ToolResult(text: "feito", isError: true)
        })
        let args = JSONValue.object(["text": .string("rodando os testes")])
        let reply = server.handle(request("tools/call", id: 7, params: .object(["name": .string("set_status"), "arguments": args])))
        #expect(seen?.0 == "set_status")
        #expect(seen?.1 == args)
        #expect(reply?["id"] == .number(7))
        #expect(reply?["result"]?["isError"] == .bool(true))
        guard case .array(let content)? = reply?["result"]?["content"] else { Issue.record("no content"); return }
        #expect(content.first?["text"] == .string("feito"))
    }

    @Test func unknownToolAndMethodAreErrors() {
        let server = MCPServer(enabledTools: { nil }, callTool: { _, _ in ToolResult(text: "") })
        #expect(server.handle(request("tools/call", params: .object(["name": .string("rm_rf")])))?["error"] != nil)
        #expect(server.handle(request("resources/list"))?["error"]?["code"] == .number(-32601))
    }
}

@Suite struct ClaudeLaunchTests {
    @Test func quotesSingleQuotes() {
        #expect(ClaudeLaunch.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func freshSessionPassesNameWorktreeAndPrompt() {
        let script = ClaudeLaunch.shellScript(.init(claudeCommand: "claude", projectPath: "/p/a b", settingsFile: "/s.json",
                                                    mcpConfigFile: "/m.json", name: "app main", worktree: "ws-1", prompt: "oi"))
        #expect(script.hasPrefix("cd '/p/a b' && claude --settings '/s.json' --mcp-config '/m.json' --worktree 'ws-1' --name 'app main' -- 'oi';"))
        #expect(script.hasSuffix("exec \"${SHELL:-/bin/zsh}\" -l"))
    }

    @Test func resumeSkipsNameWorktreeAndPrompt() {
        let script = ClaudeLaunch.shellScript(.init(claudeCommand: "claude", projectPath: "/p", settingsFile: "/s", mcpConfigFile: "/m",
                                                    name: "x", resumeId: "abc", worktree: "ws-1", prompt: "oi"))
        #expect(script.contains("--resume 'abc'"))
        #expect(!script.contains("--name"))
        #expect(!script.contains("--worktree"))
        #expect(!script.contains("'oi'"))
    }

    @Test func settingsHookEveryEventWithHelper() {
        let settings = ClaudeLaunch.settingsJSON(helperPath: "/Apps/W.app/Contents/MacOS/Workspaces")
        for event in HookEvent.subscribed {
            guard case .array(let entries)? = settings["hooks"]?[event],
                  case .array(let hooks)? = entries.first?["hooks"] else { Issue.record(Comment(rawValue: event)); continue }
            #expect(hooks.first?["command"] == .string("'/Apps/W.app/Contents/MacOS/Workspaces' hook"))
        }
    }

    @Test func mcpConfigRunsHelperInMcpMode() {
        let config = ClaudeLaunch.mcpConfigJSON(helperPath: "/bin/W")
        #expect(config["mcpServers"]?["workspaces"]?["command"] == .string("/bin/W"))
        #expect(config["mcpServers"]?["workspaces"]?["args"] == .array([.string("mcp")]))
    }
}

@Suite struct ProjectMatchTests {
    @Test func picksTheMostSpecificProjectAndKeepsHomeExact() {
        let home = Project(name: "pasta pessoal", path: "/Users/g")
        let app = Project(name: "app", path: "/Users/g/dev/app")
        let mobile = Project(name: "mobile", path: "/Users/g/dev/app/mobile")
        let config = AppConfig(workspaces: [Workspace(name: "Geral", projects: [home]), Workspace(name: "Sift", projects: [app, mobile])])
        #expect(config.project(containing: "/Users/g/dev/app/.claude/worktrees/x", home: "/Users/g")?.project.name == "app")
        #expect(config.project(containing: "/Users/g/dev/app/mobile/ios", home: "/Users/g")?.project.name == "mobile")
        #expect(config.project(containing: "/Users/g", home: "/Users/g")?.workspace.name == "Geral")
        #expect(config.project(containing: "/Users/g/elsewhere", home: "/Users/g") == nil)
        #expect(config.project(containing: "/Users/g/dev/apple", home: "/Users/g") == nil)
    }
}

@Suite struct ConfigTests {
    @Test func roundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConfigStore(url: url)
        var config = AppConfig()
        config.workspaces = [Workspace(name: "Trabalho", projects: [Project(name: "central", path: "/p", newSessionMode: .worktree, sessionsOnOpen: 3,
                                                                              savedSessions: [SavedSession(id: UUID(), label: "main", claudeSessionId: "c1", cwd: "/p"),
                                                                                              SavedSession(id: UUID(), label: "Terminal · main", cwd: "/p", terminal: true)])])]
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test func missingFileIsEmpty() throws {
        let store = ConfigStore(url: URL(fileURLWithPath: "/nonexistent/\(UUID()).json"))
        #expect(try store.load() == AppConfig())
    }

    @Test func handWrittenConfigGetsDefaults() throws {
        let json = #"{"workspaces":[{"name":"Sift","projects":[{"path":"/Users/x/sift-mobile"}]}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let project = try #require(config.workspaces.first?.projects.first)
        #expect(project.name == "sift-mobile")
        #expect(project.sessionsOnOpen == 1)
        #expect(project.newSessionMode == .folder)
        #expect(config.disabledTools == ["close_session"])
    }

    @Test func savedSessionWithoutTerminalFlagIsClaude() throws {
        let json = #"{"id":"6F1C2A4E-0000-4000-8000-000000000001","label":"main","claudeSessionId":"c1"}"#
        let saved = try JSONDecoder().decode(SavedSession.self, from: Data(json.utf8))
        #expect(saved.terminal == false)
        #expect(saved.claudeSessionId == "c1")
    }

    @Test func brokenFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{nope".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ConfigStore(url: url).load() }
    }
}

@Suite struct RelativeTimeTests {
    @Test func formats() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(RelativeTime.short(since: now.addingTimeInterval(-30), now: now) == "agora")
        #expect(RelativeTime.short(since: now.addingTimeInterval(-240), now: now) == "4 min")
        #expect(RelativeTime.short(since: now.addingTimeInterval(-7200), now: now) == "2 h")
        #expect(RelativeTime.short(since: now.addingTimeInterval(-3 * 86400), now: now) == "3 d")
    }
}

@Suite struct IPCTests {
    /// A real socket round trip with a tiny server, the same framing the app uses.
    @Test func clientTalksToSocket() throws {
        let path = "/tmp/ws-test-\(getpid()).sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try UnixSocket.address(for: path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        listen(fd, 1)
        defer { close(fd); unlink(path) }

        let thread = Thread {
            let client = accept(fd, nil, nil)
            let line = UnixSocket.readLine(fd: client) ?? Data()
            let request = try? JSONDecoder().decode(IPCRequest.self, from: line)
            var reply = try! JSONEncoder().encode(IPCResponse(ok: true, text: "tool=\(request?.tool ?? "")"))
            reply.append(0x0A)
            _ = UnixSocket.writeAll(fd: client, reply)
            close(client)
        }
        thread.start()

        let response = try IPCClient.send(IPCRequest(kind: .tool, session: "s", tool: "notify"), socketPath: path, timeout: 2)
        #expect(response == IPCResponse(ok: true, text: "tool=notify"))
    }

    @Test func clientFailsWithoutServer() {
        #expect(throws: (any Error).self) {
            try IPCClient.send(IPCRequest(kind: .tools, session: nil), socketPath: "/tmp/ws-none-\(UUID()).sock", timeout: 1)
        }
    }
}

@Suite struct ConversationTests {
    @Test func onlyAPromptStartsAConversation() {
        for event in HookEvent.subscribed {
            let update = HookEvent.update(from: .object(["hook_event_name": .string(event)]))
            #expect(update?.startsConversation == (event == "UserPromptSubmit"), "\(event)")
        }
    }
}

@Suite struct ExtraArgumentsTests {
    @Test func extraArgumentsGoRawAfterHelperFlags() {
        let script = ClaudeLaunch.shellScript(.init(claudeCommand: "claude", projectPath: "/p", settingsFile: "/s", mcpConfigFile: "/m",
                                                    resumeId: "abc", extraArguments: " --add-dir /x/api "))
        #expect(script.contains("--mcp-config '/m' --add-dir /x/api --resume 'abc'"))
    }

    @Test func emptyExtraArgumentsAddNothing() {
        let script = ClaudeLaunch.shellScript(.init(claudeCommand: "claude", projectPath: "/p", settingsFile: "/s", mcpConfigFile: "/m"))
        #expect(script.contains("--mcp-config '/m';"))
    }
}

@Suite struct SleepPolicyTests {
    let policy = SleepPolicy(freezeAfterMinutes: 2, hibernateAfterMinutes: 30)

    private func session(_ status: SessionStatus = .done, quiet minutes: Double, state: SleepState = .awake, attention: Bool = false,
                         visible: Bool = false, conversation: Bool = true, running: Bool = false) -> SleepPolicy.Session {
        .init(status: status, attention: attention, visible: visible, quietFor: minutes * 60, state: state,
              hasConversation: conversation, runningCommand: running)
    }

    @Test func freezesThenHibernates() {
        #expect(policy.action(for: session(quiet: 1)) == .none)
        #expect(policy.action(for: session(quiet: 3)) == .freeze)
        #expect(policy.action(for: session(quiet: 3, state: .frozen)) == .none)
        #expect(policy.action(for: session(quiet: 31, state: .frozen)) == .hibernate)
        #expect(policy.action(for: session(.idle, quiet: 31)) == .hibernate)
    }

    @Test func neverTouchesWhatNeedsThePerson() {
        #expect(policy.action(for: session(.waiting, quiet: 60)) == .none)
        #expect(policy.action(for: session(.working, quiet: 60)) == .none)
        #expect(policy.action(for: session(quiet: 60, attention: true)) == .none)
        #expect(policy.action(for: session(quiet: 60, visible: true)) == .none)
        #expect(policy.action(for: session(quiet: 60, running: true)) == .none)
        #expect(policy.action(for: session(.ended, quiet: 60)) == .none)
        #expect(policy.action(for: session(quiet: 60, state: .hibernated)) == .none)
    }

    @Test func withoutConversationOnlyFreezes() {
        #expect(policy.action(for: session(quiet: 60, conversation: false)) == .freeze)
        #expect(policy.action(for: session(quiet: 60, state: .frozen, conversation: false)) == .none)
    }

    @Test func zeroTurnsOff() {
        let off = SleepPolicy(freezeAfterMinutes: 0, hibernateAfterMinutes: 0)
        #expect(off.action(for: session(quiet: 600)) == .none)
        let onlyHibernate = SleepPolicy(freezeAfterMinutes: 0, hibernateAfterMinutes: 30)
        #expect(onlyHibernate.action(for: session(quiet: 10)) == .none)
        #expect(onlyHibernate.action(for: session(quiet: 31)) == .hibernate)
    }
}

@Suite struct KeepAwakePolicyTests {
    let policy = KeepAwakePolicy(staleAfter: 30 * 60)

    private func session(_ status: SessionStatus = .working, quiet minutes: Double = 1, running: Bool = false) -> KeepAwakePolicy.Session {
        .init(status: status, quietFor: minutes * 60, runningCommand: running)
    }

    @Test func holdsWhileAnySessionWorks() {
        #expect(policy.holds([session()]))
        #expect(policy.holds([session(.done), session(.idle), session()]))
    }

    @Test func releasesWhenNothingWorks() {
        #expect(!policy.holds([]))
        #expect(!policy.holds([session(.done), session(.idle), session(.waiting), session(.ended)]))
        #expect(!policy.holds([session(.done, running: true)]))
    }

    @Test func staleWorkingHoldsOnlyWithACommandUnderIt() {
        #expect(!policy.holds([session(quiet: 31)]))
        #expect(policy.holds([session(quiet: 31, running: true)]))
    }
}

@Suite struct ShellSupportTests {
    @Test func splitsPlainWordsAndQuotes() {
        #expect(ShellSupport.words("claude") == ["claude"])
        #expect(ShellSupport.words("  --add-dir /a/b   --model opus ") == ["--add-dir", "/a/b", "--model", "opus"])
        #expect(ShellSupport.words("--add-dir '/a b' \"c d\" e\\ f") == ["--add-dir", "/a b", "c d", "e f"])
        #expect(ShellSupport.words("") == [])
        #expect(ShellSupport.words("a~b x#y") == ["a~b", "x#y"])
    }

    @Test func leavesShellSyntaxToTheShell() {
        #expect(ShellSupport.words("--add-dir $HOME/x") == nil)
        #expect(ShellSupport.words("--add-dir ~/x") == nil)
        #expect(ShellSupport.words("a | b") == nil)
        #expect(ShellSupport.words("\"$(pwd)\"") == nil)
        #expect(ShellSupport.words("'open") == nil)
        #expect(ShellSupport.words("x # comment") == nil)
    }

    @Test func parsesEnvSkippingJunk() {
        let data = Data("PATH=/bin:/usr/bin\0EMPTY=\0EQ=a=b\0junk\0".utf8)
        #expect(ShellSupport.parseEnvironment(data) == ["PATH": "/bin:/usr/bin", "EMPTY": "", "EQ": "a=b"])
    }

    @Test func resolvesInPathOrder() {
        let found = ShellSupport.resolve("claude", path: "/a:/b:/c", isExecutable: { $0 == "/b/claude" || $0 == "/c/claude" })
        #expect(found == "/b/claude")
        #expect(ShellSupport.resolve("/x/claude", path: nil, isExecutable: { $0 == "/x/claude" }) == "/x/claude")
        #expect(ShellSupport.resolve("claude", path: "/a", isExecutable: { _ in false }) == nil)
    }
}

@Suite struct ArgvTests {
    @Test func argvHasNoQuotingAndKeepsOrder() {
        let o = ClaudeLaunch.Options(claudeCommand: "claude", projectPath: "/p", settingsFile: "/s s.json", mcpConfigFile: "/m.json",
                                     name: "app it's", worktree: "ws-1", prompt: "oi", extraArguments: "--add-dir '/x y'")
        #expect(ClaudeLaunch.argv(o) == ["claude", "--settings", "/s s.json", "--mcp-config", "/m.json", "--add-dir", "/x y",
                                         "--worktree", "ws-1", "--name", "app it's", "--", "oi"])
    }

    @Test func promptThatLooksLikeAFlagStaysAPrompt() {
        let o = ClaudeLaunch.Options(claudeCommand: "claude", projectPath: "/p", settingsFile: "/s", mcpConfigFile: "/m",
                                     prompt: "--dangerously-skip-permissions")
        #expect(ClaudeLaunch.argv(o)?.suffix(2) == ["--", "--dangerously-skip-permissions"])
        #expect(ClaudeLaunch.shellScript(o).contains("-- '--dangerously-skip-permissions';"))
    }

    @Test func argvGivesUpOnShellSyntax() {
        let o = ClaudeLaunch.Options(claudeCommand: "claude", projectPath: "/p", settingsFile: "/s", mcpConfigFile: "/m",
                                     extraArguments: "--add-dir ~/api")
        #expect(ClaudeLaunch.argv(o) == nil)
    }

    @Test func httpConfigCarriesSessionAndToken() {
        let c = ClaudeLaunch.mcpHTTPConfigJSON(url: "http://127.0.0.1:5000/mcp", session: "S1", token: "T")
        #expect(c["mcpServers"]?["workspaces"]?["type"] == .string("http"))
        #expect(c["mcpServers"]?["workspaces"]?["headers"]?[ClaudeLaunch.sessionHeader] == .string("S1"))
        #expect(c["mcpServers"]?["workspaces"]?["headers"]?["Authorization"] == .string("Bearer T"))
    }
}

@Suite struct HTTPParserTests {
    @Test func parsesPostWithBody() {
        let raw = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nX-Workspaces-Session: abc\r\n\r\n{\"a\"}extra".utf8)
        guard case .request(let r, let consumed) = HTTPParser.parse(raw) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST")
        #expect(r.path == "/mcp")
        #expect(r.headers["x-workspaces-session"] == "abc")
        #expect(r.body == Data("{\"a\"".utf8))
        #expect(consumed == raw.count - 6)
    }

    @Test func waitsForTheWholeBody() {
        #expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)) == .needMore)
        #expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-".utf8)) == .needMore)
    }

    @Test func rejectsWhatItDoesNotSupport() {
        #expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)) == .invalid)
        #expect(HTTPParser.parse(Data("GARBAGE\r\n\r\n".utf8)) == .invalid)
    }

    @Test func parsesTwoPipelinedRequests() {
        let one = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
        let raw = Data((one + one).utf8)
        guard case .request(_, let consumed) = HTTPParser.parse(raw) else { Issue.record("first"); return }
        guard case .request(let second, _) = HTTPParser.parse(raw.subdata(in: consumed..<raw.count)) else { Issue.record("second"); return }
        #expect(second.body == Data("{}".utf8))
    }
}

@Suite struct ReviewFixTests {
    @Test func idleReminderIsNotWaiting() {
        let idle = JSONValue.object(["hook_event_name": .string("Notification"), "notification_type": .string("idle_prompt"),
                                     "message": .string("Claude is waiting for your input")])
        #expect(HookEvent.update(from: idle)?.status == nil)
        let untyped = JSONValue.object(["hook_event_name": .string("Notification"), "message": .string("Claude is waiting for your input")])
        #expect(HookEvent.update(from: untyped)?.status == nil)
        let permission = JSONValue.object(["hook_event_name": .string("Notification"), "notification_type": .string("permission_prompt"),
                                           "message": .string("Claude needs your permission to use Bash")])
        #expect(HookEvent.update(from: permission)?.status == .waiting)
    }

    @Test func backslashInDoubleQuotesFollowsPOSIX() {
        #expect(ShellSupport.words(#"--append-system-prompt "use \d+ no regex""#) == ["--append-system-prompt", #"use \d+ no regex"#])
        #expect(ShellSupport.words(#""a \" b \\ c""#) == [#"a " b \ c"#])
        #expect(ShellSupport.words(#"'keep \n'"#) == [#"keep \n"#])
    }

    @Test func hookRequestCarriesLaunch() throws {
        let request = IPCRequest(kind: .hook, session: "s", payload: .null, launch: "3")
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.launch == "3")
    }
}
