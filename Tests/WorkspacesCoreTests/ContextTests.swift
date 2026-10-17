import Foundation
import Testing
@testable import WorkspacesCore

@Suite struct ContextFormatTests {
    @Test func shortForm() {
        #expect(ContextFormat.short(963_412) == "963k")
        #expect(ContextFormat.short(300_000) == "300k")
    }

    @Test func anOldHandoffLimitInTheConfigIsIgnored() throws {
        // Settings written before the recycle was removed still load, and the key is not written back.
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"handoffContextTokens": 250000}"#.utf8))
        let saved = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!saved.contains("handoffContextTokens"))
    }
}

@Suite struct HookReplyTests {
    @Test func helperPrintsOnlyJSONObjectsTheAppSent() {
        let json = #"{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"x"}}"#
        #expect(HookReply.stdout(IPCResponse(ok: true, text: json)) == json + "\n")
        #expect(HookReply.stdout(IPCResponse(ok: true, text: "")) == nil)
        #expect(HookReply.stdout(IPCResponse(ok: false, text: "app encerrando")) == nil)
        #expect(HookReply.stdout(IPCResponse(ok: true, text: "texto solto")) == nil)
        #expect(HookReply.stdout(IPCResponse(ok: true, text: "{quebrado}")) == nil)
        #expect(HookReply.stdout(nil) == nil)
    }

    @Test func sessionStartCarriesSourceAndTranscript() {
        let update = HookEvent.update(from: .object(["hook_event_name": .string("SessionStart"), "session_id": .string("new"),
                                                     "source": .string("clear"), "transcript_path": .string("/t/new.jsonl")]))
        #expect(update?.event == "SessionStart")
        #expect(update?.source == "clear")
        #expect(update?.transcriptPath == "/t/new.jsonl")
        #expect(update?.status == .idle)
    }

    @Test func clearDoesNotEndTheSession() {
        func end(_ reason: String?) -> SessionStatus? {
            var o: [String: JSONValue] = ["hook_event_name": .string("SessionEnd")]
            if let reason { o["reason"] = .string(reason) }
            return HookEvent.update(from: .object(o))?.status
        }
        #expect(end("clear") == nil)
        #expect(end("resume") == nil)
        #expect(end("other") == .ended)
        #expect(end("prompt_input_exit") == .ended)
        #expect(end(nil) == .ended)
    }

    @Test func sessionStartHookRunsForEverySourceIncludingClear() {
        // No matcher: the same hook fires on startup, resume, clear and compact.
        let settings = ClaudeLaunch.settingsJSON(hookCommand: "'/x/workspaces-hook'")
        guard case .array(let entries)? = settings["hooks"]?["SessionStart"] else { Issue.record("no SessionStart"); return }
        #expect(entries.count == 1)
        #expect(entries.first?["matcher"] == nil)
    }
}
