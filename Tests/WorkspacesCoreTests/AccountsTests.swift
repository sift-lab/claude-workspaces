import Foundation
import Testing
@testable import WorkspacesCore

private func temporaryFolder(_ name: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return AccountFolder.resolved(url.path)
}

private func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

@Suite struct AccountChoiceTests {
    let main = Account(name: "conta1")
    let second = Account(name: "conta2", configDirectory: "/Users/x/.claude-b")

    @Test func sessionThenWorkspaceThenDefault() {
        let config = AppConfig(accounts: [main, second], defaultAccount: "conta2")
        let follows = Workspace(name: "Geral")
        let own = Workspace(name: "Sift", account: "conta1")
        #expect(config.account(of: follows).name == "conta2")
        #expect(config.account(of: own).name == "conta1")
        #expect(config.account(of: own, session: SavedSession(id: UUID(), label: "a")).name == "conta1")
        #expect(config.account(of: own, session: SavedSession(id: UUID(), label: "a", account: "conta2")).name == "conta2")
        #expect(config.account(of: nil).name == "conta2")
    }

    @Test func namesNoLongerListedFallBack() {
        let config = AppConfig(accounts: [main], defaultAccount: "conta9")
        let workspace = Workspace(name: "Sift", account: "conta2")
        #expect(config.mainAccount.name == "conta1")
        #expect(config.account(of: workspace, session: SavedSession(id: UUID(), label: "a", account: "conta3")).name == "conta1")
    }

    @Test func nextNameNeverReusesOneThatHadALogin() {
        #expect(AppConfig(accounts: [main]).nextAccountName() == "conta2")
        #expect(AppConfig(accounts: [main, second]).nextAccountName() == "conta3")
        let removed = AppConfig(accounts: [main], retiredAccounts: [second])
        #expect(removed.nextAccountName() == "conta3")
        #expect(removed.nextAccountName(taken: ["conta3"]) == "conta4")
    }

    @Test func everyFolderAConversationMayBeInIsSearchedOnce() {
        let config = AppConfig(accounts: [main, second], retiredAccounts: [Account(name: "conta3", configDirectory: "/old")])
        #expect(config.projectsDirectories(environment: [:], home: "/Users/x") == [
            "/Users/x/.claude/projects", "/Users/x/.claude-b/projects", "/old/projects"])
    }

    @Test func environmentSetsTheFolderOnlyWhenTheAccountHasOne() {
        let shell = ["PATH": "/bin", "WORKSPACES_CONTA": "old"]
        let own = main.environment(shell)
        #expect(own["CLAUDE_CONFIG_DIR"] == nil)
        #expect(own["WORKSPACES_CONTA"] == "conta1")
        #expect(own["PATH"] == "/bin")
        let other = second.environment(shell)
        #expect(other["CLAUDE_CONFIG_DIR"] == "/Users/x/.claude-b")
        #expect(other["WORKSPACES_CONTA"] == "conta2")
        // The shell's own folder stays for the default account.
        #expect(main.environment(["CLAUDE_CONFIG_DIR": "/elsewhere"])["CLAUDE_CONFIG_DIR"] == "/elsewhere")
        #expect(Account(name: "c", configDirectory: "~/.claude-c").environment([:])["CLAUDE_CONFIG_DIR"] == NSHomeDirectory() + "/.claude-c")
    }

    @Test func loginAndConversationsLiveWhereClaudeCodeKeepsThem() {
        #expect(main.stateFile(environment: [:], home: "/Users/x") == "/Users/x/.claude.json")
        #expect(main.stateFile(environment: ["CLAUDE_CONFIG_DIR": "/c"], home: "/Users/x") == "/c/.claude.json")
        #expect(second.stateFile(environment: [:], home: "/Users/x") == "/Users/x/.claude-b/.claude.json")
        #expect(main.projectsDirectory(environment: [:], home: "/Users/x") == "/Users/x/.claude/projects")
        #expect(second.projectsDirectory(environment: [:], home: "/Users/x") == "/Users/x/.claude-b/projects")
    }

    @Test func oldConfigGetsOneAccountAndChoicesRoundTrip() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"workspaces":[{"name":"Geral","projects":[]}]}"#.utf8))
        // Claude Code's own folder, named by WORKSPACES_CONTA when the app runs with it.
        let own = LimitReadingStore.accountName(ProcessInfo.processInfo.environment["WORKSPACES_CONTA"])
        #expect(old.accounts == [Account(name: own)])
        #expect(old.defaultAccount == own)
        #expect(old.retiredAccounts.isEmpty)
        #expect(old.workspaces[0].account == nil)
        let empty = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"accounts":[]}"#.utf8))
        #expect(empty.accounts == [Account(name: own)])

        let saved = SavedSession(id: UUID(), label: "main", claudeSessionId: "c1", account: "conta2")
        let config = AppConfig(workspaces: [Workspace(name: "Sift", projects: [Project(name: "app", path: "/p", savedSessions: [saved])], account: "conta2")],
                               accounts: [main, second], defaultAccount: "conta2", retiredAccounts: [Account(name: "conta3", configDirectory: "/c")])
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        #expect(decoded.workspaces[0].projects[0].savedSessions[0].account == "conta2")
    }
}

@Suite struct AccountFolderTests {
    @Test func emailComesFromTheLogin() throws {
        let folder = temporaryFolder("login")
        let file = folder + "/.claude.json"
        try write(#"{"numStartups": 3, "oauthAccount": {"emailAddress": "a@b.com", "organizationName": "x"}}"#, to: file)
        #expect(AccountLogin.email(stateFile: file) == "a@b.com")
        try write(#"{"numStartups": 3}"#, to: file)
        #expect(AccountLogin.email(stateFile: file) == nil)
        #expect(AccountLogin.email(stateFile: folder + "/missing.json") == nil)
    }

    @Test func newFolderLinksWhatTheOwnFolderHas() throws {
        let own = temporaryFolder("own")
        try write("{}", to: own + "/settings.json")
        try write("x", to: own + "/CLAUDE.md")
        try FileManager.default.createDirectory(atPath: own + "/projects", withIntermediateDirectories: true)
        try write("{}", to: own + "/.credentials.json")
        let target = temporaryFolder("acct") + "/.claude-c"
        let linked = try AccountFolder.prepare(target, sharingWith: own)
        #expect(Set(linked) == ["settings.json", "CLAUDE.md", "projects"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target + "/projects") == own + "/projects")
        #expect(!FileManager.default.fileExists(atPath: target + "/.credentials.json"))
        #expect(!FileManager.default.fileExists(atPath: target + "/skills"))
    }

    @Test func folderInUseIsLeftAlone() throws {
        let own = temporaryFolder("own")
        try write("{}", to: own + "/settings.json")
        let target = temporaryFolder("used")
        try write("{}", to: target + "/.claude.json")
        #expect(try AccountFolder.prepare(target, sharingWith: own).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target + "/settings.json"))
    }
}

private func setModified(_ path: String, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

@Suite struct TranscriptSyncTests {
    @Test func conversationIsCopiedToTheAccountThatResumesIt() throws {
        let from = temporaryFolder("from"), to = temporaryFolder("to")
        let transcript = from + "/-Users-x-app/c1.jsonl"
        try write("{\"a\":1}\n", to: transcript)
        try write("{}", to: from + "/-Users-x-app/c1/subagents/agent-1.jsonl")
        let copy = try #require(TranscriptSync.needed("c1", target: to, folders: [from]))
        #expect(AccountFolder.resolved(copy.from) == AccountFolder.resolved(transcript))
        #expect(copy.to == to + "/-Users-x-app/c1.jsonl")
        try TranscriptSync.apply(copy)
        #expect(FileManager.default.contents(atPath: copy.to) == Data("{\"a\":1}\n".utf8))
        #expect(FileManager.default.fileExists(atPath: to + "/-Users-x-app/c1/subagents/agent-1.jsonl"))
        #expect(FileManager.default.fileExists(atPath: transcript))
        // Once copied, nothing more to do.
        #expect(TranscriptSync.needed("c1", target: to, folders: [from]) == nil)
    }

    @Test func sharedFolderNeedsNoCopy() throws {
        let from = temporaryFolder("shared")
        try write("{}\n", to: from + "/-p/c2.jsonl")
        let account = temporaryFolder("acct")
        try FileManager.default.createSymbolicLink(atPath: account + "/projects", withDestinationPath: from)
        #expect(TranscriptSync.needed("c2", target: account + "/projects", folders: [from]) == nil)
    }

    @Test func goingBackResumesWhatWasWrittenInTheOtherAccount() throws {
        let a = temporaryFolder("a"), b = temporaryFolder("b")
        try write("one\n", to: a + "/-p/c3.jsonl")
        try setModified(a + "/-p/c3.jsonl", Date().addingTimeInterval(-600))
        // To B, then the conversation grows there.
        try TranscriptSync.apply(try #require(TranscriptSync.needed("c3", target: b, folders: [a])))
        try write("one\ntwo\n", to: b + "/-p/c3.jsonl")
        // Back to A: B's copy is newer, and A's is where it started, so A's is replaced.
        let back = try #require(TranscriptSync.needed("c3", target: a, folders: [a, b]))
        #expect(AccountFolder.resolved(back.from) == AccountFolder.resolved(b + "/-p/c3.jsonl"))
        try TranscriptSync.apply(back)
        #expect(FileManager.default.contents(atPath: a + "/-p/c3.jsonl") == Data("one\ntwo\n".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: a + "/-p") == ["c3.jsonl"])
    }

    @Test func aCopyThatWentAnotherWayIsKeptBesideIt() throws {
        let a = temporaryFolder("a"), b = temporaryFolder("b")
        try write("one\nlocal\n", to: a + "/-p/c4.jsonl")
        try setModified(a + "/-p/c4.jsonl", Date().addingTimeInterval(-600))
        try write("one\ntwo\n", to: b + "/-p/c4.jsonl")
        try TranscriptSync.apply(try #require(TranscriptSync.needed("c4", target: a, folders: [b])), now: Date(timeIntervalSince1970: 0))
        #expect(FileManager.default.contents(atPath: a + "/-p/c4.jsonl") == Data("one\ntwo\n".utf8))
        let kept = try FileManager.default.contentsOfDirectory(atPath: a + "/-p").filter { $0.hasPrefix("c4.jsonl.antes-") }
        #expect(kept.count == 1)
        #expect(FileManager.default.contents(atPath: a + "/-p/" + kept[0]) == Data("one\nlocal\n".utf8))
    }

    @Test func unknownConversationsNeedNothing() throws {
        let from = temporaryFolder("from"), to = temporaryFolder("to")
        try write("{}\n", to: from + "/-p/c5.jsonl")
        #expect(TranscriptSync.needed("nope", target: to, folders: [from]) == nil)
        #expect(TranscriptSync.needed("../c5", target: to, folders: [from]) == nil)
    }
}

@Suite struct ConversationAccountsTests {
    @Test func aMovedConversationKeepsWhatItSpentBefore() {
        var owners = ConversationAccounts()
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        let added = owners.record("c", account: "conta1", at: t0)
        let same = owners.record("c", account: "conta1", at: t0.addingTimeInterval(10))
        let moved = owners.record("c", account: "conta2", at: t1)
        #expect(added && !same && moved)
        #expect(owners.account(of: "c", at: Date(timeIntervalSince1970: 500)) == "conta1")
        #expect(owners.account(of: "c", at: Date(timeIntervalSince1970: 1500)) == "conta1")
        #expect(owners.account(of: "c", at: Date(timeIntervalSince1970: 2500)) == "conta2")
        #expect(owners.account(of: "other", at: t1) == nil)
        #expect(owners.changes("c", for: "conta2") == [LedgerFilter.Change(from: 1000, counts: false), LedgerFilter.Change(from: 2000, counts: true)])
    }

    @Test func survivesARestartAndForgetsOldOnes() throws {
        var owners = ConversationAccounts()
        owners.record("old", account: "conta1", at: Date(timeIntervalSince1970: 0))
        owners.record("new", account: "conta2", at: Date(timeIntervalSince1970: 5000))
        var decoded = try JSONDecoder().decode(ConversationAccounts.self, from: JSONEncoder().encode(owners))
        #expect(decoded == owners)
        decoded.prune(before: Date(timeIntervalSince1970: 1000))
        #expect(Array(decoded.conversations.keys) == ["new"])
    }
}

@Suite struct LedgerFilterTests {
    @Test func sumsCountOnlyTheSpendOfTheAccount() {
        let ledger = TokenLedger()
        let now = Date()
        ledger.add(TokenCall(key: "1", time: now.addingTimeInterval(-600), session: "a", output: 100, cwd: "/p"))
        ledger.add(TokenCall(key: "2", time: now.addingTimeInterval(-300), session: "b", output: 300, cwd: "/p"))
        ledger.add(TokenCall(key: "3", time: now.addingTimeInterval(-60), session: "a", output: 100, cwd: "/p"))
        let all = ledger.weight(from: now.addingTimeInterval(-3600))
        func only(_ id: String) -> LedgerFilter { ledger.filter { [LedgerFilter.Change(from: -.infinity, counts: $0 == id)] } }
        let a = ledger.weight(from: now.addingTimeInterval(-3600), only: only("a"))
        let b = ledger.weight(from: now.addingTimeInterval(-3600), only: only("b"))
        #expect(a > 0 && b > 0)
        #expect(abs(a + b - all) < 0.001)
        #expect(abs(b - 3 * a / 2) < 0.001)
        let overview = ledger.overview(now: now, windowStart: now.addingTimeInterval(-5 * 3600), weekStart: now.addingTimeInterval(-86_400),
                                       only: only("a")) { _ in "g" }
        #expect(abs(overview.weightInWindow - a) < 0.001)
        #expect(overview.windowSessions.map(\.id) == ["a"])
        #expect(abs(ledger.heaviest(span: 3600, from: now.addingTimeInterval(-3600), to: now, only: only("a")) - a) < 0.001)
        // A session the ledger learns after the filter was made is left out.
        let before = only("a")
        ledger.add(TokenCall(key: "4", time: now.addingTimeInterval(-30), session: "c", output: 100))
        #expect(abs(ledger.weight(from: now.addingTimeInterval(-3600), only: before) - a) < 0.001)
    }

    @Test func aConversationMovedMidwayCountsForEachAccountInItsStretch() {
        let ledger = TokenLedger()
        let now = Date()
        ledger.add(TokenCall(key: "1", time: now.addingTimeInterval(-600), session: "a", output: 100))
        ledger.add(TokenCall(key: "2", time: now.addingTimeInterval(-60), session: "a", output: 300))
        let switched = now.addingTimeInterval(-300).timeIntervalSince1970
        var owners = ConversationAccounts()
        owners.record("a", account: "conta1", at: now.addingTimeInterval(-900))
        owners.record("a", account: "conta2", at: Date(timeIntervalSince1970: switched))
        let first = ledger.weight(from: now.addingTimeInterval(-3600), only: ledger.filter { owners.changes($0, for: "conta1") ?? [] })
        let second = ledger.weight(from: now.addingTimeInterval(-3600), only: ledger.filter { owners.changes($0, for: "conta2") ?? [] })
        #expect(first > 0 && abs(second - 3 * first) < 0.001)
    }
}
