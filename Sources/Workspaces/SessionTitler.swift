import Foundation
import WorkspacesCore

/// Names each task: on its first prompt a small model writes the tab and the title, once; `/titulo`
/// and Renomear do the rest. The call never touches the session itself (`claude -p` on the side).
@MainActor
final class SessionTitler {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// UserPromptSubmit. Returns what the hook prints when the prompt was a `/titulo` command.
    func promptSubmitted(_ prompt: String, runtime: SessionRuntime) -> String? {
        if let command = TitleCommand.parse(prompt) { return run(command, runtime: runtime) }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // A recycle's fixed resume message is not the task: not remembered, and the title from before the /clear stays.
        guard !runtime.isTerminal, !text.isEmpty, !model.recycler.isBusy(runtime) else { return nil }
        runtime.remember(prompt: text)
        guard model.config.generateTitles, runtime.title == nil, runtime.titlePending == nil else { return nil }
        generate(runtime, prompts: [text])
        return nil
    }

    /// SessionStart after a /clear: a new task starts, the old title goes to the history.
    /// A recycle keeps it, since the work goes on.
    func cleared(_ runtime: SessionRuntime) {
        guard !model.recycler.isBusy(runtime) else { return }
        if let title = runtime.title {
            runtime.titleHistory = Array(([title.tab] + runtime.titleHistory.filter { $0 != title.tab }).prefix(5))
        }
        runtime.title = nil
        runtime.titlePending = nil
        runtime.prompts = []
        runtime.titleRequest += 1
        model.persist(runtime)
    }

    /// Renomear: the person's names, kept or not.
    func rename(_ runtime: SessionRuntime, tab: String, full: String, keep: Bool) {
        let full = SessionTitle.clean(full, limit: SessionTitle.fullLimit)
        let tab = SessionTitle.clean(tab.trimmingCharacters(in: .whitespaces).isEmpty ? full : tab, limit: SessionTitle.tabLimit)
        guard !tab.isEmpty else { return }
        runtime.titleRequest += 1
        runtime.titlePending = nil
        runtime.title = SessionTitle(tab: tab, full: full.isEmpty ? tab : full, pinned: keep)
        model.persist(runtime)
    }

    func setKept(_ runtime: SessionRuntime, _ keep: Bool) {
        guard runtime.title != nil else { return }
        runtime.title?.pinned = keep
        model.persist(runtime)
    }

    /// "Gerar título de novo" and `/titulo` alone: from the prompts in memory, or the transcript's.
    /// The new title replaces a kept one. False when there is nothing to read the task from.
    @discardableResult
    func regenerate(_ runtime: SessionRuntime) -> Bool {
        guard !runtime.isTerminal else { return false }
        if !runtime.prompts.isEmpty {
            generate(runtime, prompts: runtime.prompts, replacingKept: true)
            return true
        }
        guard let path = runtime.transcriptPath else { return false }
        runtime.titlePending = runtime.title?.full ?? ""
        let request = runtime.titleRequest
        let id = runtime.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let prompts = FileManager.default.contents(atPath: path).map { TranscriptPrompts.read($0) } ?? []
            DispatchQueue.main.async {
                guard let self, let runtime = self.model.session(id), runtime.titleRequest == request else { return }
                runtime.titlePending = nil
                guard !prompts.isEmpty else { return }
                runtime.prompts = prompts
                self.generate(runtime, prompts: prompts, replacingKept: true)
            }
        }
        return true
    }

    private func run(_ command: TitleCommand, runtime: SessionRuntime) -> String {
        switch command {
        case .regenerate:
            return TitleCommand.reply(regenerate(runtime)
                ? "Gerando o título de novo."
                : "Esta conversa ainda não tem pedidos para ler. Use /titulo <texto> para definir o título.")
        case .set(let text):
            let title = SessionTitle.given(text)
            runtime.titleRequest += 1
            runtime.titlePending = nil
            runtime.title = title
            model.persist(runtime)
            // A title too long for the tab gets a short tab written from it; the title stays as typed.
            if text.count > SessionTitle.tabLimit { generate(runtime, prompts: [], given: title.full) }
            return TitleCommand.reply("Título: \(title.full)")
        }
    }

    /// `replacingKept`: asked for by the person, so the answer replaces a kept title.
    private func generate(_ runtime: SessionRuntime, prompts: [String], given: String? = nil, replacingKept: Bool = false) {
        guard let (_, project) = model.project(runtime.projectId) else { return }
        // In the account sessions start in: the one in use may be the one that is spent.
        let env = model.activeAccount.environment(model.toolEnvironment)
        guard let words = ShellSupport.words(model.config.claudeCommand), let first = words.first,
              let executable = ShellSupport.resolve(first, path: env["PATH"]) else { return }
        runtime.titleRequest += 1
        let request = runtime.titleRequest
        if given == nil { runtime.titlePending = prompts.last ?? "" }
        let input = TitlePrompt.request(project: project.name, branch: runtime.label, prompts: prompts, given: given)
        let arguments = Array(words.dropFirst()) + TitlePrompt.arguments(model: model.config.titleModel)
        var environment = env
        environment[ClaudeLaunch.sessionEnvKey] = nil
        environment[ClaudeLaunch.launchEnvKey] = nil
        TitleCall.run(executable: executable, arguments: arguments, input: input, environment: environment) { [weak self, weak runtime] title in
            guard let self, let runtime, runtime.titleRequest == request else { return }
            runtime.titlePending = nil
            guard var title else { return }
            if let given {
                title.full = given
                title.pinned = true
            } else if runtime.title?.pinned == true, !replacingKept {
                return
            }
            runtime.title = title
            self.model.persist(runtime)
        }
    }
}

/// `claude -p` off the main thread, with a deadline. Calls back on the main thread, nil on any failure.
enum TitleCall {
    static func run(executable: String, arguments: [String], input: String, environment: [String: String],
                    timeout: TimeInterval = 45, completion: @escaping @MainActor (SessionTitle?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = AppPaths.supportDirectory
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            // Throws instead of raising when claude already exited and the pipe is closed.
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            let title = process.terminationStatus == 0 ? TitlePrompt.parse(output) : nil
            #if DEBUG
            if title == nil { NSLog("título: claude -p saiu com %d: %@", process.terminationStatus, String(decoding: output.prefix(300), as: UTF8.self)) }
            #endif
            DispatchQueue.main.async { completion(title) }
        }
    }
}
