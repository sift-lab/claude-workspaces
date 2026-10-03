import SwiftUI
import WorkspacesCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.tokens.fiveHourLimit != nil {
                MenuBarLimitSection()
                divider
            }
            let waiting = model.sessionsNeedingYou
            if !waiting.isEmpty {
                SectionLabel(text: "Esperando você")
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                VStack(spacing: 0) {
                    ForEach(waiting) { session in
                        Button { model.focus(sessionId: session.id) } label: {
                            row(title: model.displayLabel(session), subtitle: context(of: session), trailing: RelativeTime.short(since: session.lastChange, now: model.now), bold: true) {
                                StatusGlyph(status: session.status, attention: session.attention)
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(.horizontal, 6)
                divider
            }

            SectionLabel(text: "Workspaces")
                .padding(.horizontal, 16)
                .padding(.top, waiting.isEmpty ? 10 : 2)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                if model.config.workspaces.isEmpty {
                    Text("Nenhum workspace ainda. Crie um nos Ajustes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                ForEach(Array(model.config.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    Button { model.openWorkspaceWindow(workspace.id) } label: {
                        row(title: workspace.name, subtitle: summary(of: workspace), trailing: index < 9 ? "⌃\(index + 1)" : "", bold: false) {
                            EmptyView()
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .padding(.horizontal, 6)

            divider

            VStack(spacing: 0) {
                Button { model.tokens.focused = nil; openWindow(id: "usage"); NSApp.activate(ignoringOtherApps: true) } label: {
                    menuItem("Consumo", shortcut: "")
                }
                .buttonStyle(RowButtonStyle())
                SettingsLink {
                    menuItem("Ajustes", shortcut: "⌘,")
                }
                .buttonStyle(RowButtonStyle())
                Button { NSApp.terminate(nil) } label: { menuItem("Sair", shortcut: "⌘Q") }
                    .buttonStyle(RowButtonStyle())
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(width: 320)
        .background(Theme.surface)
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func context(of session: SessionRuntime) -> String {
        guard let (workspace, project) = model.project(session.projectId) else { return "" }
        return "\(project.name), \(workspace.name)"
    }

    private func summary(of workspace: Workspace) -> String {
        let sessions = model.sessions(inWorkspace: workspace.id)
        guard !sessions.isEmpty else { return "Fechado" }
        let projects = Set(sessions.map(\.projectId)).count
        var text = "\(sessions.count) \(sessions.count == 1 ? "sessão" : "sessões") em \(projects) \(projects == 1 ? "projeto" : "projetos")"
        let waiting = sessions.filter(\.needsYou).count
        if waiting > 0 { text += ", \(waiting) esperando" }
        return text
    }

    private func row<Glyph: View>(title: String, subtitle: String, trailing: String, bold: Bool, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: 10) {
            glyph()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: bold ? .semibold : .regular)).foregroundStyle(Theme.primary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func menuItem(_ title: String, shortcut: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.primary)
            Spacer()
            Text(shortcut).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

/// Shown in a window that has no workspace yet.
struct WorkspacePicker: View {
    let choose: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspaces").font(.system(size: 26, weight: .bold))
                Text("Escolha um workspace para abrir nesta janela.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            if let error = model.configError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.primary)
            }
            VStack(spacing: 0) {
                ForEach(model.config.workspaces) { workspace in
                    Button { choose(workspace.id) } label: {
                        HStack {
                            Text(workspace.name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(workspace.projects.count) \(workspace.projects.count == 1 ? "projeto" : "projetos")")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))

            HStack(spacing: 8) {
                TextField("Novo workspace", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Criar", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(48)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let workspace = model.addWorkspace(named: name)
        newName = ""
        choose(workspace.id)
    }
}
