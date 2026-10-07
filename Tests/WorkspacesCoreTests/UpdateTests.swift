import Foundation
import Testing
@testable import WorkspacesCore

private let installedCommit = "1111111aaaaaaa"
private let mainCommit = "2222222bbbbbbb"

@Suite struct UpdateDecisionTests {
    /// History main <- installed, and origin/main ahead of main.
    private let order = ["1111111aaaaaaa": 1, "2222222bbbbbbb": 2, "3333333ccccccc": 3]
    private func ancestor(_ a: String, _ b: String) -> Bool? {
        guard let x = order[a], let y = order[b] else { return nil }
        return x <= y
    }

    @Test func aNewCommitOnMainIsAnUpdate() {
        #expect(UpdateDecision.check(installed: installedCommit, target: mainCommit, isAncestor: ancestor) == .available(mainCommit))
    }

    @Test func theSameCommitIsUpToDate() {
        #expect(UpdateDecision.check(installed: mainCommit, target: mainCommit, isAncestor: ancestor) == .upToDate)
    }

    @Test func aBuildAheadOfMainIsNeverReplacedByAnOlderOne() {
        // Installed from a branch that main does not have yet (feat/recycle-sessions on 06/10).
        let branch: (String, String) -> Bool? = { a, b in a == b }
        #expect(UpdateDecision.check(installed: "feature", target: mainCommit, isAncestor: branch) == .installedAhead)
    }

    @Test func aCommitTheRepositoryForgotFollowsMain() {
        #expect(UpdateDecision.check(installed: "rebased-away", target: mainCommit, isAncestor: ancestor) == .available(mainCommit))
    }

    @Test func originMainWinsOnlyWhenItIsAheadOfTheLocalMain() {
        #expect(UpdateDecision.target(main: mainCommit, originMain: "3333333ccccccc", isAncestor: ancestor) == "3333333ccccccc")
        // The local main has commits origin lacks (merged here, not pushed): the local one.
        #expect(UpdateDecision.target(main: mainCommit, originMain: installedCommit, isAncestor: ancestor) == mainCommit)
        #expect(UpdateDecision.target(main: mainCommit, originMain: nil, isAncestor: ancestor) == mainCommit)
        #expect(UpdateDecision.target(main: nil, originMain: mainCommit, isAncestor: ancestor) == mainCommit)
        let diverged: (String, String) -> Bool? = { _, _ in false }
        #expect(UpdateDecision.target(main: mainCommit, originMain: "3333333ccccccc", isAncestor: diverged) == mainCommit)
    }

    @Test func theStampComesFromInfoPlist() {
        let stamp = BuildStamp(info: ["WorkspacesCommit": mainCommit, "WorkspacesRepository": "/repo", "WorkspacesDirty": true])
        #expect(stamp == BuildStamp(commit: mainCommit, repository: "/repo", dirty: true))
        #expect(stamp?.short == "2222222")
        #expect(BuildStamp(info: ["CFBundleName": "Workspaces"]) == nil)
        #expect(BuildStamp(info: nil) == nil)
    }
}

@Suite struct BuildGateTests {
    @Test func readsTheFreePercentage() {
        let text = """
        The system has 8589934592 (2097152 pages with a page size of 4096).
        System-wide memory free percentage: 63%
        """
        #expect(BuildGate.freeMemoryPercent(memoryPressureOutput: text) == 63)
        #expect(BuildGate.freeMemoryPercent(memoryPressureOutput: "nothing here") == nil)
    }

    @Test func waitsForMemoryAndDisk() {
        #expect(BuildGate.check(freeMemoryPercent: 31, freeDiskBytes: 10 << 30) == .go)
        #expect(BuildGate.check(freeMemoryPercent: 30, freeDiskBytes: 10 << 30) != .go)
        #expect(BuildGate.check(freeMemoryPercent: nil, freeDiskBytes: 10 << 30) != .go)
        #expect(BuildGate.check(freeMemoryPercent: 80, freeDiskBytes: 1 << 30) != .go)
        #expect(BuildGate.check(freeMemoryPercent: 80, freeDiskBytes: 3 << 30) == .go)
        #expect(BuildGate.check(freeMemoryPercent: 80, freeDiskBytes: nil) == .go)
    }

    @Test func readsTheTeamOfASignature() {
        #expect(CodeSignature.teamIdentifier(codesignOutput: "Identifier=local.workspaces.app\nTeamIdentifier=PP624GBC36\n") == "PP624GBC36")
        #expect(CodeSignature.teamIdentifier(codesignOutput: "Signature=adhoc\nTeamIdentifier=not set\n") == nil)
        #expect(CodeSignature.teamIdentifier(codesignOutput: "code object is not signed at all") == nil)
    }
}

@Suite struct UpdatePromptTests {
    @Test func namesTheWorkingSessions() {
        #expect(UpdatePrompt.interruption(working: 1, waiting: 0)
            == "1 sessão está trabalhando agora. Ela será interrompida e volta com --resume quando o app reabrir.")
        #expect(UpdatePrompt.interruption(working: 3, waiting: 0)
            == "3 sessões estão trabalhando agora. Elas serão interrompidas e voltam com --resume quando o app reabrir.")
        #expect(UpdatePrompt.interruption(working: 2, waiting: 1)
            == "2 sessões estão trabalhando e 1 está esperando você agora. Elas serão interrompidas e voltam com --resume quando o app reabrir.")
        #expect(UpdatePrompt.interruption(working: 0, waiting: 2)
            == "2 sessões estão esperando você agora. Elas serão interrompidas e voltam com --resume quando o app reabrir.")
    }

    @Test func saysWhenNothingIsInterrupted() {
        #expect(UpdatePrompt.interruption(working: 0, waiting: 0).hasPrefix("Nenhuma sessão está trabalhando."))
    }

    @Test func theBodyHasTheVersionAndTheSessions() {
        let body = UpdatePrompt.readyBody(short: "abc1234", subject: "Atualiza sozinho", newCommits: 4, working: 1, waiting: 0)
        #expect(body.hasPrefix("A versão abc1234 está pronta: Atualiza sozinho. São 4 commits novos.\n\n1 sessão está trabalhando"))
    }
}

/// A clock that moves only when the installer sleeps, so timeouts take no real time.
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_791_300_000)
}

private final class Harness {
    let root: URL
    let installed: URL
    let paths: UpdatePaths
    let clock = FakeClock()
    var alive: Set<Int32> = []
    var opened: [String] = []
    var terminated: [URL] = []
    var notes: [String] = []
    /// What opening the installed app does: by default the new build starts and writes its heartbeat.
    var onOpen: ((Harness) -> Void)?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-update-\(UUID().uuidString)", isDirectory: true)
        installed = root.appendingPathComponent("Applications/Workspaces.app", isDirectory: true)
        paths = UpdatePaths(directory: root.appendingPathComponent("support/update", isDirectory: true))
        try makeBundle(at: installed, commit: installedCommit, marker: "old")
        try makeBundle(at: paths.staged, commit: mainCommit, marker: "new")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeBundle(at url: URL, commit: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [BuildStamp.commitKey: commit, BuildStamp.repositoryKey: "/repo"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Workspaces"))
    }

    func marker(_ url: URL) -> String? {
        FileManager.default.contents(atPath: url.appendingPathComponent("Contents/MacOS/Workspaces").path)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func beat(pid: Int32, commit: String) {
        alive.insert(pid)
        try? UpdateHeartbeat(pid: pid, commit: commit, time: clock.now).write(to: paths.heartbeat)
    }

    var plan: UpdatePlan {
        UpdatePlan(appPID: 100, installed: installed.path, commit: mainCommit, updateDirectory: paths.directory.path,
                   startTimeout: 20, exitTimeout: 90)
    }

    func run() -> UpdateInstaller.Outcome {
        let env = UpdateInstaller.Environment(
            isAlive: { [unowned self] in self.alive.contains($0) },
            open: { [unowned self] url in
                self.opened.append(self.marker(url) ?? "?")
                self.onOpen?(self)
                return true
            },
            terminateApp: { [unowned self] url in self.terminated.append(url); self.alive.removeAll() },
            sleep: { [unowned self] seconds in self.clock.now.addTimeInterval(seconds) },
            now: { [unowned self] in self.clock.now },
            notify: { [unowned self] title, body in self.notes.append("\(title): \(body)") },
            log: { _ in })
        return UpdateInstaller(plan: plan, env: env).run()
    }
}

@Suite struct UpdateInstallerTests {
    @Test func swapsKeepsTheBackupAndOpensTheNewVersion() throws {
        let h = try Harness()
        h.onOpen = { h in h.beat(pid: 200, commit: mainCommit) }
        #expect(h.run() == .installed)
        #expect(h.marker(h.installed) == "new")
        #expect(h.marker(h.paths.backup) == "old")
        #expect(h.opened == ["new"])
        #expect(!FileManager.default.fileExists(atPath: h.paths.staged.path))
        #expect(h.paths.failedCommits().isEmpty)
    }

    @Test func putsThePreviousVersionBackWhenTheNewOneDoesNotStart() throws {
        let h = try Harness()
        h.onOpen = { _ in }  // opens, but never writes a heartbeat
        guard case .rolledBack = h.run() else { Issue.record("expected a rollback"); return }
        #expect(h.marker(h.installed) == "old")
        #expect(h.opened == ["new", "old"])
        #expect(h.terminated == [h.installed])
        #expect(h.paths.failedCommits() == [mainCommit])
        #expect(h.notes.last?.hasPrefix("Atualização do Workspaces desfeita") == true)
    }

    @Test func aHeartbeatFromTheOldVersionDoesNotCount() throws {
        let h = try Harness()
        h.onOpen = { h in h.beat(pid: 200, commit: installedCommit) }
        guard case .rolledBack = h.run() else { Issue.record("expected a rollback"); return }
        #expect(h.marker(h.installed) == "old")
    }

    @Test func putsThePreviousVersionBackWhenTheNewOneDiesRightAway() throws {
        let h = try Harness()
        h.onOpen = { h in h.beat(pid: 200, commit: mainCommit) }
        // It writes the heartbeat and is gone one second later, before the stay-up check.
        let env = UpdateInstaller.Environment(
            isAlive: { [unowned h] pid in pid == 200 ? h.clock.now < Date(timeIntervalSince1970: 1_791_300_001) : h.alive.contains(pid) },
            open: { [unowned h] url in h.opened.append(h.marker(url) ?? "?"); h.onOpen?(h); return true },
            terminateApp: { [unowned h] url in h.terminated.append(url) },
            sleep: { [unowned h] seconds in h.clock.now.addTimeInterval(seconds) },
            now: { [unowned h] in h.clock.now },
            notify: { _, _ in }, log: { _ in })
        guard case .rolledBack = UpdateInstaller(plan: h.plan, env: env).run() else { Issue.record("expected a rollback"); return }
        #expect(h.marker(h.installed) == "old")
    }

    @Test func touchesNothingWhileTheAppIsStillOpen() throws {
        let h = try Harness()
        h.alive = [100]
        guard case .aborted = h.run() else { Issue.record("expected an abort"); return }
        #expect(h.marker(h.installed) == "old")
        #expect(h.marker(h.paths.staged) == "new")
        #expect(h.opened.isEmpty)
    }

    @Test func refusesAStagedBuildOfAnotherCommit() throws {
        let h = try Harness()
        try FileManager.default.removeItem(at: h.paths.staged)
        try h.makeBundle(at: h.paths.staged, commit: "something-else", marker: "other")
        guard case .aborted = h.run() else { Issue.record("expected an abort"); return }
        #expect(h.marker(h.installed) == "old")
        // The app had quit: it is opened again as it was.
        #expect(h.opened == ["old"])
    }
}

#if os(macOS)
@Suite struct DetachedProcessTests {
    @Test func theHelperRunsInASessionOfItsOwn() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("ws-detached-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try #require(DetachedProcess.spawn("/bin/sleep", arguments: ["5"], output: log))
        defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        // Its own session: closing the app (and its terminal sessions) does not reach it.
        #expect(getsid(pid) == pid)
        #expect(getsid(pid) != getsid(0))
    }
}
#endif
