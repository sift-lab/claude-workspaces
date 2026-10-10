import SwiftUI
import WorkspacesCore

/// The accounts with a check on the chosen one. Nil is `followLabel`: the workspace's account for a
/// session, the default one for a workspace.
struct AccountPicker: View {
    let title: String
    let selection: String?
    var followLabel: String?
    let choose: (String?) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: choose)) {
            if let followLabel { Text(followLabel).tag(String?.none) }
            ForEach(model.config.accounts) { account in
                Text(model.accountLabel(account.name)).tag(String?.some(account.name))
            }
        }
    }
}

/// Beside the session's state: the account it runs in, and a menu to put it in another one.
struct AccountTag: View {
    let session: SessionRuntime
    @Environment(AppModel.self) private var model

    var body: some View {
        let chosen = model.account(for: session).name
        let workspace = model.config.account(of: model.workspace(session.workspaceId)).name
        Menu {
            AccountPicker(title: "Conta desta sessão", selection: model.ownAccount(of: session),
                          followLabel: "A do workspace (\(model.accountLabel(workspace)))") { name in
                model.setAccount(name, session: session.id)
            }
            .pickerStyle(.inline)
            if session.pendingAccountSwitch != nil {
                Divider()
                Button("Trocar agora, interrompendo o que estiver rodando") { model.switchAccountNow(session.id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle").font(.system(size: 10, weight: .medium))
                Text(model.accountShortLabel(chosen))
                if session.pendingAccountSwitch != nil {
                    Text("troca pendente").foregroundStyle(Theme.tertiary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.control))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(session.pendingAccountSwitch.map { "\($0): passa para a conta \(model.accountLabel(chosen)), na mesma conversa." }
              ?? "Conta do Claude Code desta sessão: \(model.accountLabel(chosen)). Trocar reabre a sessão na outra conta, na mesma conversa.")
        .accessibilityLabel("Conta \(model.accountLabel(chosen))")
    }
}

/// Which account the meter shows, with the 5 h window of each. Only with more than one account.
struct MeterAccountPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        if model.config.accounts.count > 1 {
            Picker("Conta", selection: Binding(get: { tokens.meterAccount }, set: { tokens.meterAccount = $0 })) {
                ForEach(tokens.accountLimits, id: \.account) { item in
                    let used = item.limit.map { " · \(TokenFormat.percent($0.used))" } ?? ""
                    Text(model.accountLabel(item.account) + used).tag(item.account)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("O limite mostrado é o desta conta")
        }
    }
}
