import AppKit
import WorkspacesCore

/// Moves the sessions between Claude Code accounts. Each account logs in once in its own config
/// folder; switching restarts each Claude on the same conversation (`--resume`) in the new folder.
/// When the account in use is spent, it offers the one that is free.
@MainActor
final class AccountSwitcher {
    private unowned let model: AppModel
    /// The last rate limit error a session stopped on, by account.
    private var failedAt: [String: Date] = [:]
    /// The advice already shown, so each one is offered once.
    private var offered: AccountSwitch.Advice?
    private var alertOpen = false

    init(model: AppModel) {
        self.model = model
    }

    /// Each name once, even in a config edited by hand.
    var names: [String] {
        var seen = Set<String>()
        return model.config.accounts.map(\.name).filter { seen.insert($0).inserted }
    }

    /// Nil when it can switch; otherwise why not.
    func problem(switchingTo name: String) -> String? {
        guard let target = model.config.accounts.first(where: { $0.name == name }) else { return "A \(name) não está nos ajustes." }
        let current = model.activeAccount
        guard target.conversationsPath == current.conversationsPath else {
            return "A pasta da \(target.name) guarda as conversas em outro lugar (\(target.conversationsPath)), e a troca não acharia as conversas abertas. A pasta projects dela precisa apontar para \(current.conversationsPath)."
        }
        return nil
    }

    /// A renamed account keeps its rate limit error.
    func renamed(_ old: String, to new: String) {
        if let date = failedAt.removeValue(forKey: old) { failedAt[new] = date }
    }

    func switchTo(_ name: String) {
        guard name != model.activeAccount.name else { return }
        if let problem = problem(switchingTo: name) {
            tell("Não troquei de conta", problem)
            return
        }
        model.config.activeAccount = name
        offered = nil
        moveSessions()
    }

    /// Restarts in the active account each session that is still in another one and is at rest:
    /// its turn over, its box seen empty, no command running in the background, no recycle under way.
    /// The rest move when they get there.
    func moveSessions() {
        let target = model.activeAccount.name
        for runtime in model.sessions where !runtime.isTerminal && !runtime.shellOnly && runtime.host.isRunning {
            guard let account = runtime.account, account != target,
                  runtime.status == .idle || runtime.status == .done,
                  !model.recycler.isBusy(runtime),
                  !(runtime.host.pid.map(ProcessTree.runsShell(under:)) ?? false),
                  PromptScreen.inputIsEmpty(runtime.host.screen(lines: 400)) == true else { continue }
            model.relaunch(runtime, note: "passando para a \(target): a conversa continua")
        }
    }

    /// A turn ended on an API error. A spent limit ends it as "rate_limit".
    func turnFailed(_ error: String?, runtime: SessionRuntime) {
        guard error == "rate_limit", let account = runtime.account else { return }
        failedAt[account] = Date()
        check()
    }

    /// Offers the switch once the account in use is spent: a notification, and the question on a window.
    func check() {
        guard names.count > 1 else { return }
        let active = model.activeAccount.name
        let readings = Dictionary(names.map { ($0, model.tokens.readings(of: $0)) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        guard let advice = AccountSwitch.advice(active: active, accounts: names, readings: readings,
                                                failedAt: failedAt, now: now) else {
            offered = nil
            return
        }
        guard advice != offered, !alertOpen else { return }
        offered = advice
        let renews = AccountSwitch.spentUntil(readings[active] ?? LimitReadings(), now: now)
            .map { "Renova \(TokenFormat.moment($0, now: now))." } ?? "O Claude Code recusou por limite."
        let title = "A \(active) chegou ao limite"
        switch advice {
        case .switchTo(let free):
            let body = "\(renews) A \(free) está livre."
            if let target = model.sessions.first(where: { $0.account == active && !$0.isTerminal }) {
                Notifier.shared.post(title: title, body: body, sessionId: target.id)
            }
            ask(title: title, body: body, button: "Trocar para a \(free)") { [weak self] in self?.switchTo(free) }
        case .waitFor(let other, let until):
            let body = "\(renews) A \(other) libera \(TokenFormat.moment(until, now: now))."
            if let target = model.sessions.first(where: { $0.account == active && !$0.isTerminal }) {
                Notifier.shared.post(title: title, body: body, sessionId: target.id)
            }
        }
    }

    // MARK: Dialogs

    private func ask(title: String, body: String, button: String, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Agora não")
        present(alert) { response in
            if response == .alertFirstButtonReturn { then() }
        }
    }

    func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    /// A sheet on a workspace window, so sessions keep running while it is open.
    private func present(_ alert: NSAlert, then: @escaping (NSApplication.ModalResponse) -> Void) {
        alertOpen = true
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.alertOpen = false
            then(response)
        }
        if let window = model.presentationWindow {
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            done(alert.runModal())
        }
    }
}
