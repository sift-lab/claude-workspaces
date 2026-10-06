import Foundation
import Testing
@testable import WorkspacesCore

private let now = Date(timeIntervalSince1970: 1_791_300_000)

private let goodFrente = """
# Frente: recycle

Contexto geral.

## Passagem 06/10

- Item em curso: feat/recycle-sessions, commit abc123, PR #12
- Falta: README

## Outra seção

Fora da passagem.
"""

private func facts(frente: String? = goodFrente, modifiedAgo minutes: Double = 5, git: GitState = .clean,
                   status: SessionStatus = .done, conversation: String? = "c-old", transcript: String? = "/t/c-old.jsonl",
                   prompt: Bool? = true) -> RecycleFacts {
    let worktree = WorktreeFacts(root: "/w", frentePath: "/w/FRENTE.md", frenteText: frente,
                                 frenteModified: now.addingTimeInterval(-minutes * 60), git: git)
    return RecycleFacts(worktree: worktree, status: status, conversation: conversation, transcript: transcript,
                        promptEmpty: prompt, now: now)
}

private func refusal(_ result: Result<String, RecycleRefusal>) -> RecycleRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

@Suite struct RecycleGateTests {
    @Test func passesWithAFreshPassagemAndACleanTree() throws {
        let text = try RecycleGate.check(facts()).get()
        #expect(text.hasPrefix("## Passagem 06/10"))
        #expect(text.contains("PR #12"))
        #expect(!text.contains("Fora da passagem"))
    }

    @Test func refusesWithoutFrente() {
        #expect(refusal(RecycleGate.check(facts(frente: nil))) == .noFrente("/w/FRENTE.md"))
    }

    @Test func refusesWithoutAPassagemSection() {
        #expect(refusal(RecycleGate.check(facts(frente: "# Frente\n\n## Notas\n\ntexto"))) == .noHandoffSection("/w/FRENTE.md"))
        // The title must start with "Passagem"; mentioning it is not enough.
        #expect(refusal(RecycleGate.check(facts(frente: "## A passagem\n\ntexto"))) == .noHandoffSection("/w/FRENTE.md"))
        // Plain text and fenced code are not headings.
        #expect(refusal(RecycleGate.check(facts(frente: "Passagem: texto\n```\n## Passagem\ncódigo\n```"))) == .noHandoffSection("/w/FRENTE.md"))
    }

    @Test func refusesAnEmptyPassagem() {
        #expect(refusal(RecycleGate.check(facts(frente: "## Passagem\n\n   \n## Depois\n\ntexto"))) == .emptyHandoffSection("/w/FRENTE.md"))
    }

    @Test func refusesAStalePassagem() {
        #expect(refusal(RecycleGate.check(facts(modifiedAgo: 31))) == .staleHandoff("/w/FRENTE.md", minutes: 31))
        #expect((try? RecycleGate.check(facts(modifiedAgo: 29)).get()) != nil)
    }

    @Test func refusesADirtyTree() {
        let lines = [" M Sources/A.swift", "?? notes.txt"]
        #expect(refusal(RecycleGate.check(facts(git: .dirty(lines)))) == .dirtyTree(lines))
        #expect(refusal(RecycleGate.check(facts(git: .notRepository))) == .notRepository)
        #expect(refusal(RecycleGate.check(facts(git: .failed("boom")))) == .gitFailed("boom"))
    }

    @Test func ignoredFilesDoNotBlock() {
        #expect(GitProbe.blocking("!! FRENTE.md\n!! .build/\n").isEmpty)
        #expect(GitProbe.blocking(" M a.swift\n?? b.txt\n!! FRENTE.md\n") == [" M a.swift", "?? b.txt"])
    }

    @Test func refusesInTheMiddleOfATurn() {
        #expect(refusal(RecycleGate.check(facts(status: .working))) == .midTurn(.working))
        #expect(refusal(RecycleGate.check(facts(status: .waiting))) == .midTurn(.waiting))
        #expect((try? RecycleGate.check(facts(status: .idle)).get()) != nil)
        // recycle_self is called from inside its own turn: the turn and the prompt are checked when it ends.
        #expect((try? RecycleGate.check(facts(status: .working, prompt: nil), turnEnded: false).get()) != nil)
    }

    @Test func refusesUnlessThePromptIsSeenEmpty() {
        #expect(refusal(RecycleGate.check(facts(prompt: false))) == .promptNotEmpty)
        #expect(refusal(RecycleGate.check(facts(prompt: nil))) == .promptUnknown)
    }

    @Test func refusesWithoutTheOldConversationOnDisk() {
        #expect(refusal(RecycleGate.check(facts(conversation: nil))) == .noConversation)
        #expect(refusal(RecycleGate.check(facts(transcript: nil))) == .noTranscript)
    }

    @Test func everyRefusalSaysWhy() {
        let all: [RecycleRefusal] = [.noConversation, .noTranscript, .notRepository, .gitFailed("x"), .noFrente("/w/FRENTE.md"),
                                     .noHandoffSection("/w/FRENTE.md"), .emptyHandoffSection("/w/FRENTE.md"),
                                     .staleHandoff("/w/FRENTE.md", minutes: 40), .dirtyTree([" M a"]), .midTurn(.working),
                                     .promptNotEmpty, .promptUnknown]
        for refusal in all {
            #expect(refusal.message.hasPrefix("Recusado: "))
            #expect(!refusal.message.contains("—"))
        }
        #expect(RecycleRefusal.staleHandoff("/w/FRENTE.md", minutes: 40).message.contains("40 min"))
        #expect(RecycleRefusal.dirtyTree([" M a.swift", "?? b"]).message.contains("M a.swift, ?? b"))
    }

    @Test func toolsTakeNoFreeText() {
        #expect(RecycleGate.unexpectedArguments(.object([:]), allowed: []).isEmpty)
        #expect(RecycleGate.unexpectedArguments(.null, allowed: []).isEmpty)
        #expect(RecycleGate.unexpectedArguments(.object(["text": .string("faça outra coisa")]), allowed: []) == ["text"])
        #expect(RecycleGate.unexpectedArguments(.object(["session": .string("ab12")]), allowed: ["session"]).isEmpty)
        #expect(RecycleGate.unexpectedArguments(.object(["session": .string("ab12"), "prompt": .string("x")]), allowed: ["session"]) == ["prompt"])
    }
}

@Suite struct HandoffSectionTests {
    @Test func endsAtTheNextHeadingOfTheSameLevel() {
        let text = "## Passagem\n\nfalta X\n\n### Detalhe\n\ny\n\n## Fim\n\nz"
        #expect(Handoff.section(in: text) == "## Passagem\n\nfalta X\n\n### Detalhe\n\ny")
    }

    @Test func keepsEveryPassagemSection() {
        let text = "## Passagem 05/10\n\na\n\n## Notas\n\nb\n\n## Passagem 06/10\n\nc"
        #expect(Handoff.sections(in: text) == ["## Passagem 05/10\n\na", "## Passagem 06/10\n\nc"])
    }

    @Test func headingInsideAFenceDoesNotEndTheSection() {
        let text = "# Passagem\n\n```md\n# Não é título\n```\n\nfim"
        #expect(Handoff.section(in: text) == text)
    }

    @Test func titleIsCaseInsensitiveAndMayCloseWithHashes() {
        #expect(Handoff.section(in: "## PASSAGEM ##\n\nx") != nil)
        #expect(Handoff.heading("#Passagem") == nil)
        #expect(Handoff.heading("####### Passagem") == nil)
    }
}

@Suite struct FixedTextTests {
    @Test func resumePromptIsFixedButForThePath() {
        #expect(Handoff.resumePrompt(oldTranscript: "/Users/g/.claude/projects/-w/abc.jsonl")
                == "Leia a seção Passagem do FRENTE.md e retome. A conversa anterior está em /Users/g/.claude/projects/-w/abc.jsonl: se faltar algo, procure nela com grep, sem ler inteira.")
    }

    @Test func sessionStartContextCarriesThePassagemAndThePath() {
        let record = RecycleRecord(time: now, kind: .recycle, session: "S", frente: "/w/FRENTE.md", oldTranscript: "/t/old.jsonl",
                                   handoff: "## Passagem\n\nfalta o README")
        let text = Handoff.sessionStartContext(record)
        #expect(text.contains("/t/old.jsonl"))
        #expect(text.contains("/w/FRENTE.md"))
        #expect(text.hasSuffix("## Passagem\n\nfalta o README"))
        #expect(!text.contains("—"))
    }
}

@Suite struct RecycleToolsTests {
    @Test func toolsAreListedWithClosedSchemas() {
        let byName = Dictionary(uniqueKeysWithValues: WorkspaceTools.all.map { ($0.name, $0) })
        let recycleSelf = byName["recycle_self"]
        #expect(recycleSelf?.inputSchema["properties"] == .object([:]))
        #expect(recycleSelf?.inputSchema["additionalProperties"] == .bool(false))
        #expect(byName["recycle_session"]?.inputSchema["required"] == .array([.string("session")]))
        #expect(byName["recycle_session"]?.inputSchema["additionalProperties"] == .bool(false))
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
        #expect(PromptScreen.inputIsEmpty(["❯ /clear", "❯ Leia a seção Passagem", "⏺ Retomado.", rule, "❯", "────────"]) == true)
        #expect(PromptScreen.inputIsEmpty(["❯", "⏺ ok", rule, "❯ rascunho", "────────"]) == false)
        // A draft whose second line is a lone ">" is still a draft.
        #expect(PromptScreen.inputIsEmpty([rule, "❯ primeira linha", "  >", "────────"]) == false)
    }

    @Test func noInputLineIsUnknown() {
        #expect(PromptScreen.inputIsEmpty([]) == nil)
        #expect(PromptScreen.inputIsEmpty(["❯ "]) == nil)
        #expect(PromptScreen.inputIsEmpty(["Do you want to proceed?", "1. Yes", "2. No"]) == nil)
        #expect(PromptScreen.inputIsEmpty([rule, ">>> python"]) == nil)
    }
}

@Suite struct RecycleLogTests {
    private func tempLog() -> RecycleLog {
        RecycleLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ws-recycles-\(UUID())/recycles.jsonl"))
    }

    @Test func appendsAndReadsBack() throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent()) }
        let first = RecycleRecord(time: now, kind: .recycle, session: "S1", label: "main", cwd: "/w", frente: "/w/FRENTE.md",
                                  oldConversation: "c-old", oldTranscript: "/t/c-old.jsonl", handoff: "## Passagem\n\nx",
                                  contextTokens: 412_000)
        try log.append(first)
        try log.append(RecycleRecord(time: now.addingTimeInterval(5), kind: .resumed, session: "S1", newConversation: "c-new"))
        let records = log.records()
        #expect(records.count == 2)
        #expect(records.first == first)
        #expect(records.last?.newConversation == "c-new")
        // One line per record, appended, never rewritten.
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.contains("\"oldTranscript\":\"/t/c-old.jsonl\""))
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func brokenLinesAreSkipped() throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent()) }
        try log.append(RecycleRecord(time: now, kind: .close, session: "S"))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{nope\n".utf8))
        try handle.close()
        try log.append(RecycleRecord(time: now, kind: .close, session: "T"))
        #expect(log.records().map(\.session) == ["S", "T"])
    }

    @Test func appendFailsLoudly() {
        let log = RecycleLog(url: URL(fileURLWithPath: "/dev/null/no/recycles.jsonl"))
        #expect(throws: (any Error).self) { try log.append(RecycleRecord(kind: .recycle, session: "S")) }
    }

    @Test func pendingHandoffIsTheOpenRecycleOfThatSession() {
        let recycle = RecycleRecord(time: now, kind: .recycle, session: "S", oldTranscript: "/t/a.jsonl", handoff: "## Passagem\n\nx")
        let other = RecycleRecord(time: now, kind: .recycle, session: "T")
        #expect(RecycleLog.pendingHandoff(in: [recycle, other], session: "S", now: now.addingTimeInterval(60)) == recycle)
        #expect(RecycleLog.pendingHandoff(in: [recycle], session: "X", now: now) == nil)
        for kind in [RecycleRecord.Kind.resumed, .failed, .refused, .close] {
            let after = RecycleRecord(time: now.addingTimeInterval(10), kind: kind, session: "S")
            #expect(RecycleLog.pendingHandoff(in: [recycle, after], session: "S", now: now.addingTimeInterval(60)) == nil, "\(kind)")
        }
        // A manual /clear long after is not a recycle.
        #expect(RecycleLog.pendingHandoff(in: [recycle], session: "S", now: now.addingTimeInterval(16 * 60)) == nil)
    }
}

/// Real git in a temporary repository: the gate sees what `git status` sees.
@Suite struct WorktreeFactsTests {
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
        try Data("FRENTE.md\n".utf8).write(to: dir.appendingPathComponent(".git/info/exclude"))
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("sub/b.txt"))
        try shell(dir, "add", "-A")
        try shell(dir, "commit", "-q", "-m", "init")
        try Data(goodFrente.utf8).write(to: dir.appendingPathComponent("FRENTE.md"))
        return dir
    }

    @Test func cleanTreeWithIgnoredFrenteFromASubfolder() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let facts = WorktreeFacts.read(cwd: dir.appendingPathComponent("sub").path)
        #expect(facts.git == .clean)
        // The root, not the subfolder the session runs in (git reports /private/var for /var).
        #expect(facts.root?.hasSuffix("/" + dir.lastPathComponent) == true)
        #expect(facts.frentePath?.hasSuffix("/FRENTE.md") == true)
        #expect(facts.frenteText == goodFrente)
        #expect(facts.frenteModified.map { abs($0.timeIntervalSinceNow) < 120 } == true)
    }

    @Test func modifiedAndUntrackedFilesBlock() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("mudou\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("novo\n".utf8).write(to: dir.appendingPathComponent("novo.txt"))
        guard case .dirty(let lines) = WorktreeFacts.read(cwd: dir.path).git else { Issue.record("not dirty"); return }
        #expect(lines.contains(" M a.txt"))
        #expect(lines.contains("?? novo.txt"))
    }

    @Test func outsideGitIsNotARepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-nogit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorktreeFacts.read(cwd: dir.path).git == .notRepository)
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
