import Foundation
import Testing
@testable import WorkspacesCore

/// Screens captured with `tmux capture-pane -p -e` from Claude Code 2.1.292 on the server (07/10).
private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).ansi")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct ScreenParserTests {
    @Test func placeholderIsFaintAndTheInputCountsAsEmpty() throws {
        let lines = ScreenParser.lines(try fixture("placeholder"))
        let input = try #require(lines.first { $0.text.hasPrefix("❯") })
        #expect(input.text.contains("Try \"fix lint errors\""))
        let letters = input.cells.dropFirst(2).filter { !$0.character.isWhitespace }
        #expect(!letters.isEmpty && letters.allSatisfy(\.faint))
        #expect(PromptScreen.inputIsEmpty(lines) == true)
    }

    @Test func emptyInputAfterATurn() throws {
        let lines = ScreenParser.lines(try fixture("after-turn"))
        #expect(PromptScreen.inputIsEmpty(lines) == true)
        // The echoes of sent prompts keep their text and are not faint.
        #expect(lines.contains { $0.text == "❯ Responda só: ok" && !$0.cells.contains(where: \.faint) })
    }

    @Test func typedTextIsADraft() throws {
        let lines = ScreenParser.lines(try fixture("typed"))
        #expect(PromptScreen.inputIsEmpty(lines) == false)
    }

    /// The suggested next prompt takes the placeholder's place, drawn the same way (SGR 2).
    @Test func suggestionAfterATurnCountsAsEmpty() throws {
        let screen = try fixture("after-turn").replacingOccurrences(
            of: "\u{1B}[39m❯\u{A0}\n", with: "\u{1B}[39m❯\u{A0}\u{1B}[2mrode os testes de novo\u{1B}[0m\n")
        #expect(screen != (try fixture("after-turn")))
        #expect(PromptScreen.inputIsEmpty(ScreenParser.lines(screen)) == true)
    }

    @Test func faintAndInverseFollowTheCodes() {
        let lines = ScreenParser.lines("a\u{1B}[2mb\u{1B}[22mc\u{1B}[7md\u{1B}[27me\u{1B}[2;7mf\u{1B}[0mg")
        #expect(lines.count == 1)
        let cells = lines[0].cells
        #expect(cells.map(\.character) == ["a", "b", "c", "d", "e", "f", "g"])
        #expect(cells.map(\.faint) == [false, true, false, false, false, true, false])
        #expect(cells.map(\.inverse) == [false, false, false, true, false, true, false])
    }

    @Test func stateCarriesToTheNextRow() {
        let lines = ScreenParser.lines("x\u{1B}[2m\ny\u{1B}[m\nz")
        #expect(lines.map(\.text) == ["x", "y", "z"])
        #expect(lines[1].cells[0].faint)
        #expect(!lines[2].cells[0].faint)
    }

    @Test func colorArgumentsAreNotCodes() {
        // 38;5;2 is a color, not faint; 38;2;7;7;7 is a color, not inverse.
        let lines = ScreenParser.lines("\u{1B}[38;5;2ma\u{1B}[38;2;7;7;7mb\u{1B}[38:5:2;2mc")
        #expect(lines[0].cells.map(\.faint) == [false, false, true])
        #expect(lines[0].cells.map(\.inverse) == [false, false, false])
    }

    @Test func otherSequencesAreSkipped() {
        let lines = ScreenParser.lines("\u{1B}]8;;https://x.y\u{1B}\\link\u{1B}]8;;\u{07}\u{1B}(Bok\u{1B}[2K!")
        #expect(lines.map(\.text) == ["linkok!"])
    }

    @Test func combinedCharactersStayOneCell() {
        let lines = ScreenParser.lines("e\u{301}\u{1B}[2mé")
        #expect(lines[0].cells.count == 2)
        #expect(lines[0].cells[1].faint)
    }
}

@Suite struct LimitReadingStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ws-limits-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func oneFilePerAccount() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reset = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let one = LimitReadings(fiveHour: [MeterReading(time: Date(), percent: 16, resetsAt: reset)])
        try LimitReadingStore(account: "conta1", directory: dir).save(one)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("limit-readings-conta1.json").path))
        #expect(LimitReadingStore(account: "conta1", directory: dir).load().fiveHour.map(\.percent) == [16])
        #expect(LimitReadingStore(account: "conta2", directory: dir).load() == LimitReadings())
    }

    @Test func dateFormatIsTheMacOne() throws {
        // Seconds since 2001, as the Mac's limit-readings.json always had.
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LimitReadingStore(account: "conta1", directory: dir)
        let reading = MeterReading(time: Date(timeIntervalSinceReferenceDate: 100), percent: 4, resetsAt: Date(timeIntervalSinceReferenceDate: 200))
        try store.save(LimitReadings(sevenDay: [reading]))
        let json = try #require(JSONValue.parse(try Data(contentsOf: store.url)))
        guard case .array(let week)? = json["sevenDay"] else { Issue.record("sem sevenDay"); return }
        #expect(week.first?["resetsAt"] == .number(200))
    }

    @Test func legacyFileOnlyUntilTheAccountHasItsOwn() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LimitReadingStore(account: "conta1", directory: dir)
        let old = LimitReadings(sevenDay: [MeterReading(time: Date(), percent: 53, resetsAt: Date())])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: store.legacyURL)
        #expect(store.load().sevenDay.isEmpty)
        #expect(store.load(legacy: true).sevenDay.map(\.percent) == [53])
        try store.save(LimitReadings())
        #expect(store.load(legacy: true).sevenDay.isEmpty)
    }

    @Test func accountNames() {
        #expect(LimitReadingStore.accountName("conta2") == "conta2")
        #expect(LimitReadingStore.accountName(nil) == "conta1")
        #expect(LimitReadingStore.accountName("../x") == "conta1")
        #expect(LimitReadingStore.accountName("") == "conta1")
        #expect(LimitReadingStore.accountName("cônta") == "conta1")
    }

    @Test func recordKeepsOnlyChanges() {
        var list: [MeterReading] = []
        let reset = Date().addingTimeInterval(3600)
        #expect(LimitReadings.record(MeterReading(time: Date(), percent: 10, resetsAt: reset), in: &list))
        #expect(LimitReadings.record(MeterReading(time: Date().addingTimeInterval(5), percent: 10, resetsAt: reset), in: &list))
        #expect(list.count == 1)
        #expect(LimitReadings.record(MeterReading(time: Date().addingTimeInterval(9), percent: 11, resetsAt: reset), in: &list))
        #expect(list.count == 2)
        // Older than the newest: not recorded.
        #expect(!LimitReadings.record(MeterReading(time: Date().addingTimeInterval(-60), percent: 12, resetsAt: reset), in: &list))
    }
}

@Suite struct ToolCommandTests {
    @Test func buildsAToolRequestFromNobody() throws {
        let request = try ToolCommand.request(["send_message", #"{"session":"abcd","text":"oi"}"#], session: nil).get()
        #expect(request.kind == .tool)
        #expect(request.session == nil)
        #expect(request.tool == "send_message")
        #expect(request.arguments?["text"] == .string("oi"))
        #expect(try ToolCommand.request(["list_sessions"], session: nil).get().arguments == .object([:]))
    }

    @Test func insideASessionItActsAsThatSession() throws {
        #expect(try ToolCommand.request(["close_session"], session: "s-1").get().session == "s-1")
    }

    @Test func refusesBadUsage() {
        #expect(throws: ToolCommandError.usage) { try ToolCommand.request([]).get() }
        #expect(throws: ToolCommandError.badArguments) { try ToolCommand.request(["x", "[1]"]).get() }
        #expect(throws: ToolCommandError.badArguments) { try ToolCommand.request(["x", "{"]).get() }
        #expect(throws: ToolCommandError.usage) { try ToolCommand.request(["x", "{}", "extra"]).get() }
    }
}
