import Foundation
import WorkspacesCore

/// The MCP tools on the server, with the app's texts where they apply (ToolRunner in the app).
extension Daemon {
    func runTool(_ name: String, _ args: JSONValue, caller: ServerSession?) -> ToolResult {
        switch name {
        case "list_sessions": return listSessions(all: args["all_workspaces"] == .bool(true), caller: caller)
        case "set_status": return setStatus(args["text"]?.stringValue, caller: caller)
        case "open_session": return openSession(args, caller: caller)
        case "send_message": return sendMessage(to: args["session"]?.stringValue, text: args["text"]?.stringValue, caller: caller)
        case "notify": return notify(args["text"]?.stringValue, caller: caller)
        case "close_session": return closeSession(args, caller: caller)
        case "recycle_self": return recycleSelf(args, caller: caller)
        case "recycle_session": return recycleSession(args, caller: caller)
        default: return ToolResult(text: "Ferramenta desconhecida: \(name)", isError: true)
        }
    }

    private var noCaller: ToolResult {
        ToolResult(text: "Esta sessão não foi aberta pelo workspacesd.", isError: true)
    }

    private func listSessions(all: Bool, caller: ServerSession?) -> ToolResult {
        let workspaces = config.workspaces.filter { all || caller == nil || $0.id == caller?.record.workspaceId }
        var lines: [String] = []
        for workspace in workspaces {
            lines.append("Workspace \(workspace.name)")
            for project in workspace.projects {
                lines.append("  Project \(project.name) (\(project.path))")
                let list = sessions.filter { $0.record.projectId == project.id }
                if list.isEmpty { lines.append("    (no sessions)") }
                for s in list { lines.append("    - " + describe(s, caller: caller)) }
            }
        }
        return ToolResult(text: lines.isEmpty ? "No workspaces configured." : lines.joined(separator: "\n"))
    }

    func describe(_ s: ServerSession, caller: ServerSession?) -> String {
        let awake = isAwake(s)
        let status: SessionStatus = !s.hibernated && !awake ? .ended : s.status
        var line = "\(s.label) | \(status.rawValue) | id \(s.shortId) | \(s.record.account) | \(s.record.model ?? "modelo padrão")"
        if let activity = s.activity, status == .working { line += " | \(activity)" }
        if let message = s.message, status == .waiting { line += " | \(message)" }
        if s.hibernated { line += " | hibernated, wakes when opened or messaged" }
        if let context = s.contextTokens { line += " | " + contextText(context) }
        if let until = s.rateLimitedUntil {
            line += " | limite da conta: continua sozinha às \(Self.clock(until))"
        }
        if let recycle = s.recycle { line += " | \(recycle.text)" }
        if s.id == caller?.id { line += " (this session)" }
        return line
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter.string(from: date)
    }

    private func contextText(_ context: Int) -> String {
        let limits = config.contextLimits
        var text = "contexto \(ContextLimits.short(context))"
        switch limits.level(context) {
        case .normal: break
        case .needsHandoff: text += " (precisa de passagem: acima de \(ContextLimits.short(limits.handoff)))"
        case .alarm: text += " (precisa de passagem; alarme: acima de \(ContextLimits.short(limits.alarm)))"
        }
        return text
    }

    private func setStatus(_ text: String?, caller: ServerSession?) -> ToolResult {
        guard let caller else { return noCaller }
        let phrase = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        caller.activity = phrase.isEmpty ? nil : String(phrase.prefix(80))
        return ToolResult(text: "ok")
    }

    private func openSession(_ args: JSONValue, caller: ServerSession?) -> ToolResult {
        func text(_ key: String) -> String? {
            args[key]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var place: (workspace: Workspace, project: Project)?
        var folder: String?
        if let path = text("path") {
            let expanded = (path as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isFolder), isFolder.boolValue else {
                return ToolResult(text: "A pasta \(path) não existe no servidor.", isError: true)
            }
            folder = expanded
        } else if let wanted = text("project")?.lowercased() {
            // Prefer the caller's workspace when two workspaces share a project name.
            let all = config.workspaces
            let ordered = all.filter { $0.id == caller?.record.workspaceId } + all.filter { $0.id != caller?.record.workspaceId }
            guard let found = ordered.lazy.flatMap({ w in w.projects.map { (w, $0) } }).first(where: { $0.1.name.lowercased() == wanted }) else {
                return ToolResult(text: "Projeto \"\(wanted)\" não encontrado. Use list_sessions para ver os nomes, ou passe path.", isError: true)
            }
            place = (found.0, found.1)
        } else {
            return ToolResult(text: "Informe o projeto ou a pasta (path).", isError: true)
        }
        let account = text("account") ?? caller?.record.account ?? server.defaultAccount
        guard LimitReadingStore.isValidAccount(account) else {
            return ToolResult(text: "Conta inválida: \(account).", isError: true)
        }
        let configDirectory = server.configDirectory(account: account)
        guard FileManager.default.fileExists(atPath: configDirectory) else {
            return ToolResult(text: "A conta \(account) não tem pasta de configuração (\(configDirectory)). Confira o server.json.", isError: true)
        }
        let model = text("model")
        if let model, !Self.isValidModel(model) {
            return ToolResult(text: "Modelo inválido: \(model).", isError: true)
        }
        let worktree = text("worktree")
        if let worktree, worktree.contains("/") || worktree.hasPrefix(".") || worktree.hasPrefix("-") {
            return ToolResult(text: "Nome de worktree inválido: \(worktree).", isError: true)
        }
        // Only now, with everything valid, a new folder becomes a project.
        if let folder { place = projectFor(path: folder) }
        guard let place else { return ToolResult(text: "Informe o projeto ou a pasta (path).", isError: true) }
        // The first number no session of the project uses, so a label never repeats after a close.
        let labels = Set(sessions.map { $0.label.lowercased() })
        let label = worktree ?? (1...).lazy.map { "\(place.project.name) \($0)" }.first { !labels.contains($0.lowercased()) }!
        let record = ServerSessionRecord(label: label, workspaceId: place.workspace.id, projectId: place.project.id,
                                         worktree: worktree, account: account, model: model)
        let session = ServerSession(record: record, now: scheduler.now)
        sessions.append(session)
        if let failure = launch(session, prompt: text("prompt")) {
            sessions.removeAll { $0.id == session.id }
            saveSessions()
            return ToolResult(text: "Não consegui abrir a sessão: \(failure).", isError: true)
        }
        return ToolResult(text: "Opened session \(session.label) (id \(session.shortId)) in \(place.project.name), \(account), \(model ?? "modelo padrão"). Terminal: tmux attach -t \(session.terminalName).")
    }

    private enum Target {
        case found(ServerSession)
        case failure(ToolResult)
    }

    /// One session of the caller's workspace (any, for a script): an id prefix of at least 4
    /// characters, or a label only one session has. Anything ambiguous is refused, never guessed.
    private func target(_ reference: String?, caller: ServerSession?) -> Target {
        guard let reference = reference?.lowercased().trimmingCharacters(in: .whitespaces), !reference.isEmpty else {
            return .failure(ToolResult(text: "Informe a sessão (id de list_sessions).", isError: true))
        }
        let scope = sessions.filter { caller == nil || $0.record.workspaceId == caller?.record.workspaceId }
        var matches = reference.count >= 4 ? scope.filter { $0.id.uuidString.lowercased().hasPrefix(reference) } : []
        if matches.isEmpty { matches = scope.filter { $0.label.lowercased() == reference } }
        switch matches.count {
        case 1: return .found(matches[0])
        case 0: return .failure(ToolResult(text: "Sessão não encontrada neste workspace.", isError: true))
        default:
            let ids = matches.map { "\($0.label) (id \($0.shortId))" }.joined(separator: ", ")
            return .failure(ToolResult(text: "Mais de uma sessão casa com \"\(reference)\": \(ids). Use o id.", isError: true))
        }
    }

    private func sendMessage(to reference: String?, text: String?, caller: ServerSession?) -> ToolResult {
        guard let text, !text.isEmpty else { return ToolResult(text: "Mensagem vazia.", isError: true) }
        let session: ServerSession
        switch target(reference, caller: caller) {
        case .failure(let result): return result
        case .found(let found): session = found
        }
        guard session.id != caller?.id else { return ToolResult(text: "Esta é a própria sessão.", isError: true) }
        if recycler.isBusy(session) {
            return ToolResult(text: "Recusado: \(session.label) está no meio de uma reciclagem; mande de novo quando ela terminar.", isError: true)
        }
        let from = caller.map { "[recado de \($0.label)] " } ?? ""
        let wasHibernated = session.hibernated
        guard deliver(from + text, to: session) else {
            return ToolResult(text: "\(session.label) está encerrada; o recado não foi entregue.", isError: true)
        }
        session.attention = true
        session.lastChange = scheduler.now
        if wasHibernated {
            return ToolResult(text: "\(session.label) estava hibernando e está voltando com --resume; o recado é colado e enviado quando a caixa de entrada abrir.")
        }
        return ToolResult(text: "Message pasted into \(session.label)'s prompt and Enter pressed.")
    }

    private func notify(_ text: String?, caller: ServerSession?) -> ToolResult {
        let body = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { return ToolResult(text: "Mensagem vazia.", isError: true) }
        caller?.attention = true
        let title = caller.map { "\($0.label) pede atenção" } ?? "workspacesd"
        guard notifier.post(title: title, body: body) else {
            return ToolResult(text: "Não consegui mandar o aviso (sem tópico do ntfy no server.json, ou o ntfy não respondeu); ficou no workspacesd.log.", isError: true)
        }
        return ToolResult(text: "ok")
    }

    private func refuseExtra(_ args: JSONValue, allowed: Set<String>) -> ToolResult? {
        let extra = RecycleGate.unexpectedArguments(args, allowed: allowed)
        guard !extra.isEmpty else { return nil }
        return ToolResult(text: "Recusado: esta ferramenta não aceita \(extra.joined(separator: ", ")); o texto enviado à sessão é sempre o fixo.", isError: true)
    }

    private func closeSession(_ args: JSONValue, caller: ServerSession?) -> ToolResult {
        if let refusal = refuseExtra(args, allowed: ["session"]) { return refusal }
        switch target(args["session"]?.stringValue, caller: caller) {
        case .failure(let result): return result
        case .found(let session):
            guard session.id != caller?.id else { return ToolResult(text: "Uma sessão não fecha a si mesma.", isError: true) }
            return recycler.close(session)
        }
    }

    private func recycleSelf(_ args: JSONValue, caller: ServerSession?) -> ToolResult {
        if let refusal = refuseExtra(args, allowed: []) { return refusal }
        guard let caller else { return noCaller }
        return recycler.requestSelf(caller)
    }

    private func recycleSession(_ args: JSONValue, caller: ServerSession?) -> ToolResult {
        if let refusal = refuseExtra(args, allowed: ["session"]) { return refusal }
        switch target(args["session"]?.stringValue, caller: caller) {
        case .failure(let result): return result
        case .found(let session):
            guard session.id != caller?.id else {
                return ToolResult(text: "Esta é a própria sessão: use recycle_self, que espera o turno terminar.", isError: true)
            }
            return recycler.requestSession(session)
        }
    }
}
