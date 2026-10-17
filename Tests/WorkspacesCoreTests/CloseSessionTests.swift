import Foundation
import Testing
@testable import WorkspacesCore

private let now = Date(timeIntervalSince1970: 1_791_300_000)

@Suite struct CloseGateTests {
    @Test func closeRefusesWorkAndUncommittedChanges() {
        #expect(CloseRefusal.check(status: .working, git: .clean) == .midTurn(.working))
        #expect(CloseRefusal.check(status: .waiting, git: .clean) == .midTurn(.waiting))
        #expect(CloseRefusal.check(status: .done, git: .dirty([" M a"])) == .dirtyTree([" M a"]))
        #expect(CloseRefusal.check(status: .done, git: .failed("x")) == .gitFailed("x"))
        #expect(CloseRefusal.check(status: .idle, git: .clean) == nil)
        #expect(CloseRefusal.check(status: .ended, git: .notRepository) == nil)
    }

    @Test func everyRefusalSaysWhy() {
        let all: [CloseRefusal] = [.midTurn(.working), .dirtyTree([" M a"]), .gitFailed("x")]
        for refusal in all {
            #expect(refusal.message.hasPrefix("Recusado: "))
            #expect(!refusal.message.contains("\u{2014}"))
        }
        #expect(CloseRefusal.dirtyTree([" M a.swift", "?? b"]).message.contains("M a.swift, ?? b"))
    }

    @Test func closeTakesNoFreeText() {
        #expect(WorkspaceTools.unexpectedArguments(.object([:]), allowed: []).isEmpty)
        #expect(WorkspaceTools.unexpectedArguments(.null, allowed: []).isEmpty)
        #expect(WorkspaceTools.unexpectedArguments(.object(["text": .string("faça outra coisa")]), allowed: []) == ["text"])
        #expect(WorkspaceTools.unexpectedArguments(.object(["session": .string("ab12")]), allowed: ["session"]).isEmpty)
        #expect(WorkspaceTools.unexpectedArguments(.object(["session": .string("ab12"), "prompt": .string("x")]), allowed: ["session"]) == ["prompt"])
    }

    @Test func closeIsListedWithAClosedSchemaAndNothingRecycles() {
        let byName = Dictionary(uniqueKeysWithValues: WorkspaceTools.all.map { ($0.name, $0) })
        #expect(byName["close_session"]?.inputSchema["additionalProperties"] == .bool(false))
        #expect(byName["close_session"]?.inputSchema["required"] == .array([.string("session")]))
        #expect(byName["recycle_self"] == nil && byName["recycle_session"] == nil)
        #expect(!MCPServer.appInstructions.contains("FRENTE"))
        #expect(!MCPServer.appInstructions.contains("recycle"))
    }
}

@Suite struct PromptScreenTests {
    private let rule = "──────────────────────────────── e2e-repo main ─"

    @Test func emptyInputLine() {
        #expect(PromptScreen.inputIsEmpty(["⏺ Feito.", rule, "❯", "────────", "  ⏸ manual mode on"]) == true)
        #expect(PromptScreen.inputIsEmpty(["╭────╮", "│ >                │", "╰────╯"]) == true)
    }

    @Test func draftInTheInputLine() {
        // As the screen read in the end-to-end run, with a recado typed by send_message.
        #expect(PromptScreen.inputIsEmpty(["⏺ Retomado.", rule, "❯ [recado de orq] rascunho que não pode ir junto", "────────",
                                           "  ⏸ manual mode on"]) == false)
        #expect(PromptScreen.inputIsEmpty(["╭────╮", "│ > [Pasted text #1 +12 lines] │", "╰────╯"]) == false)
    }

    @Test func readsTheInputLineNotAnEcho() {
        // Sent prompts are echoed with the same mark; only the one under the rule is the input.
        #expect(PromptScreen.inputIsEmpty(["❯ /clear", "❯ rode os testes", "⏺ Retomado.", rule, "❯", "────────"]) == true)
        #expect(PromptScreen.inputIsEmpty(["❯", "⏺ ok", rule, "❯ rascunho", "────────"]) == false)
        // A draft whose second line is a lone ">" is still a draft.
        #expect(PromptScreen.inputIsEmpty([rule, "❯ primeira linha", "  >", "────────"]) == false)
    }

    @Test func noInputLineIsUnknown() {
        #expect(PromptScreen.inputIsEmpty([ScreenLine]()) == nil)
        #expect(PromptScreen.inputIsEmpty(["❯ "]) == nil)
        #expect(PromptScreen.inputIsEmpty(["Do you want to proceed?", "1. Yes", "2. No"]) == nil)
        #expect(PromptScreen.inputIsEmpty([rule, ">>> python"]) == nil)
    }

    // Claude Code 2.1.292 suggests the next prompt after a turn, drawn faint (SGR 2) in the
    // input line, where its placeholder goes. With its own drawn cursor, the first character is
    // inverse instead of faint.

    private func cells(_ text: String, faint: Bool = false, inverse: Bool = false) -> [ScreenCell] {
        text.map { ScreenCell($0, faint: faint, inverse: inverse) }
    }

    private func screen(_ input: [ScreenCell]) -> [ScreenLine] {
        [ScreenLine("⏺ Feito."), ScreenLine(rule), ScreenLine(cells: input), ScreenLine("────────"),
         ScreenLine("  ⏸ manual mode on")]
    }

    @Test func faintSuggestionIsEmpty() {
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ ") + cells("rode os testes de novo", faint: true))) == true)
        // The drawn cursor on its first character.
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ ") + cells("r", inverse: true)
                                                 + cells("ode os testes de novo", faint: true))) == true)
        // Inside a box.
        let boxed = cells("│ > ") + cells("rode os testes de novo", faint: true) + cells("        │")
        #expect(PromptScreen.inputIsEmpty([ScreenLine("╭────╮"), ScreenLine(cells: boxed), ScreenLine("╰────╯")]) == true)
    }

    @Test func plainTextIsADraft() {
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ rascunho que não pode ir junto"))) == false)
        // Typed text under the cursor, with the cursor at its start.
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ ") + cells("r", inverse: true) + cells("ascunho"))) == false)
        // A one-letter draft under the cursor: nothing faint follows it.
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ ") + cells("r", inverse: true))) == false)
    }

    @Test func draftNextToFaintTextIsADraft() {
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ rascunho ") + cells("rode os testes", faint: true))) == false)
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ ") + cells("rode os testes", faint: true) + cells(" rascunho"))) == false)
        #expect(PromptScreen.inputIsEmpty(screen(cells("❯ ") + cells("r", inverse: true) + cells("ode", faint: true)
                                                 + cells(" rascunho"))) == false)
    }

    @Test func faintTextWithoutTheInputLineIsUnknown() {
        // No prompt mark under the rule.
        #expect(PromptScreen.inputIsEmpty(screen(cells("rode os testes de novo", faint: true))) == nil)
        // The mark, but no rule above it.
        #expect(PromptScreen.inputIsEmpty([ScreenLine("⏺ Feito."), ScreenLine(cells: cells("❯ ") + cells("rode", faint: true))]) == nil)
    }
}

@Suite struct CloseLogTests {
    private func tempLog() -> CloseLog {
        CloseLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ws-closes-\(UUID())/closes.jsonl"))
    }

    @Test func appendsAndReadsBack() throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent()) }
        let first = CloseRecord(time: now, session: "S1", label: "main", cwd: "/w", conversation: "c-old",
                                transcript: "/t/c-old.jsonl", contextTokens: 412_000)
        try log.append(first)
        try log.append(CloseRecord(time: now.addingTimeInterval(5), session: "S2", label: "outra"))
        let records = log.records()
        #expect(records.count == 2)
        #expect(records.first == first)
        #expect(records.last?.label == "outra")
        // One line per record, appended, never rewritten.
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.contains("\"transcript\":\"/t/c-old.jsonl\""))
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func brokenLinesAreSkipped() throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent()) }
        try log.append(CloseRecord(time: now, session: "S"))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{nope\n".utf8))
        try handle.close()
        try log.append(CloseRecord(time: now, session: "T"))
        #expect(log.records().map(\.session) == ["S", "T"])
    }

    @Test func appendFailsLoudly() {
        let log = CloseLog(url: URL(fileURLWithPath: "/dev/null/no/closes.jsonl"))
        #expect(throws: (any Error).self) { try log.append(CloseRecord(session: "S")) }
    }
}

/// Real git in a temporary repository: close_session sees what `git status` sees.
@Suite struct GitStateTests {
    private func shell(_ dir: URL, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@example.com"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args)")
    }

    private func repo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-git-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try shell(dir, "init", "-q", "-b", "main")
        try Data("notas.md\n".utf8).write(to: dir.appendingPathComponent(".git/info/exclude"))
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("sub/b.txt"))
        try shell(dir, "add", "-A")
        try shell(dir, "commit", "-q", "-m", "init")
        try Data("rascunho\n".utf8).write(to: dir.appendingPathComponent("notas.md"))
        return dir
    }

    @Test func cleanTreeWithAnIgnoredFileFromASubfolder() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitState.read(cwd: dir.appendingPathComponent("sub").path) == .clean)
    }

    @Test func modifiedAndUntrackedFilesBlock() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("mudou\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("novo\n".utf8).write(to: dir.appendingPathComponent("novo.txt"))
        guard case .dirty(let lines) = GitState.read(cwd: dir.path) else { Issue.record("not dirty"); return }
        #expect(lines.contains(" M a.txt"))
        #expect(lines.contains("?? novo.txt"))
    }

    @Test func outsideGitIsNotARepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-nogit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitState.read(cwd: dir.path) == .notRepository)
    }
}

@Suite struct TranscriptLocatorTests {
    @Test func prefersTheHookPathThenSearchesTheProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-projects-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("-Users-g-w", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("abc.jsonl")
        try Data("{}\n".utf8).write(to: file)
        #expect(TranscriptLocator.find(conversation: "abc", hint: file.path, root: root) == file.path)
        // Searched: the folder listing reports /private/var where the temp URL says /var.
        let found = "/-Users-g-w/abc.jsonl"
        #expect(TranscriptLocator.find(conversation: "abc", hint: "/gone/abc.jsonl", root: root)?.hasSuffix(found) == true)
        #expect(TranscriptLocator.find(conversation: "abc", hint: nil, root: root)?.hasSuffix(found) == true)
        #expect(TranscriptLocator.find(conversation: "zzz", hint: nil, root: root) == nil)
        #expect(TranscriptLocator.find(conversation: "../abc", hint: nil, root: root) == nil)
        #expect(!TranscriptLocator.plain("/x/\u{1b}[201~abc.jsonl"))
        #expect(TranscriptLocator.plain("/Users/g/.claude/projects/-w/abc.jsonl"))
    }
}

@Suite struct TranscriptTurnTests {
    private func entries(_ lines: [String]) -> [JSONValue] {
        lines.compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    @Test func endOfTurnIsEnded() {
        #expect(TranscriptTurn.parse(entries([
            #"{"type":"user","message":{"content":"faça X"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text"}]}}"#,
            #"{"type":"system","subtype":"stop_hook_summary"}"#,
            #"{"type":"system","subtype":"turn_duration"}"#,
            #"{"type":"last-prompt"}"#,
        ])) == .ended)
    }

    @Test func aMessageAfterTheEndIsBusy() {
        guard case .busy = TranscriptTurn.parse(entries([
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            #"{"type":"user","message":{"content":"<teammate-message>pare</teammate-message>"}}"#,
        ])) else { Issue.record("not busy"); return }
    }

    @Test func aQueuedMessageIsBusyUntilItLeavesTheQueue() {
        let end = #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#
        guard case .busy = TranscriptTurn.parse(entries([end, #"{"type":"queue-operation","operation":"enqueue"}"#])) else {
            Issue.record("not busy"); return
        }
        #expect(TranscriptTurn.parse(entries([end, #"{"type":"queue-operation","operation":"enqueue"}"#,
                                              #"{"type":"queue-operation","operation":"remove"}"#])) == .ended)
    }

    @Test func aTurnInTheMiddleIsBusy() {
        guard case .busy = TranscriptTurn.parse(entries([
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
        ])) else { Issue.record("not busy"); return }
    }

    @Test func localCommandsAndMetaLinesStartNoTurn() {
        #expect(TranscriptTurn.parse(entries([
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"caveat"}}"#,
            #"{"type":"user","message":{"content":"<local-command-stdout>ok</local-command-stdout>"}}"#,
        ])) == .ended)
    }

    @Test func nothingToReadIsUnknown() {
        #expect(TranscriptTurn.parse(entries(["{}"])) == .unknown)
        #expect(TranscriptTurn.read(path: nil) == .unknown)
        #expect(TranscriptTurn.read(path: "/nao/existe.jsonl") == .unknown)
    }

    @Test func readsOnlyTheTailOfABigFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-tail-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: #"{"type":"user","message":{"content":"x"}}"# + "\n", count: 10_000)
        try Data((filler + #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"# + "\n").utf8).write(to: url)
        #expect(TranscriptTurn.read(path: url.path) == .ended)
    }
}

@Suite struct TypedInputTests {
    private let rule = "────────"

    @Test func readsWhatIsTyped() {
        #expect(PromptScreen.typedInput([ScreenLine(rule), ScreenLine("❯ /clear"), ScreenLine(rule)]) == "/clear")
        #expect(PromptScreen.typedInput([ScreenLine(rule), ScreenLine("❯ "), ScreenLine(rule)]) == "")
        let faint = [ScreenCell("❯"), ScreenCell(" ")] + "rode os testes".map { ScreenCell($0, faint: true) }
        #expect(PromptScreen.typedInput([ScreenLine(rule), ScreenLine(cells: faint), ScreenLine(rule)]) == "")
        #expect(PromptScreen.typedInput([ScreenLine("nada")]) == nil)
    }
}
