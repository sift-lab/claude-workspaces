import Foundation
import WorkspacesCore

/// Runs the MCP tools for one calling session.
@MainActor
struct ToolRunner {
    let model: AppModel
    let caller: SessionRuntime?

    func run(_ name: String, _ args: JSONValue) -> ToolResult {
        switch name {
        case "list_sessions": return listSessions(all: args["all_workspaces"] == .bool(true))
        case "set_status": return setStatus(args["text"]?.stringValue)
        case "open_session": return openSession(args)
        case "send_message": return sendMessage(to: args["session"]?.stringValue, text: args["text"]?.stringValue)
        case "notify": return notify(args["text"]?.stringValue)
        case "close_session": return closeSession(args["session"]?.stringValue)
        case "recycle_self": return recycleSelf(args)
        case "recycle_session": return recycleSession(args)
        default: return ToolResult(text: "Ferramenta desconhecida: \(name)", isError: true)
        }
    }

    private var noCaller: ToolResult {
        ToolResult(text: "Esta sessão não foi aberta pelo app Workspaces.", isError: true)
    }

    private func listSessions(all: Bool) -> ToolResult {
        let workspaces = model.config.workspaces.filter { all || caller == nil || $0.id == caller?.workspaceId }
        var lines: [String] = []
        for workspace in workspaces {
            lines.append("Workspace \(workspace.name)")
            for project in workspace.projects {
                lines.append("  Project \(project.name) (\(project.path))")
                let sessions = model.sessions(inProject: project.id)
                if sessions.isEmpty { lines.append("    (no sessions)") }
                for s in sessions {
                    var line = "    - \(s.label) | \(s.status.rawValue) | id \(s.shortId)"
                    if s.isTerminal { line += " | terminal (shell, not Claude)" }
                    if let activity = s.activity, s.status == .working { line += " | \(activity)" }
                    if let message = s.message, s.status == .waiting { line += " | \(message)" }
                    if s.sleep != .awake { line += " | \(s.sleep.rawValue), wakes when opened or messaged" }
                    else if s.host.isRunning { line += " | \(ByteFormat.short(model.currentUsage(s).memory))" }
                    if !s.isTerminal, let context = model.tokens.context(s) { line += " | " + contextText(context) }
                    if let recycle = s.recycle { line += " | \(recycle.text)" }
                    if s.id == caller?.id { line += " (this session)" }
                    lines.append(line)
                }
            }
        }
        return ToolResult(text: lines.isEmpty ? "No workspaces configured." : lines.joined(separator: "\n"))
    }

    private func setStatus(_ text: String?) -> ToolResult {
        guard let caller else { return noCaller }
        let phrase = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        caller.activity = phrase.isEmpty ? nil : String(phrase.prefix(80))
        return ToolResult(text: "ok")
    }

    private func openSession(_ args: JSONValue) -> ToolResult {
        guard let wanted = args["project"]?.stringValue?.lowercased() else {
            return ToolResult(text: "Informe o projeto.", isError: true)
        }
        // Prefer the caller's workspace when two workspaces share a project name.
        let all = model.config.workspaces
        let ordered = all.filter { $0.id == caller?.workspaceId } + all.filter { $0.id != caller?.workspaceId }
        guard let project = ordered.lazy.flatMap(\.projects).first(where: { $0.name.lowercased() == wanted }) else {
            return ToolResult(text: "Projeto \"\(wanted)\" não encontrado. Use list_sessions para ver os nomes.", isError: true)
        }
        let worktree = args["worktree"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        guard let runtime = model.newSession(projectId: project.id, worktree: worktree, prompt: args["prompt"]?.stringValue) else {
            return ToolResult(text: "Não consegui abrir a sessão.", isError: true)
        }
        return ToolResult(text: "Opened session \(runtime.label) (id \(runtime.shortId)) in \(project.name).")
    }

    private enum Target {
        case found(SessionRuntime)
        case failure(ToolResult)
    }

    /// One session of the caller's workspace: an id prefix of at least 4 characters, or a label
    /// that only one session has. Anything ambiguous is refused, never guessed.
    private func target(_ reference: String?) -> Target {
        guard let reference = reference?.lowercased().trimmingCharacters(in: .whitespaces), !reference.isEmpty else {
            return .failure(ToolResult(text: "Informe a sessão (id de list_sessions).", isError: true))
        }
        let scope = model.sessions.filter { caller == nil || $0.workspaceId == caller?.workspaceId }
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

    private func sendMessage(to reference: String?, text: String?) -> ToolResult {
        guard let text, !text.isEmpty else { return ToolResult(text: "Mensagem vazia.", isError: true) }
        guard case .found(let target) = target(reference) else {
            if case .failure(let result) = target(reference) { return result }
            return ToolResult(text: "Sessão não encontrada.", isError: true)
        }
        guard target.id != caller?.id else { return ToolResult(text: "Esta é a própria sessão.", isError: true) }
        guard !target.isTerminal else { return ToolResult(text: "\(target.label) é um terminal, não uma sessão do Claude.", isError: true) }
        let from = caller.map { "[recado de \($0.label)] " } ?? ""
        guard model.deliver(from + text, to: target) else {
            return ToolResult(text: "\(target.label) está encerrada; o recado não foi entregue.", isError: true)
        }
        target.attention = true
        target.lastChange = Date()
        model.updateBadge()
        return ToolResult(text: "Message typed into \(target.label)'s prompt; the person decides when to send it.")
    }

    private func notify(_ text: String?) -> ToolResult {
        guard let caller else { return noCaller }
        caller.attention = true
        model.updateBadge()
        model.announceWaiting(caller, text: text ?? "")
        return ToolResult(text: "ok")
    }

    /// "contexto 412k", with the handoff and the alarm when they apply.
    private func contextText(_ context: Int) -> String {
        let limits = model.contextLimits
        var text = "contexto \(ContextLimits.short(context))"
        switch limits.level(context) {
        case .normal: break
        case .needsHandoff: text += " (precisa de passagem: acima de \(ContextLimits.short(limits.handoff)))"
        case .alarm: text += " (precisa de passagem; alarme: acima de \(ContextLimits.short(limits.alarm)))"
        }
        return text
    }

    private func closeSession(_ reference: String?) -> ToolResult {
        let found = target(reference)
        guard case .found(let target) = found else {
            if case .failure(let result) = found { return result }
            return ToolResult(text: "Sessão não encontrada.", isError: true)
        }
        guard target.id != caller?.id else { return ToolResult(text: "Uma sessão não fecha a si mesma.", isError: true) }
        guard [.done, .idle, .ended].contains(target.status) else {
            return ToolResult(text: "\(target.label) ainda está \(target.status.label.lowercased()).", isError: true)
        }
        model.closeSession(target.id)
        return ToolResult(text: "Closed \(target.label).")
    }

    /// These tools never carry free text: any argument beyond the allowed ones is refused.
    private func refuseExtra(_ args: JSONValue, allowed: Set<String>) -> ToolResult? {
        let extra = RecycleGate.unexpectedArguments(args, allowed: allowed)
        guard !extra.isEmpty else { return nil }
        return ToolResult(text: "Recusado: esta ferramenta não aceita \(extra.joined(separator: ", ")); o texto enviado à sessão é sempre o fixo.", isError: true)
    }

    private func recycleSelf(_ args: JSONValue) -> ToolResult {
        if let refusal = refuseExtra(args, allowed: []) { return refusal }
        guard let caller else { return noCaller }
        return model.recycler.requestSelf(caller)
    }

    private func recycleSession(_ args: JSONValue) -> ToolResult {
        if let refusal = refuseExtra(args, allowed: ["session"]) { return refusal }
        let session: SessionRuntime
        switch target(args["session"]?.stringValue) {
        case .failure(let result): return result
        case .found(let runtime): session = runtime
        }
        guard session.id != caller?.id else {
            return ToolResult(text: "Esta é a própria sessão: use recycle_self, que espera o turno terminar.", isError: true)
        }
        return model.recycler.requestSession(session)
    }
}
