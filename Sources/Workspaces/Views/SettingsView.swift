import AppKit
import SwiftUI
import WorkspacesCore

private enum SettingsPane: Hashable {
    case general
    case accounts
    case workspace(UUID)
    case claude
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(Theme.divider).frame(width: 1)
            ScrollView {
                Group {
                    switch pane {
                    case .general: GeneralPane()
                    case .accounts: AccountsPane()
                    case .workspace(let id): WorkspacePane(workspaceId: id)
                    case .claude: ClaudePane()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 820, height: 620)
        .background(Theme.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            item("Geral", .general)
            item("Contas", .accounts, trailing: "\(model.config.accounts.count)")
            SectionLabel(text: "Workspaces").padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            ForEach(model.config.workspaces) { workspace in
                item(workspace.name, .workspace(workspace.id), trailing: "\(workspace.projects.count)")
            }
            SectionLabel(text: "Integração").padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            item("Claude Code", .claude)
            Spacer()
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, -10)
            HStack(spacing: 2) {
                Button {
                    let workspace = model.addWorkspace(named: "Novo workspace")
                    pane = .workspace(workspace.id)
                } label: { Image(systemName: "plus").frame(width: 28, height: 24) }
                .accessibilityLabel("Adicionar workspace")
                Button {
                    if case .workspace(let id) = pane {
                        model.removeWorkspace(id)
                        pane = .general
                    }
                } label: { Image(systemName: "minus").frame(width: 28, height: 24) }
                .accessibilityLabel("Remover workspace")
                .disabled({ if case .workspace = pane { return false } else { return true } }())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.support)
            .padding(.top, 6)
        }
        .padding(10)
        .padding(.top, 8)
        .background(Theme.sidebar)
    }

    private func item(_ title: String, _ target: SettingsPane, trailing: String? = nil) -> some View {
        Button { pane = target } label: {
            HStack {
                Text(title).font(.system(size: 13, weight: pane == target ? .medium : .regular))
                    .foregroundStyle(pane == target ? Theme.primary : Theme.support)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .buttonStyle(RowButtonStyle(selected: pane == target))
    }
}

// MARK: Building blocks

private struct SettingsGroup<Content: View>: View {
    let title: String
    var accessory: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
        }
    }
}

private struct FormRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var last = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14)
            .frame(minHeight: subtitle == nil ? 44 : 50)
            if !last { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
    }
}

private struct PaneTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).padding(.bottom, 4)
    }
}

/// Edits locally and writes to the config only on Return or when the field loses focus,
/// instead of on every keystroke.
private struct CommitField: View {
    let placeholder: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onSubmit(save)
    }

    private func save() {
        if text != value { commit(text) }
    }
}

// MARK: Panes

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 24) {
            PaneTitle(text: "Geral")
            if let error = model.configError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.primary)
            }
            SettingsGroup(title: "Comportamento") {
                FormRow(title: "Reabrir as sessões ao abrir um workspace",
                        subtitle: "Retoma a conversa de cada sessão com claude --resume") {
                    Toggle("", isOn: $model.config.reopenSessions).labelsHidden().toggleStyle(.switch)
                }
                FormRow(title: "Notificar quando uma sessão esperar por você", last: true) {
                    Toggle("", isOn: $model.config.notifyWhenWaiting).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup(title: "Economia") {
                FormRow(title: "Congelar sessões paradas",
                        subtitle: "Fora da tela e sem nada rodando: CPU zero, volta na hora ao abrir") {
                    minutesPicker($model.config.freezeAfterMinutes, options: [0, 1, 2, 5, 10])
                }
                FormRow(title: "Hibernar sessões paradas",
                        subtitle: "Encerra o processo e guarda a conversa; retoma em poucos segundos ao abrir", last: true) {
                    minutesPicker($model.config.hibernateAfterMinutes, options: [0, 15, 30, 60, 120])
                }
            }
            SettingsGroup(title: "Contexto") {
                FormRow(title: "Pedir passagem acima de",
                        subtitle: "A sessão aparece como precisa de passagem e recebe um aviso a cada 50 mil a mais", last: true) {
                    Picker("", selection: $model.config.handoffContextTokens) {
                        ForEach([150_000, 200_000, 250_000, 300_000, 400_000], id: \.self) { tokens in
                            Text(TokenFormat.tokens(tokens)).tag(tokens)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            Text("Acima de \(TokenFormat.tokens(ContextLimits.defaultAlarm)) a marca fica vermelha e chega uma notificação. O modelo nunca é trocado e nada é compactado de propósito: a compactação resume sozinha e perde detalhe.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, -16)
            SettingsGroup(title: "Arquivo de configuração") {
                FormRow(title: AppPaths.configFile.path, last: true) {
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configFile]) }
                        .controlSize(.small)
                }
            }
        }
    }
}

private func minutesPicker(_ value: Binding<Int>, options: [Int]) -> some View {
    Picker("", selection: value) {
        ForEach(options, id: \.self) { minutes in
            Text(minutes == 0 ? "Nunca" : minutes < 60 ? "Após \(minutes) min" : "Após \(minutes / 60) h").tag(minutes)
        }
    }
    .labelsHidden()
    .frame(width: 130)
}

private struct WorkspacePane: View {
    let workspaceId: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workspace = model.workspace(workspaceId) {
            VStack(alignment: .leading, spacing: 24) {
                PaneTitle(text: workspace.name)
                SettingsGroup(title: "Geral") {
                    FormRow(title: "Nome") {
                        CommitField(placeholder: "", value: model.workspace(workspaceId)?.name ?? "") { name in
                            model.updateWorkspace(workspaceId) { $0.name = name }
                        }
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 220)
                    }
                    FormRow(title: "Conta", subtitle: "Onde as sessões rodam, menos as que têm conta própria", last: true) {
                        AccountPicker(title: "", selection: workspace.account,
                                      followLabel: "A padrão (\(model.accountLabel(model.config.mainAccount.name)))") { name in
                            model.setAccount(name, workspace: workspaceId)
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                }
                SettingsGroup(title: "Projetos", accessory: AnyView(
                    Button("Adicionar projeto", action: addProject).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.support)
                )) {
                    if workspace.projects.isEmpty {
                        FormRow(title: "Nenhum projeto ainda", last: true) { EmptyView() }
                    }
                    ForEach(Array(workspace.projects.enumerated()), id: \.element.id) { index, project in
                        ProjectRow(project: project, last: index == workspace.projects.count - 1)
                    }
                }
            }
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

private struct AccountsPane: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PaneTitle(text: "Contas")
            Text("Cada conta é uma pasta de configuração do Claude Code (CLAUDE_CONFIG_DIR), com o próprio login. Uma sessão roda na conta escolhida para ela; sem escolha, na do workspace; sem essa, na padrão. Trocar a conta de uma sessão reabre o Claude na outra, na mesma conversa; no meio de um turno, a troca espera o turno acabar.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsGroup(title: "Contas", accessory: AnyView(
                Button("Adicionar conta…", action: add).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.support)
            )) {
                ForEach(Array(model.config.accounts.enumerated()), id: \.element.id) { index, account in
                    row(account, last: index == model.config.accounts.count - 1)
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            Text("Numa pasta nova ou vazia, o app liga as configurações, as instruções, as skills, os plugins e as conversas da pasta do Claude Code; o login fica separado e a primeira sessão aberta nela pede para entrar. Os servidores MCP do usuário ficam no .claude.json de cada conta.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshAccountEmails() }
    }

    private func row(_ account: Account, last: Bool) -> some View {
        let isDefault = account.name == model.config.mainAccount.name
        let folder = account.configDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "pasta do Claude Code"
        let users = sessionsIn(account.name)
        return FormRow(title: model.accountEmail(account) ?? "Sem login ainda",
                       subtitle: "\(account.name) · \(folder) · \(users) \(users == 1 ? "sessão aberta" : "sessões abertas")", last: last) {
            HStack(spacing: 12) {
                if isDefault {
                    Text("Padrão").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                } else {
                    Button("Usar como padrão") { model.setDefaultAccount(account.name) }.controlSize(.small)
                }
                if let directory = account.expandedDirectory {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)]) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .help("Mostrar a pasta no Finder")
                    .accessibilityLabel("Mostrar a pasta de \(account.name) no Finder")
                }
                Button { model.removeAccount(account.name) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .disabled(model.config.accounts.count == 1)
                    .help("Tirar do app. A pasta e o login continuam no disco; o que usava esta conta passa para a padrão.")
                    .accessibilityLabel("Remover \(account.name)")
            }
        }
    }

    private func sessionsIn(_ name: String) -> Int {
        model.sessions.filter { !$0.isTerminal && model.account(for: $0).name == name }.count
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Escolha a pasta da conta, como ~/.claude-b. Para uma conta nova, crie uma pasta vazia."
        panel.prompt = "Adicionar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try model.addAccount(folder: url.path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let last: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 13))
                    Text(project.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).truncationMode(.head)
                    CommitField(placeholder: "Argumentos extras do claude", value: project.claudeArguments) { value in
                        model.updateProject(project.id) { $0.claudeArguments = value }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.support)
                    .help("Vão em todo comando claude deste projeto, por exemplo --add-dir ../api")
                }
                Spacer(minLength: 12)
                Picker("Nova sessão em", selection: Binding(
                    get: { project.newSessionMode },
                    set: { mode in model.updateProject(project.id) { $0.newSessionMode = mode } }
                )) {
                    Text("Pasta do projeto").tag(NewSessionMode.folder)
                    Text("Worktree nova").tag(NewSessionMode.worktree)
                }
                .labelsHidden()
                .frame(width: 150)
                .help("Onde uma sessão nova abre")
                Stepper(value: Binding(
                    get: { project.sessionsOnOpen },
                    set: { n in model.updateProject(project.id) { $0.sessionsOnOpen = n } }
                ), in: 0...6) {
                    Text("\(project.sessionsOnOpen)").font(.system(size: 13)).monospacedDigit().frame(width: 14)
                }
                .help("Sessões que abrem junto com o workspace")
                Button { model.removeProject(project.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityLabel("Remover \(project.name)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            if !last { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
    }
}

private struct ClaudePane: View {
    @Environment(AppModel.self) private var model

    private let toolTitles: [String: (String, String)] = [
        "list_sessions": ("Ver o workspace", "Lista as outras sessões e o estado de cada uma"),
        "set_status": ("Dizer o que está fazendo", "A frase aparece na barra de ferramentas e na grade"),
        "open_session": ("Abrir outra sessão", "Num projeto do workspace, com worktree e conta"),
        "send_message": ("Mandar recado", "Digita na caixa de outra sessão, sem enviar"),
        "notify": ("Pedir sua atenção", "Notificação com uma frase"),
        "close_session": ("Fechar sessões", "Encerra uma sessão parada do mesmo workspace, só sem mudança fora de commit"),
        "recycle_self": ("Recomeçar a própria conversa", "Depois da Passagem no FRENTE.md: registra, limpa e retoma pela passagem"),
        "recycle_session": ("Recomeçar outra sessão", "O mesmo, pedido por uma orquestradora, com a sessão parada"),
    ]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 24) {
            PaneTitle(text: "Claude Code")
            SettingsGroup(title: "Conexão") {
                FormRow(title: "Servidor local") {
                    HStack(spacing: 8) {
                        Circle().fill(model.serverError == nil ? Theme.primary : Theme.faint).frame(width: 6, height: 6)
                        Text(model.serverError == nil ? "Ligado em \(model.sessions.count) \(model.sessions.count == 1 ? "sessão" : "sessões")" : "Parado: \(model.serverError ?? "")")
                            .font(.system(size: 12)).foregroundStyle(Theme.support)
                    }
                }
                FormRow(title: "Hooks e MCP", subtitle: "Cada sessão aberta pelo app já recebe os dois; seu ~/.claude fica como está") {
                    EmptyView()
                }
                FormRow(title: "Comando", subtitle: "Resolvido pelo seu shell de login", last: true) {
                    CommitField(placeholder: "claude", value: model.config.claudeCommand) { model.config.claudeCommand = $0 }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 220)
                }
            }
            SettingsGroup(title: "O que uma sessão pode fazer") {
                ForEach(Array(WorkspaceTools.all.enumerated()), id: \.element.name) { index, tool in
                    let titles = toolTitles[tool.name] ?? (tool.name, "")
                    FormRow(title: titles.0, subtitle: titles.1, last: index == WorkspaceTools.all.count - 1) {
                        HStack(spacing: 16) {
                            Text(tool.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                            Toggle("", isOn: Binding(
                                get: { !model.config.disabledTools.contains(tool.name) },
                                set: { on in
                                    var disabled = model.config.disabledTools.filter { $0 != tool.name }
                                    if !on { disabled.append(tool.name) }
                                    model.config.disabledTools = disabled
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
            }
            Text("O Claude Code pede sua permissão na primeira vez que a sessão usa cada ferramenta.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
    }
}
