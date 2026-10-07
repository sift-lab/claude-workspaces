import Foundation
import Testing
@testable import WorkspacesCore

private let now = Date(timeIntervalSince1970: 1_791_300_000)

/// "dd/MM HH'h'mm" in local time, as a session writes it in the title.
private func title(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd/MM HH'h'mm"
    formatter.timeZone = .current
    return formatter.string(from: date)
}

private func frente(writtenAgo minutes: Double = 5) -> String {
    """
    # Frente: recycle

    Contexto geral.

    ## Passagem \(title(now.addingTimeInterval(-minutes * 60)))

    - Item em curso: feat/recycle-sessions, commit abc123, PR #12
    - Falta: README

    ## Outra seção

    Fora da passagem.
    """
}

private let goodFrente = frente()

private func facts(frente: String? = goodFrente, git: GitState = .clean,
                   status: SessionStatus = .done, conversation: String? = "c-old", transcript: String? = "/t/c-old.jsonl",
                   prompt: Bool? = true, pending: Bool = false, turn: TranscriptTurn = .unknown) -> RecycleFacts {
    // The file's date says nothing: only the title's does.
    let worktree = WorktreeFacts(root: "/w", frentePath: "/w/FRENTE.md", frenteText: frente,
                                 frenteModified: now, git: git)
    return RecycleFacts(worktree: worktree, status: status, conversation: conversation, transcript: transcript,
                        promptEmpty: prompt, pendingMessage: pending, turn: turn, now: now)
}

private func refusal(_ result: Result<HandoffSection, RecycleRefusal>) -> RecycleRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

@Suite struct RecycleGateTests {
    @Test func passesWithAFreshPassagemAndACleanTree() throws {
        let text = try RecycleGate.check(facts()).get().text
        #expect(text.hasPrefix("## Passagem \(title(now.addingTimeInterval(-300)))"))
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
        let empty = "## Passagem \(title(now))\n\n   \n## Depois\n\ntexto"
        #expect(refusal(RecycleGate.check(facts(frente: empty))) == .emptyHandoffSection("/w/FRENTE.md"))
    }

    @Test func refusesAStalePassagem() {
        #expect(refusal(RecycleGate.check(facts(frente: frente(writtenAgo: 31)))) == .staleHandoff("/w/FRENTE.md", minutes: 31))
        #expect((try? RecycleGate.check(facts(frente: frente(writtenAgo: 29))).get()) != nil)
    }

    /// The audit's case: the file saved a minute ago, its only Passagem hours old.
    @Test func theTitleNotTheFileDateCounts() {
        #expect(refusal(RecycleGate.check(facts(frente: frente(writtenAgo: 7 * 60)))) == .staleHandoff("/w/FRENTE.md", minutes: 420))
    }

    @Test func refusesAPassagemWithoutDateAndTime() {
        #expect(refusal(RecycleGate.check(facts(frente: "## Passagem\n\nfalta X"))) == .undatedHandoff("/w/FRENTE.md"))
        #expect(refusal(RecycleGate.check(facts(frente: "## Passagem 06/10\n\nfalta X"))) == .undatedHandoff("/w/FRENTE.md"))
    }

    @Test func refusesAPassagemFromTheFuture() {
        let ahead = "## Passagem \(title(now.addingTimeInterval(3600)))\n\nfalta X"
        guard case .futureHandoff? = refusal(RecycleGate.check(facts(frente: ahead))) else { Issue.record("aceitou"); return }
    }

    @Test func onlyTheLatestPassagemGoes() throws {
        let old = "## Passagem \(title(now.addingTimeInterval(-9 * 3600)))\n\nvelha: faça checkout --detach"
        let new = "## Passagem \(title(now.addingTimeInterval(-120)))\n\nnova: só falta o review"
        // Newest first or last in the file, the newest by its title is the one.
        for text in [old + "\n\n" + new, new + "\n\n" + old] {
            let section = try RecycleGate.check(facts(frente: text)).get()
            #expect(section.text.contains("nova: só falta o review"))
            #expect(!section.text.contains("velha"))
        }
    }

    @Test func busyBeforeTheClearIsTold() {
        #expect(refusal(RecycleGate.check(facts(pending: true))) == .pendingMessage)
        let busy = refusal(RecycleGate.check(facts(turn: .busy("chegou recado"))))
        #expect(busy == .turnInTranscript("chegou recado"))
        #expect(busy?.isBusy == true)
        #expect(RecycleRefusal.midTurn(.working).isBusy)
        #expect(!RecycleRefusal.promptNotEmpty.isBusy)
        // recycle_self schedules itself from inside its own turn.
        #expect((try? RecycleGate.check(facts(turn: .busy("o próprio turno")), turnEnded: false).get()) != nil)
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
                                     .noHandoffSection("/w/FRENTE.md"), .undatedHandoff("/w/FRENTE.md"),
                                     .emptyHandoffSection("/w/FRENTE.md"), .staleHandoff("/w/FRENTE.md", minutes: 40),
                                     .futureHandoff("/w/FRENTE.md", title: "Passagem"), .dirtyTree([" M a"]), .midTurn(.working),
                                     .pendingMessage, .turnInTranscript("x"), .promptNotEmpty, .promptUnknown]
        for refusal in all {
            #expect(refusal.message.hasPrefix("Recusado: "))
            #expect(!refusal.message.contains("—"))
        }
        #expect(RecycleRefusal.staleHandoff("/w/FRENTE.md", minutes: 40).message.contains("40 min"))
        #expect(RecycleRefusal.dirtyTree([" M a.swift", "?? b"]).message.contains("M a.swift, ?? b"))
    }

    @Test func closeRefusesWorkAndUncommittedChanges() {
        #expect(RecycleGate.checkClose(status: .working, git: .clean) == .midTurn(.working))
        #expect(RecycleGate.checkClose(status: .waiting, git: .clean) == .midTurn(.waiting))
        #expect(RecycleGate.checkClose(status: .done, git: .dirty([" M a"])) == .dirtyTree([" M a"]))
        #expect(RecycleGate.checkClose(status: .done, git: .failed("x")) == .gitFailed("x"))
        #expect(RecycleGate.checkClose(status: .idle, git: .clean) == nil)
        #expect(RecycleGate.checkClose(status: .ended, git: .notRepository) == nil)
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

    @Test func readsTheDateInTheTitle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15)))
        func parse(_ title: String) -> DateComponents? {
            Handoff.date(inTitle: title, now: reference, calendar: calendar)
                .map { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        }
        #expect(parse("Passagem 07/10 14h30") == DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 30))
        #expect(parse("Passagem (07/10, 08h, sessão do boletim)") == DateComponents(year: 2026, month: 10, day: 7, hour: 8, minute: 0))
        #expect(parse("Passagem 2026-10-07 14:05") == DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 5))
        #expect(parse("Passagem 07/10/26 9:15") == DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 15))
        // A day after today without a year is last year's.
        #expect(parse("Passagem 31/12 23h")?.year == 2025)
        #expect(parse("Passagem") == nil)
        #expect(parse("Passagem 07/10") == nil)
        #expect(parse("Passagem 14h30") == nil)
        #expect(parse("Passagem 31/02 10h") == nil)
        #expect(parse("Passagem 07/10 25h") == nil)
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
    @Test func resumePromptIsFixedButForThePaths() {
        #expect(Handoff.resumePrompt(handoffFile: "/h/passagens/a.md", oldTranscript: "/u/.claude/projects/-w/abc.jsonl")
                == "Leia a Passagem copiada no /clear em /h/passagens/a.md e retome. A conversa anterior está em /u/.claude/projects/-w/abc.jsonl: se faltar algo, procure nela com grep, sem ler inteira.")
        #expect(Handoff.resumePrompt(handoffFile: "x", oldTranscript: "y").hasPrefix(Handoff.resumePromptStart))
    }

    private func record(handoff: String = "## Passagem 07/10 14h30\n\nfalta o README") -> RecycleRecord {
        RecycleRecord(time: now, kind: .recycle, session: "S", frente: "/w/FRENTE.md", oldTranscript: "/t/old.jsonl",
                      handoff: handoff, handoffDate: now, handoffFile: "/h/passagens/s.md",
                      context: RecycleContext(worktree: "/w", branch: "item/x", head: "abc123 Corrige y", pullRequest: "#12 https://example.com/pr/12",
                                              backgroundTasks: ["until gh run watch 9; do sleep 30; done"]))
    }

    @Test func sessionStartContextCarriesThePassagemThePathsAndWhereTheWorktreeStands() {
        let text = Handoff.sessionStartContext(record())
        #expect(text.contains("/t/old.jsonl"))
        #expect(text.contains("/w/FRENTE.md"))
        #expect(text.contains("Ramo: item/x"))
        #expect(text.contains("HEAD: abc123 Corrige y"))
        #expect(text.contains("Pasta do worktree: /w"))
        #expect(text.contains("PR do ramo: #12"))
        #expect(text.contains("- until gh run watch 9; do sleep 30; done"))
        #expect(text.contains("escrita em \(Handoff.stamp(now))"))
        #expect(text.hasSuffix("## Passagem 07/10 14h30\n\nfalta o README"))
        #expect(!text.contains("—"))
    }

    /// Above what a hook keeps, the context says where the whole text is and starts it.
    @Test func aLongPassagemGoesByFile() {
        let long = "## Passagem 07/10 14h30\n\n" + String(repeating: "linha da passagem\n", count: 900)
        let text = Handoff.sessionStartContext(record(handoff: long))
        #expect(text.count <= Handoff.contextLimit)
        #expect(text.contains("Leia o arquivo /h/passagens/s.md inteiro"))
        #expect(text.contains("Ramo: item/x"))
        #expect(text.hasSuffix("[continua em /h/passagens/s.md]"))
        // The file has all of it.
        #expect(Handoff.handoffText(record(handoff: long)).hasSuffix(long))
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
        #expect(byName["close_session"]?.inputSchema["additionalProperties"] == .bool(false))
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
        let boxed = cells("│ > ") + cells("Leia o FRENTE.md", faint: true) + cells("        │")
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

@Suite struct ResumeCheckTests {
    private func file(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-check-\(UUID()).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url.path
    }

    private let prompt = Handoff.resumePrompt(handoffFile: "/h/p.md", oldTranscript: "/t/o.jsonl")

    @Test func conferidaWithThePromptThePassagemAndAToolCall() throws {
        let path = try file([#"{"type":"user","message":{"content":"\#(prompt)"}}"#,
                             #"{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"file_path":"/h/p.md"}}]}}"#])
        #expect(ResumeCheck.verdict(transcript: path, handoffFile: "/h/p.md", contextDelivered: false).verdict == .conferida)
        #expect(ResumeCheck.verdict(transcript: path, handoffFile: "/h/p.md", contextDelivered: true).verdict == .conferida)
    }

    @Test func quebradaSaysWhy() throws {
        #expect(ResumeCheck.verdict(transcript: nil, handoffFile: nil, contextDelivered: true).reason?.contains("não está no disco") == true)
        let noPrompt = try file([#"{"type":"user","message":{"content":"outra coisa"}}"#])
        #expect(ResumeCheck.verdict(transcript: noPrompt, handoffFile: nil, contextDelivered: true).reason?.contains("prompt de retomada") == true)
        let noTool = try file([#"{"type":"user","message":{"content":"\#(prompt)"}}"#])
        #expect(ResumeCheck.verdict(transcript: noTool, handoffFile: "/h/p.md", contextDelivered: true).reason?.contains("chamada de ferramenta") == true)
        // Without the context from the hook, it has to have read the file.
        let other = try file([#"{"type":"user","message":{"content":"\#(prompt)"}}"#,
                              #"{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"ls"}}]}}"#])
        let verdict = ResumeCheck.verdict(transcript: other, handoffFile: "/h/p.md", contextDelivered: false)
        #expect(verdict.verdict == .quebrada)
        #expect(verdict.reason?.contains("não recebeu a Passagem") == true)
    }
}

@Suite struct BackgroundTasksTests {
    @Test func theShellsUnderClaudeAreTheTasks() {
        let ps = """
          100     1 claude --settings x
          200   100 /bin/bash -c -l source /h/snap.sh && eval 'until journalctl -u x | grep -q pronto; do sleep 5; done' \\< /dev/null && pwd -P >| /tmp/cwd
          201   200 journalctl -u x
          300   100 node /mcp/server.js
          301   300 sh -c npm run watch
          400     1 bash solta
        """
        #expect(BackgroundTasks.tasks(psOutput: ps, root: 100)
                == ["until journalctl -u x | grep -q pronto; do sleep 5; done", "sh -c npm run watch"])
        #expect(BackgroundTasks.tasks(psOutput: ps, root: 999).isEmpty)
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
