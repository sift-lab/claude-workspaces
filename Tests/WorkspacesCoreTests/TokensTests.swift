import Foundation
import Testing
@testable import WorkspacesCore

private func line(session: String = "s1", id: String, at time: String, input: Int = 1, output: Int = 100,
                  read: Int = 0, write: Int = 0, model: String = "claude-opus-5-5", cwd: String = "/p/app") -> String {
    """
    {"parentUuid":"x","isSidechain":false,"type":"assistant","timestamp":"\(time)","sessionId":"\(session)","cwd":"\(cwd)","gitBranch":"main","requestId":"req_\(id)","message":{"id":"msg_\(id)","model":"\(model)","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(write),"cache_read_input_tokens":\(read),"output_tokens":\(output)}}}
    """
}

private func date(_ text: String) -> Date { Transcript.parseTime(text)! }

@Suite struct TranscriptTests {
    @Test func readsAnAssistantLine() throws {
        let call = try #require(Transcript.call(fromLine: Data(line(id: "a", at: "2026-10-02T18:31:05.123Z", input: 3, output: 50, read: 500_000, write: 49_000).utf8)))
        #expect(call.session == "s1")
        #expect(call.context == 549_003)
        #expect(call.key == "msg_a|req_a")
        #expect(call.cwd == "/p/app")
        #expect(call.branch == "main")
    }

    @Test func ignoresUserLinesAndLocalMessages() {
        let user = #"{"type":"user","timestamp":"2026-10-02T18:31:05.123Z","sessionId":"s1","message":{"role":"user","content":"usage"}}"#
        #expect(Transcript.call(fromLine: Data(user.utf8)) == nil)
        #expect(Transcript.call(fromLine: Data(line(id: "b", at: "2026-10-02T18:31:05Z", model: "<synthetic>").utf8)) == nil)
    }

    @Test func parsesTimeLikeTheFormatter() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in ["2026-10-02T18:31:05.123Z", "2024-02-29T00:00:00.000Z", "1999-12-31T23:59:59.999Z"] {
            let mine = Transcript.parseTime(text)!.timeIntervalSince1970
            let theirs = formatter.date(from: text)!.timeIntervalSince1970
            #expect(abs(mine - theirs) < 0.0005, Comment(rawValue: text))
        }
        #expect(Transcript.parseTime("2026-10-02T18:31:05Z") == ISO8601DateFormatter().date(from: "2026-10-02T18:31:05Z"))
    }

    @Test func familyNamesTheModel() {
        #expect(TokenPrice.family("claude-opus-5-5") == "Opus 5.5")
        #expect(TokenPrice.family("claude-fable-5-1") == "Fable 5.1")
        #expect(TokenPrice.family("claude-haiku-4-5-20251001") == "Haiku 4.5")
    }
}

@Suite struct LedgerTests {
    @Test func countsEachMessageOnceAndWeighsByKind() {
        let ledger = TokenLedger()
        let call = TokenCall(key: "m|r", time: date("2026-10-02T10:00:00.000Z"), session: "s", input: 10, output: 2, cacheRead: 1000, cacheWrite: 8)
        #expect(ledger.add(call))
        #expect(!ledger.add(call))
        // 10 + 2*5 + 1000*0.1 + 8*1.25
        #expect(abs(ledger.weight(from: .distantPast) - 130) < 0.001)
        let fable = TokenCall(key: "f|r", time: call.time, session: "s", output: 1, model: "claude-fable-5-1")
        ledger.add(fable)
        #expect(abs(ledger.weight(from: .distantPast) - 150) < 0.001)
    }

    @Test func sessionFindsCompactionsGrowthAndAgents() throws {
        let ledger = TokenLedger()
        let now = date("2026-10-02T18:44:00.000Z")
        let contexts = [(0, 300_000), (20, 600_000), (40, 960_000), (45, 120_000), (60, 300_000), (100, 420_000), (110, 549_000)]
        for (i, (minute, tokens)) in contexts.enumerated() {
            let t = now.addingTimeInterval(Double(minute - 115) * 60)
            ledger.add(TokenCall(key: "m\(i)", time: t, session: "s", cacheRead: tokens))
        }
        ledger.add(TokenCall(key: "a1", time: now.addingTimeInterval(-30), session: "s", output: 1000), agent: "agent-1")
        ledger.add(TokenCall(key: "a2", time: now.addingTimeInterval(-50), session: "s", output: 1000), agent: "agent-2")
        ledger.add(TokenCall(key: "a3", time: now.addingTimeInterval(-900), session: "s", output: 1000), agent: "agent-3")

        let s = try #require(ledger.session("s", from: now.addingTimeInterval(-3 * 3600), windowStart: now.addingTimeInterval(-3600), now: now))
        #expect(s.context == 549_000)
        #expect(s.compactions.count == 1)
        #expect(s.compactions.first?.before == 960_000)
        #expect(s.compactions.first?.after == 120_000)
        #expect(s.activeAgents == 2)
        // An hour ago the last answer was the one right after the compaction (120 mil).
        #expect(s.growthPerHour == Double(549_000 - 120_000))
        #expect(s.growthLast10 == 549_000 - 420_000)
        #expect(s.agentWeightSinceFrom == 15_000)
    }

    @Test func heaviestFindsTheBusiestStretch() {
        let ledger = TokenLedger()
        let t = date("2026-10-02T10:00:00.000Z")
        for (i, minutes) in [0, 10, 20, 400, 410].enumerated() {
            ledger.add(TokenCall(key: "\(i)", time: t.addingTimeInterval(Double(minutes) * 60), session: "s", output: 100))
        }
        #expect(ledger.heaviest(span: 3600, from: .distantPast, to: .distantFuture) == 1500)
        #expect(ledger.heaviest(span: 3600, from: t.addingTimeInterval(3600), to: .distantFuture) == 1000)
    }

    @Test func overviewSplitsWindowWeekAndGroups() {
        let ledger = TokenLedger()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = date("2026-10-02T18:00:00.000Z")
        ledger.add(TokenCall(key: "1", time: now.addingTimeInterval(-600), session: "a", output: 100, cwd: "/w/sift/app"))
        ledger.add(TokenCall(key: "2", time: now.addingTimeInterval(-2 * 86_400), session: "b", output: 100, cwd: "/w/job"))
        ledger.add(TokenCall(key: "3", time: now.addingTimeInterval(-9 * 86_400), session: "b", output: 100, cwd: "/w/job"))
        let o = ledger.overview(now: now, windowStart: now.addingTimeInterval(-3600), weekStart: now.addingTimeInterval(-3 * 86_400),
                                calendar: calendar) { $0?.hasPrefix("/w/sift") == true ? "Sift" : "Outros" }
        #expect(o.weightInWindow == 500)
        #expect(o.weightInWeek == 1000)
        #expect(o.lastWeekCurve.last?.weight == 500)
        #expect(o.days.last?.groups["Sift"] == 500)
        #expect(o.days[o.days.count - 3].groups["Outros"] == 500)
        #expect(o.windowSessions.map(\.id) == ["a"])
        #expect(o.topSessions.map(\.id) == ["b", "a"] || o.topSessions.map(\.id) == ["a", "b"])
    }
}

@Suite struct ScannerTests {
    @Test func readsOnlyFinishedLinesAndResumes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID())")
        let dir = root.appendingPathComponent("-p-app/s1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("-p-app/s1.jsonl")
        let first = line(id: "a", at: "2026-10-02T10:00:00.000Z") + "\n"
        let second = line(id: "b", at: "2026-10-02T10:01:00.000Z")
        // The second line is still being written: no newline yet.
        try (first + String(second.prefix(40))).write(to: main, atomically: false, encoding: .utf8)
        try (line(id: "c", at: "2026-10-02T10:02:00.000Z") + "\n").write(to: dir.appendingPathComponent("agent-x.jsonl"), atomically: false, encoding: .utf8)

        let ledger = TokenLedger()
        let scanner = TranscriptScanner(root: root)
        #expect(scanner.scan(into: ledger, since: .distantPast) == 2)
        #expect(ledger.entries.filter(\.isAgent).count == 1)

        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd()
        handle.write(Data((String(second.dropFirst(40)) + "\n").utf8))
        try handle.close()
        #expect(scanner.scan(into: ledger, since: .distantPast) == 1)
        #expect(scanner.scan(into: ledger, since: .distantPast) == 0)
        #expect(ledger.entries.count == 3)
    }
}

@Suite struct LimitTests {
    @Test func forecastSaysWhenTheWindowRunsOut() {
        let now = date("2026-10-01T18:25:00.000Z")
        let reset = now.addingTimeInterval(4 * 3600 + 45 * 60)
        let fast = LimitMath.forecast(used: 28, resetsAt: reset, rate: 160, now: now)
        #expect(fast.runsOutAt != nil)
        #expect(abs(fast.runsOutAt!.timeIntervalSince(now) - 72.0 / 160 * 3600) < 1)
        let calm = LimitMath.forecast(used: 55, resetsAt: now.addingTimeInterval(7000), rate: 18, now: now)
        #expect(calm.runsOutAt == nil)
        #expect(abs(calm.atReset - (55 + 18 * 7000 / 3600)) < 0.01)
    }

    @Test func fullWeightComesFromReadingsOfOneWindow() {
        let t = date("2026-10-02T15:00:00.000Z")
        let reset = t.addingTimeInterval(5 * 3600)
        let readings = [MeterReading(time: t, percent: 10, resetsAt: reset),
                        MeterReading(time: t.addingTimeInterval(3600), percent: 30, resetsAt: reset.addingTimeInterval(20))]
        let full = LimitMath.fullWeight(readings: readings, spent: { _, _ in 1_000_000 }, fallback: 5)
        #expect(full == 5_000_000)
        let few = [MeterReading(time: t, percent: 10, resetsAt: reset), MeterReading(time: t.addingTimeInterval(60), percent: 11, resetsAt: reset)]
        #expect(LimitMath.fullWeight(readings: few, spent: { _, _ in 1 }, fallback: 5) == 5)
    }
}

@Suite struct StatusLineTests {
    @Test func readsContextAndLimits() throws {
        let json = #"""
        {"session_id":"abc","cwd":"/p/app","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
         "workspace":{"current_dir":"/p/app","project_dir":"/p/app"},
         "context_window":{"total_input_tokens":549000,"total_output_tokens":12,"context_window_size":1000000,"used_percentage":55,"remaining_percentage":45},
         "rate_limits":{"five_hour":{"used_percentage":55,"resets_at":1790980800},"seven_day":{"used_percentage":37,"resets_at":1791277200}}}
        """#
        let now = Date()
        let r = StatusLineReading.parse(try #require(JSONValue.parse(Data(json.utf8))), now: now)
        #expect(r.sessionId == "abc")
        #expect(r.contextTokens == 549_000)
        #expect(r.contextSize == 1_000_000)
        #expect(r.projectDir == "/p/app")
        #expect(r.fiveHour == MeterReading(time: now, percent: 55, resetsAt: Date(timeIntervalSince1970: 1_790_980_800)))
        #expect(r.sevenDay?.percent == 37)
    }

    @Test func withoutLimitsThereIsNoReading() {
        let r = StatusLineReading.parse(.object(["session_id": .string("x")]))
        #expect(r.fiveHour == nil)
        #expect(r.contextTokens == nil)
    }

    @Test func ownCommandFollowsClaudeCodesOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID())")
        let project = root.appendingPathComponent("p"), home = root.appendingPathComponent("h")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(StatusLineRelay.ownCommand(projectDir: project.path, home: home.path) == nil)
        try #"{"statusLine":{"type":"command","command":"echo user"}}"#.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        #expect(StatusLineRelay.ownCommand(projectDir: project.path, home: home.path) == "echo user")
        try #"{"statusLine":{"type":"command","command":"echo local"}}"#.write(to: project.appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)
        #expect(StatusLineRelay.ownCommand(projectDir: project.path, home: home.path) == "echo local")
    }

    @Test func settingsAskForTheStatusLine() {
        let settings = ClaudeLaunch.settingsJSON(helperPath: "/Apps/W.app/Contents/MacOS/Workspaces")
        #expect(settings["statusLine"]?["command"] == .string("'/Apps/W.app/Contents/MacOS/Workspaces' statusline"))
        #expect(ClaudeLaunch.settingsJSON(hookCommand: "h")["statusLine"] == nil)
    }
}

/// Reads the real transcripts of this Mac, to measure. Runs only with WORKSPACES_REAL_SCAN=1.
@Suite struct RealScanTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WORKSPACES_REAL_SCAN"] == "1"))
    func scansTwoWeeks() {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let ledger = TokenLedger()
        let scanner = TranscriptScanner(root: root)
        let start = Date()
        let added = scanner.scan(into: ledger, since: Date().addingTimeInterval(-15 * 86_400))
        let first = Date().timeIntervalSince(start)
        let again = Date()
        let more = scanner.scan(into: ledger, since: Date().addingTimeInterval(-15 * 86_400))
        print("REAL SCAN: \(added) calls in \(String(format: "%.1f", first)) s; rescan \(more) in \(String(format: "%.2f", Date().timeIntervalSince(again))) s; sessions \(ledger.sessions.count)")
        let now = Date()
        let o = ledger.overview(now: now, windowStart: now.addingTimeInterval(-5 * 3600), weekStart: now.addingTimeInterval(-7 * 86_400)) { _ in "x" }
        print("REAL SCAN: week weight \(Int(o.weightInWeek)), read share \(Int(100 * o.cacheRead / max(o.total, 1)))%, agents \(Int(100 * o.agentWeight / max(o.total, 1)))%")
        let shifted = ledger.overview(now: now, windowStart: now.addingTimeInterval(-5 * 3600), weekStart: now.addingTimeInterval(-3.4 * 86_400)) { _ in "x" }
        print("REAL SCAN: heaviest 7d \(Int(ledger.heaviest(span: 7 * 86_400, from: now.addingTimeInterval(-15 * 86_400), to: now))), heaviest 5h \(Int(ledger.heaviest(span: 5 * 3600, from: now.addingTimeInterval(-15 * 86_400), to: now))), last week \(Int(shifted.lastWeekCurve.last?.weight ?? 0)), this week \(Int(shifted.weightInWeek))")
        #expect(added > 0)
    }
}
