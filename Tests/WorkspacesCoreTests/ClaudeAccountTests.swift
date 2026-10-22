import Foundation
import Testing
@testable import WorkspacesCore

@Suite struct ClaudeAccountTests {
    @Test func environmentSetsTheFolderAndTheNameAndClearsAnInheritedFolder() {
        let base = ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/elsewhere", "WORKSPACES_CONTA": "conta9"]
        let second = ClaudeAccount(name: "conta2", configDir: "~/.claude-b").environment(base)
        #expect(second["CLAUDE_CONFIG_DIR"] == NSHomeDirectory() + "/.claude-b")
        #expect(second["WORKSPACES_CONTA"] == "conta2")
        #expect(second["PATH"] == "/usr/bin")
        let first = ClaudeAccount(name: "conta1", configDir: "  ").environment(base)
        #expect(first["CLAUDE_CONFIG_DIR"] == nil)
        #expect(first["WORKSPACES_CONTA"] == "conta1")
    }

    @Test func currentAccountFallsBackToTheFirstThenToTheDefaultLogin() {
        var config = AppConfig()
        #expect(config.currentAccount(fallback: "conta1").name == "conta1")
        #expect(config.currentAccount(fallback: "conta1").configPath == nil)
        config.accounts = [ClaudeAccount(name: "a"), ClaudeAccount(name: "b", configDir: "/tmp/b")]
        #expect(config.currentAccount(fallback: "conta1").name == "a")
        config.activeAccount = "b"
        #expect(config.currentAccount(fallback: "conta1").configPath == "/tmp/b")
        config.activeAccount = "gone"
        #expect(config.currentAccount(fallback: "conta1").name == "a")
    }

    @Test func oldConfigsDecodeWithoutAccounts() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"workspaces":[]}"#.utf8))
        #expect(config.accounts.isEmpty)
        #expect(config.activeAccount == nil)
        var saved = config
        saved.accounts = [ClaudeAccount(name: "conta2", configDir: "~/.claude-b")]
        saved.activeAccount = "conta2"
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(saved))
        #expect(back == saved)
    }

    @Test func conversationsPathFollowsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        let linked = root.appendingPathComponent("linked")
        let apart = root.appendingPathComponent("apart")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apart.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("projects"),
                                                   withDestinationURL: main.appendingPathComponent("projects"))
        let a = ClaudeAccount(name: "a", configDir: main.path)
        #expect(ClaudeAccount(name: "b", configDir: linked.path).conversationsPath == a.conversationsPath)
        #expect(ClaudeAccount(name: "c", configDir: apart.path).conversationsPath != a.conversationsPath)
    }
}

@Suite struct AccountSwitchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func readings(five: Double? = nil, fiveResets: TimeInterval = 3600, week: Double? = nil) -> LimitReadings {
        LimitReadings(
            fiveHour: five.map { [MeterReading(time: now, percent: $0, resetsAt: now.addingTimeInterval(fiveResets))] } ?? [],
            sevenDay: week.map { [MeterReading(time: now, percent: $0, resetsAt: now.addingTimeInterval(3 * 86_400))] } ?? [])
    }

    @Test func spentOnlyAtTheTopAndBeforeTheReset() {
        #expect(AccountSwitch.spentUntil(readings(five: 100), now: now) == now.addingTimeInterval(3600))
        #expect(AccountSwitch.spentUntil(readings(five: 97), now: now) == nil)
        #expect(AccountSwitch.spentUntil(readings(five: 100, fiveResets: -60), now: now) == nil)
        // The week holds it longer than the window.
        #expect(AccountSwitch.spentUntil(readings(five: 40, week: 100), now: now) == now.addingTimeInterval(3 * 86_400))
        #expect(AccountSwitch.spentUntil(LimitReadings(), now: now) == nil)
    }

    @Test func offersAFreeAccountOnlyWhenTheActiveOneIsSpent() {
        let names = ["conta1", "conta2"]
        #expect(AccountSwitch.advice(active: "conta1", accounts: names, readings: ["conta1": readings(five: 80)],
                                     failedAt: [:], now: now) == nil)
        // No reading of the other one yet: it is offered.
        #expect(AccountSwitch.advice(active: "conta1", accounts: names, readings: ["conta1": readings(five: 100)],
                                     failedAt: [:], now: now) == .switchTo("conta2"))
        #expect(AccountSwitch.advice(active: "conta1", accounts: names,
                                     readings: ["conta1": readings(five: 100), "conta2": readings(five: 100, fiveResets: 13 * 60)],
                                     failedAt: [:], now: now) == .waitFor("conta2", until: now.addingTimeInterval(13 * 60)))
        #expect(AccountSwitch.advice(active: "conta1", accounts: ["conta1"], readings: ["conta1": readings(five: 100)],
                                     failedAt: [:], now: now) == nil)
    }

    @Test func aRecentRateLimitErrorCountsBeforeTheMeterCatchesUp() {
        let names = ["conta1", "conta2"]
        #expect(AccountSwitch.advice(active: "conta1", accounts: names, readings: ["conta1": readings(five: 96)],
                                     failedAt: ["conta1": now.addingTimeInterval(-60)], now: now) == .switchTo("conta2"))
        #expect(AccountSwitch.advice(active: "conta1", accounts: names, readings: ["conta1": readings(five: 96)],
                                     failedAt: ["conta1": now.addingTimeInterval(-11 * 60)], now: now) == nil)
    }

    @Test func anAccountThatJustFailedIsNotOfferedAsFree() {
        let failed = ["conta1": now.addingTimeInterval(-60), "conta2": now.addingTimeInterval(-120)]
        #expect(AccountSwitch.advice(active: "conta1", accounts: ["conta1", "conta2", "conta3"], readings: [:],
                                     failedAt: failed, now: now) == .switchTo("conta3"))
        #expect(AccountSwitch.advice(active: "conta1", accounts: ["conta1", "conta2"], readings: [:],
                                     failedAt: failed, now: now) == nil)
    }

    @Test func stopFailureEndsTheTurnAndKeepsTheError() throws {
        let payload = try #require(JSONValue.parse(Data(#"{"hook_event_name":"StopFailure","session_id":"s1","error":"rate_limit"}"#.utf8)))
        let update = try #require(HookEvent.update(from: payload))
        #expect(update.status == .done)
        #expect(update.failure == "rate_limit")
        #expect(update.endsTurn)
        #expect(HookEvent.subscribed.contains("StopFailure"))
    }
}
