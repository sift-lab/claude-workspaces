import AppKit
import SwiftUI
import WorkspacesCore

enum DetailMode: Hashable { case single, grid }

struct WorkspaceWindow: View {
    let workspaceId: UUID
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var mode: DetailMode = .single
    /// Identifies this window to the model, which never puts the shown session to sleep.
    @State private var windowToken = UUID()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(workspaceId: workspaceId, selection: $selection, mode: $mode)
                .frame(width: 260)
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(spacing: 0) {
                DetailToolbar(workspaceId: workspaceId, selection: selection, mode: $mode)
                Rectangle().fill(Theme.divider).frame(height: 1)
                switch mode {
                case .single: SingleSession(session: model.session(selection), workspaceId: workspaceId)
                case .grid: SessionGrid(workspaceId: workspaceId) { id in
                    selection = id
                    mode = .single
                }
                }
            }
        }
        .background(Theme.background)
        .ignoresSafeArea()
        .navigationTitle(model.workspace(workspaceId)?.name ?? "Workspace")
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            model.startWorkspace(workspaceId)
            if selection == nil { selection = preferredSelection() }
            reportVisible()
        }
        .onChange(of: model.sessions.map(\.id)) { _, ids in
            if let current = selection, ids.contains(current) { return }
            selection = preferredSelection()
        }
        .onChange(of: selection) { _, id in
            if let id { model.markSeen(id) }
            reportVisible()
        }
        .onChange(of: mode) { _, _ in reportVisible() }
        .onChange(of: model.requestedMode) { _, requested in if let requested { mode = requested } }
        .onDisappear { model.setVisible(window: windowToken, session: nil) }
        .onChange(of: model.focusRequest?.session) { _, _ in
            guard let request = model.focusRequest, request.workspace == workspaceId else { return }
            selection = request.session
            mode = .single
            model.focusRequest = nil
        }
    }

    private func reportVisible() {
        model.setVisible(window: windowToken, session: mode == .single ? selection : nil)
    }

    private func preferredSelection() -> UUID? {
        let sessions = model.sessions(inWorkspace: workspaceId)
        return (sessions.first(where: \.needsYou) ?? sessions.first)?.id
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    let workspaceId: UUID
    @Binding var selection: UUID?
    @Binding var mode: DetailMode
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)
            WorkspaceSwitcher(workspaceId: workspaceId)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            SectionLabel(text: "Projetos")
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.workspace(workspaceId)?.projects ?? []) { project in
                        projectHeader(project)
                        if !collapsed.contains(project.id) {
                            ForEach(model.sessions(inProject: project.id)) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            Button(action: addProject) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                    Text("Adicionar projeto").font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .buttonStyle(RowButtonStyle())
            .padding(10)
        }
        .background(Theme.sidebar)
    }

    private func projectHeader(_ project: Project) -> some View {
        let sessions = model.sessions(inProject: project.id)
        let isCollapsed = collapsed.contains(project.id)
        return Button {
            if isCollapsed { collapsed.remove(project.id) } else { collapsed.insert(project.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 10)
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if sessions.contains(where: \.needsYou) {
                    Circle().fill(Theme.primary).frame(width: 6, height: 6)
                }
                Text("\(sessions.count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .buttonStyle(RowButtonStyle())
        .padding(.top, 6)
        .contextMenu {
            Button("Nova sessão em \(project.name)") { newSession(in: project.id) }
            Button("Novo terminal em \(project.name)") { newTerminal(in: project.id) }
            Button("Mostrar no Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
        }
        .accessibilityLabel("\(project.name), \(sessions.count) sessões")
    }

    private func sessionRow(_ session: SessionRuntime) -> some View {
        let selected = selection == session.id && mode == .single
        return Button {
            selection = session.id
            mode = .single
        } label: {
            HStack(spacing: 8) {
                StatusGlyph(status: session.status, attention: session.attention, terminal: session.isTerminal)
                Text(model.displayLabel(session))
                    .font(.system(size: 13, weight: session.needsYou ? .semibold : (selected ? .medium : .regular)))
                    .foregroundStyle(session.needsYou || selected ? Theme.primary : (session.status == .working ? Theme.support : Theme.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                TokenMark(session: session)
                if session.sleep != .awake {
                    Image(systemName: "moon")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .accessibilityLabel(session.sleep == .frozen ? "Congelada" : "Hibernando")
                }
                Text(RelativeTime.short(since: session.lastChange, now: model.now))
                    .font(.system(size: 11))
                    .foregroundStyle(session.needsYou ? Theme.secondary : Theme.tertiary)
            }
            .padding(.leading, 28)
            .padding(.trailing, 10)
            .frame(height: 28)
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .help(session.detail)
        .contextMenu {
            if !session.host.isRunning, session.sleep != .hibernated { Button("Abrir de novo") { model.restart(session.id) } }
            if session.sleep != .awake {
                Button("Acordar") { model.wake(session.id) }
            } else if session.host.isRunning, !model.isOnScreen(session.id) {
                Button(session.hasConversation ? "Hibernar agora" : "Congelar agora") { model.sleepNow(session.id) }
            }
            Button("Nova sessão neste projeto") { newSession(in: session.projectId) }
            if !session.isTerminal {
                Button("Abrir terminal na pasta desta sessão") { newTerminal(in: session.projectId, folder: session.cwd) }
            }
            Divider()
            Button("Fechar sessão") { model.closeSession(session.id) }
        }
    }

    private func newSession(in projectId: UUID) {
        if let runtime = model.newSession(projectId: projectId) {
            selection = runtime.id
            mode = .single
        }
    }

    private func newTerminal(in projectId: UUID, folder: String? = nil) {
        if let runtime = model.newTerminal(projectId: projectId, folder: folder) {
            selection = runtime.id
            mode = .single
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adicionar"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.addProject(path: url.path, to: workspaceId) }
    }
}

private struct WorkspaceSwitcher: View {
    let workspaceId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let index = model.config.workspaces.firstIndex { $0.id == workspaceId }
        Menu {
            ForEach(model.config.workspaces) { workspace in
                Button(workspace.name) { openWindow(id: "workspace", value: workspace.id) }
            }
            Divider()
            SettingsLink { Text("Editar workspaces") }
        } label: {
            HStack(spacing: 8) {
                Text(model.workspace(workspaceId)?.name ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                if let index, index < 9 {
                    Text("⌃\(index + 1)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.rowHover))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Trocar de workspace")
    }
}

// MARK: Toolbar

private struct DetailToolbar: View {
    let workspaceId: UUID
    let selection: UUID?
    @Binding var mode: DetailMode
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if mode == .grid {
                Text(model.workspace(workspaceId)?.name ?? "").font(.system(size: 13, weight: .semibold))
                Text(gridSummary).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else if let session = model.session(selection) {
                HStack(spacing: 6) {
                    Text(model.project(session.projectId)?.project.name ?? "").foregroundStyle(Theme.tertiary)
                    Text("/").foregroundStyle(Theme.faint)
                    Text(model.displayLabel(session)).fontWeight(.semibold).foregroundStyle(Theme.primary)
                }
                .font(.system(size: 13))
                .lineLimit(1)
                if !session.isTerminal { StatusPill(session: session) }
                if session.sleep != .awake { SleepTag(sleep: session.sleep) }
                ContextMeter(session: session)
                UsageBadge(session: session)
                if session.status == .working, let activity = session.activity {
                    Text(activity).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            SegmentedSwitch(options: [("Uma", DetailMode.single), ("Grade", DetailMode.grid)], selection: $mode)
            LimitButton()
            NewTerminalMenu(workspaceId: workspaceId, selection: model.session(selection)) { id in
                selectTerminal(id)
            }
            NewSessionMenu(workspaceId: workspaceId, preferredProject: model.session(selection)?.projectId)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 52)
    }

    /// The window owns the selection; the toolbar asks it to show the new terminal.
    private func selectTerminal(_ id: UUID) {
        model.focusRequest = (workspaceId, id)
    }

    private var gridSummary: String {
        let sessions = model.sessions(inWorkspace: workspaceId)
        let projects = Set(sessions.map(\.projectId)).count
        return "\(sessions.count) \(sessions.count == 1 ? "sessão" : "sessões") em \(projects) \(projects == 1 ? "projeto" : "projetos")"
    }
}

private struct StatusPill: View {
    let session: SessionRuntime

    var body: some View {
        HStack(spacing: 6) {
            StatusGlyph(status: session.status, attention: session.attention, size: 8)
            Text(pillText)
        }
        .font(.system(size: 11))
        .foregroundStyle(session.needsYou ? Theme.primary : Theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .overlay(Capsule().stroke(session.needsYou ? Color.white.opacity(0.18) : Theme.border, lineWidth: 1))
        .help(session.detail)
    }

    private var pillText: String {
        if session.attention && session.status != .waiting { return "Pede sua atenção" }
        return session.status.label
    }
}

/// Beside the state: tells that the session is resting and what opening it does.
struct SleepTag: View {
    let sleep: SleepState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "moon").font(.system(size: 9, weight: .medium))
            Text(sleep == .frozen ? "Congelada" : "Hibernando")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Theme.control))
        .help(sleep == .frozen
              ? "Parada para não gastar CPU. Volta na hora quando você interage."
              : "O processo foi encerrado para liberar memória. A conversa volta sozinha em cerca de 2 s.")
    }
}

/// Memory and CPU of the session, next to its state.
struct UsageBadge: View {
    let session: SessionRuntime

    var body: some View {
        Group {
            if session.sleep == .hibernated {
                Text(session.freedByHibernation > 0 ? "\(ByteFormat.short(session.freedByHibernation)) liberados" : "0 MB")
            } else if session.usage.memory > 0 {
                Text("\(ByteFormat.short(session.usage.memory))  \(ByteFormat.cpu(session.usage.cpu)) CPU")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.tertiary)
        .help("Memória e CPU do Claude e dos servidores MCP desta sessão")
    }
}

/// Opens a plain shell: where the shown session works (its worktree included), or in a chosen project.
private struct NewTerminalMenu: View {
    let workspaceId: UUID
    let selection: SessionRuntime?
    let opened: (UUID) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let projects = model.workspace(workspaceId)?.projects ?? []
        Menu {
            ForEach(projects) { project in
                Button("Novo terminal em \(project.name)") { open(project.id, folder: nil) }
            }
        } label: {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.support)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        } primaryAction: {
            if let selection { open(selection.projectId, folder: selection.cwd) }
            else if let id = projects.first?.id { open(id, folder: nil) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(projects.isEmpty)
        .help("Novo terminal na pasta da sessão aberta (clique longo para escolher o projeto)")
        .accessibilityLabel("Novo terminal")
    }

    private func open(_ projectId: UUID, folder: String?) {
        if let runtime = model.newTerminal(projectId: projectId, folder: folder) { opened(runtime.id) }
    }
}

private struct NewSessionMenu: View {
    let workspaceId: UUID
    let preferredProject: UUID?
    @Environment(AppModel.self) private var model

    var body: some View {
        let projects = model.workspace(workspaceId)?.projects ?? []
        Menu {
            ForEach(projects) { project in
                Button("Nova sessão em \(project.name)") { model.newSession(projectId: project.id) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.support)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        } primaryAction: {
            if let id = preferredProject ?? projects.first?.id { model.newSession(projectId: id) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(projects.isEmpty)
        .help("Nova sessão (clique longo para escolher o projeto)")
        .accessibilityLabel("Nova sessão")
    }
}

// MARK: Single session

private struct SingleSession: View {
    let session: SessionRuntime?
    let workspaceId: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session {
            ZStack(alignment: .bottom) {
                TerminalContainer(host: session.host)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                if session.status == .ended {
                    HStack(spacing: 12) {
                        Text(session.isTerminal ? "O terminal foi encerrado." : "A sessão terminou.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Button("Abrir de novo") { model.restart(session.id) }
                        if !session.isTerminal { Button("Abrir shell aqui") { model.openShell(session.id) } }
                        Button("Fechar") { model.closeSession(session.id) }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    .padding(20)
                }
            }
        } else {
            EmptyWorkspace(workspaceId: workspaceId)
        }
    }
}

private struct EmptyWorkspace: View {
    let workspaceId: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        let projects = model.workspace(workspaceId)?.projects ?? []
        VStack(spacing: 8) {
            Text(projects.isEmpty ? "Nenhum projeto neste workspace" : "Nenhuma sessão aberta")
                .font(.system(size: 15, weight: .semibold))
            Text(projects.isEmpty ? "Adicione uma pasta pela barra lateral." : "Abra uma sessão pelo botão + ou pelo menu de um projeto.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the session's long-lived terminal view; swapping sessions moves views, never restarts them.
struct TerminalContainer: NSViewRepresentable {
    let host: TerminalHost

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = host.view
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { container.window?.makeFirstResponder(view) }
    }
}
