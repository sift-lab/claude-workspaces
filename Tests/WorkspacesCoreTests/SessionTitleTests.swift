import Foundation
import Testing
@testable import WorkspacesCore

@Suite struct TitleCommandTests {
    @Test func parsesBothFormsAndTheText() {
        #expect(TitleCommand.parse("/titulo") == .regenerate)
        #expect(TitleCommand.parse("  /titulo  ") == .regenerate)
        #expect(TitleCommand.parse("/workspaces:titulo") == .regenerate)
        #expect(TitleCommand.parse("/titulo Fix da tela roxa ") == .set("Fix da tela roxa"))
        #expect(TitleCommand.parse("/workspaces:titulo  QA na 442") == .set("QA na 442"))
        #expect(TitleCommand.parse("/TITULO Algo") == .set("Algo"))
    }

    @Test func otherPromptsAreNotTheCommand() {
        #expect(TitleCommand.parse("/titulos") == nil)
        #expect(TitleCommand.parse("/workspaces:titulox a") == nil)
        #expect(TitleCommand.parse("muda o /titulo da aba") == nil)
        #expect(TitleCommand.parse("/clear") == nil)
    }

    @Test func replyBlocksThePromptWithAReason() {
        let reply = JSONValue.parse(Data(TitleCommand.reply("Título: X").utf8))
        #expect(reply?["decision"] == .string("block"))
        #expect(reply?["reason"] == .string("Título: X"))
        #expect(HookReply.stdout(IPCResponse(ok: true, text: TitleCommand.reply("ok"))) != nil)
    }
}

@Suite struct TitlePromptTests {
    private func output(_ result: String, error: Bool = false) -> Data {
        JSONValue.object(["type": .string("result"), "is_error": .bool(error), "result": .string(result)]).encodedLine()
    }

    @Test func readsTheJSONTheModelWrote() {
        let title = TitlePrompt.parse(output("{\"aba\": \"QA Primova na 442\", \"titulo\": \"QA do Primova Pay no build 442.\"}"))
        #expect(title == SessionTitle(tab: "QA Primova na 442", full: "QA do Primova Pay no build 442"))
    }

    @Test func toleratesFencesAndCleansDashes() {
        let text = "```json\n{\"aba\": \"Títulos de sessão\", \"titulo\": \"Títulos no Workspaces — protótipo antes\"}\n```"
        #expect(TitlePrompt.parse(output(text))?.full == "Títulos no Workspaces, protótipo antes")
    }

    @Test func refusesErrorsAndAnswersWithoutBothNames() {
        #expect(TitlePrompt.parse(output("{\"aba\": \"A\", \"titulo\": \"B\"}", error: true)) == nil)
        #expect(TitlePrompt.parse(output("{\"aba\": \"A\"}")) == nil)
        #expect(TitlePrompt.parse(output("{\"aba\": \" \", \"titulo\": \"B\"}")) == nil)
        #expect(TitlePrompt.parse(output("não sei")) == nil)
        #expect(TitlePrompt.parse(Data("Error: not logged in".utf8)) == nil)
    }

    @Test func argumentsTurnOffToolsMCPAndSaving() {
        let args = TitlePrompt.arguments(model: "haiku")
        #expect(args.starts(with: ["-p", "--safe-mode", "--model", "haiku", "--tools", ""]))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        #expect(args.last == TitlePrompt.system)
    }

    @Test func requestCarriesWhereAndWhat() {
        let request = TitlePrompt.request(project: "app", branch: "feat/x", prompts: ["primeiro", "último"])
        #expect(request.contains("Projeto: app\nBranch: feat/x"))
        #expect(request.hasSuffix("primeiro\núltimo"))
        let long = TitlePrompt.request(project: "app", branch: nil, prompts: [String(repeating: "a", count: 5000)])
        #expect(long.count < 3000)
        #expect(TitlePrompt.request(project: "app", branch: nil, prompts: [], given: "Meu título").hasSuffix("Meu título"))
    }
}

@Suite struct SessionTitleCleanTests {
    @Test func cutsAtAWordWithoutTrailingPunctuation() {
        #expect(SessionTitle.clean("Fix da tela roxa do Primova no iOS", limit: 20) == "Fix da tela roxa do")
        #expect(SessionTitle.clean("  \"Linha\n quebrada.\"  ", limit: 50) == "Linha quebrada")
        #expect(SessionTitle.clean("Uma, duas: tres", limit: 10) == "Uma, duas")
    }

    @Test func givenTitleIsKeptWholeAndPinned() {
        let title = SessionTitle.given("Fix da tela roxa do Primova Pay no iOS depois do boot")
        #expect(title.full == "Fix da tela roxa do Primova Pay no iOS depois do boot")
        #expect(title.tab.count <= SessionTitle.tabLimit)
        #expect(title.pinned)
        #expect(SessionTitle.given("QA na 442").tab == "QA na 442")
    }
}

@Suite struct ToolActivityTests {
    @Test func descriptionFirstThenTheFile() {
        #expect(ToolActivity.phrase(tool: "Bash", input: .object(["command": .string("swift test"), "description": .string("Rodando os testes")])) == "Rodando os testes")
        #expect(ToolActivity.phrase(tool: "Edit", input: .object(["file_path": .string("/a/b/App.swift")])) == "Editando App.swift")
        #expect(ToolActivity.phrase(tool: "Read", input: .object(["file_path": .string("/a/README.md")])) == "Lendo README.md")
        #expect(ToolActivity.phrase(tool: "Grep", input: .object(["pattern": .string("x")])) == "Buscando no código")
    }

    @Test func ownToolsAndUnknownOnesSayNothing() {
        #expect(ToolActivity.phrase(tool: "mcp__workspaces__set_status", input: .object(["text": .string("x")])) == nil)
        #expect(ToolActivity.phrase(tool: "TodoWrite", input: .object([:])) == nil)
        #expect(ToolActivity.phrase(tool: nil, input: nil) == nil)
    }

    @Test func postToolUseHookCarriesIt() {
        let update = HookEvent.update(from: .object([
            "hook_event_name": .string("PostToolUse"), "tool_name": .string("Bash"),
            "tool_input": .object(["description": .string("Compilando o app")]),
        ]))
        #expect(update?.activity == "Compilando o app")
        #expect(HookEvent.update(from: .object(["hook_event_name": .string("Stop")]))?.activity == nil)
    }
}

@Suite struct TranscriptPromptsTests {
    private func line(_ content: JSONValue, meta: Bool = false, type: String = "user") -> String {
        var o: [String: JSONValue] = ["type": .string(type), "message": .object(["role": .string("user"), "content": content])]
        if meta { o["isMeta"] = .bool(true) }
        return String(decoding: JSONValue.object(o).encodedLine(), as: UTF8.self)
    }

    @Test func keepsWhatThePersonTyped() {
        let text = [
            line(.string("<local-command-caveat>x</local-command-caveat>"), meta: true),
            line(.string("<command-name>/clear</command-name>")),
            line(.string("monta o protótipo")),
            line(.array([.object(["type": .string("tool_result"), "content": .string("ok")])])),
            line(.array([.object(["type": .string("image")]), .object(["type": .string("text"), "text": .string("olha a tela")])])),
            line(.string("/titulo Outro")),
            line(.string("resposta"), type: "assistant"),
            "não é json",
        ].joined(separator: "\n")
        #expect(TranscriptPrompts.read(Data(text.utf8)) == ["monta o protótipo", "olha a tela"])
    }

    @Test func firstAndLatest() {
        let text = (1...8).map { line(.string("p\($0)")) }.joined(separator: "\n")
        #expect(TranscriptPrompts.read(Data(text.utf8)) == ["p1", "p6", "p7", "p8"])
    }
}

@Suite struct SessionTitleStorageTests {
    @Test func oldSavedSessionsDecodeWithoutTitle() throws {
        let old = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"main"}"#.utf8)
        let saved = try JSONDecoder().decode(SavedSession.self, from: old)
        #expect(saved.title == nil)
        #expect(saved.titleHistory.isEmpty)
    }

    @Test func titleRoundTrips() throws {
        let saved = SavedSession(id: UUID(), label: "main", title: SessionTitle(tab: "A", full: "B", pinned: true), titleHistory: ["C"])
        let back = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(saved))
        #expect(back == saved)
    }

    @Test func configDefaultsToHaiku() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.generateTitles)
        #expect(config.titleModel == "haiku")
    }
}

@Suite struct TitlePluginTests {
    @Test func everySessionLoadsThePlugin() {
        let o = ClaudeLaunch.Options(claudeCommand: "claude", projectPath: "/p", settingsFile: "/s", mcpConfigFile: "/m",
                                     resumeId: "abc", extraArguments: "--add-dir /x", pluginDir: "/w/plugin")
        #expect(ClaudeLaunch.argv(o) == ["claude", "--settings", "/s", "--mcp-config", "/m", "--add-dir", "/x",
                                         "--plugin-dir", "/w/plugin", "--resume", "abc"])
        #expect(ClaudeLaunch.shellScript(o).contains("--mcp-config '/m' --add-dir /x --plugin-dir '/w/plugin' --resume 'abc'"))
    }

    @Test func writesManifestAndCommand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try TitlePlugin.write(to: dir)
        let manifest = try #require(FileManager.default.contents(atPath: dir.appendingPathComponent(".claude-plugin/plugin.json").path))
        #expect(JSONValue.parse(manifest)?["name"] == .string("workspaces"))
        let command = try String(contentsOf: dir.appendingPathComponent("commands/titulo.md"), encoding: .utf8)
        #expect(command.hasPrefix("---\ndescription: "))
    }
}
