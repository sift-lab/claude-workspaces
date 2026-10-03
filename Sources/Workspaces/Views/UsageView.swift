import SwiftUI
import WorkspacesCore

enum UsageTab: Hashable { case now, week, machine }

/// What the sessions spend: tokens now and over the week, and what they cost the machine.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    /// Order by memory, fixed when the screen opens or sessions come and go, so rows do not
    /// jump around every sample.
    @State private var order: [UUID] = []
    @State private var tab: UsageTab = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 28)
            if let id = model.tokens.focused, let session = model.session(id) {
                ScrollView {
                    SessionTokensDetail(session: session)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                }
            } else {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Consumo").font(.system(size: 26, weight: .bold))
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    SegmentedSwitch(options: [("Agora", UsageTab.now), ("Semana", UsageTab.week), ("Máquina", UsageTab.machine)], selection: $tab)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

                switch tab {
                case .now:
                    ScrollView { TokensNowView().padding(.horizontal, 28).padding(.bottom, 28) }
                case .week:
                    ScrollView { TokensWeekView().padding(.horizontal, 28).padding(.bottom, 28) }
                case .machine:
                    machine
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 640)
        .background(Theme.background)
        .ignoresSafeArea()
        .onAppear {
            model.usageAppeared()
            resort()
            // Once more after the first full sample, which the opening sort cannot see yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { resort() }
        }
        .onChange(of: model.sessions.map(\.id)) { _, _ in resort() }
        .onDisappear { model.usageDisappeared() }
    }

    private var subtitle: String {
        switch tab {
        case .now: return "Tokens das sessões abertas e o limite da sua conta, atualizados a cada resposta."
        case .week: return "O gasto das últimas duas semanas: por dia, por workspace e por sessão."
        case .machine: return "Memória e CPU do Claude e dos servidores MCP de cada sessão, atualizados a cada 3 s."
        }
    }

    private var machine: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(.horizontal, 28)
                .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(model.config.workspaces) { workspace in
                        let rows = sorted(model.sessions(inWorkspace: workspace.id))
                        if !rows.isEmpty { group(workspace, rows) }
                    }
                    if model.sessions.isEmpty {
                        Text("Nenhuma sessão aberta.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: Summary

    private var sessionsMemory: UInt64 { model.sessions.reduce(0) { $0 + $1.usage.memory } }
    private var sessionsCPU: Double { model.sessions.reduce(0) { $0 + $1.usage.cpu } }
    private var freed: UInt64 { model.sessions.reduce(0) { $0 + ($1.sleep == .hibernated ? $1.freedByHibernation : 0) } }

    private var summary: some View {
        let awake = model.sessions.filter { $0.sleep == .awake && $0.host.isRunning }.count
        let frozen = model.sessions.filter { $0.sleep == .frozen }.count
        let hibernated = model.sessions.filter { $0.sleep == .hibernated }.count
        return HStack(spacing: 12) {
            tile("Total", ByteFormat.short(sessionsMemory + model.appUsage.memory),
                 "\(ByteFormat.short(sessionsMemory)) nas sessões, \(ByteFormat.short(model.appUsage.memory)) no app")
            tile("CPU agora", ByteFormat.cpu(sessionsCPU + model.appUsage.cpu), "de um núcleo")
            tile("Sessões", "\(awake) \(awake == 1 ? "ativa" : "ativas")", "\(frozen) congeladas, \(hibernated) hibernando")
            tile("Liberado", ByteFormat.short(freed), "pela hibernação")
        }
    }

    private func tile(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.primary)
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
    }

    // MARK: Table

    private func resort() {
        order = model.sessions.sorted { $0.usage.memory > $1.usage.memory }.map(\.id)
    }

    private func sorted(_ sessions: [SessionRuntime]) -> [SessionRuntime] {
        sessions.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    private var largest: UInt64 { max(1, model.sessions.map(\.usage.memory).max() ?? 1) }

    private func group(_ workspace: Workspace, _ rows: [SessionRuntime]) -> some View {
        let total = rows.reduce(UInt64(0)) { $0 + $1.usage.memory }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: workspace.name)
                Spacer()
                Text(ByteFormat.short(total)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                    row(session)
                    if index < rows.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
        }
    }

    private func row(_ session: SessionRuntime) -> some View {
        HStack(spacing: 12) {
            StatusGlyph(status: session.status, attention: session.attention, terminal: session.isTerminal)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayLabel(session)).font(.system(size: 13)).lineLimit(1)
                Text(model.project(session.projectId)?.project.name ?? "")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            stateTag(session).fixedSize().frame(width: 130, alignment: .leading)
            Spacer(minLength: 8)
            bar(session.usage.memory)
            Text(memoryText(session))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(session.sleep == .hibernated ? Theme.tertiary : Theme.primary)
                .frame(width: 96, alignment: .trailing)
            Text(session.host.isRunning && session.sleep == .awake ? ByteFormat.cpu(session.usage.cpu) : "0%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, alignment: .trailing)
            // Color.clear keeps the column when there is no button (a frame on nothing collapses).
            ZStack(alignment: .trailing) {
                Color.clear
                action(session)
            }
            .frame(width: 110, height: 28)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private func memoryText(_ session: SessionRuntime) -> String {
        if session.sleep == .hibernated {
            return session.freedByHibernation > 0 ? "−\(ByteFormat.short(session.freedByHibernation))" : "0 MB"
        }
        return session.host.isRunning ? ByteFormat.short(session.usage.memory) : "encerrada"
    }

    private func bar(_ memory: UInt64) -> some View {
        let fraction = min(1, Double(memory) / Double(largest))
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.control)
            Capsule().fill(Theme.secondary).frame(width: max(0, 80 * fraction))
        }
        .frame(width: 80, height: 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stateTag(_ session: SessionRuntime) -> some View {
        if session.sleep != .awake {
            SleepTag(sleep: session.sleep)
        } else {
            Text(session.status.label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .overlay(Capsule().stroke(Theme.border))
        }
    }

    @ViewBuilder
    private func action(_ session: SessionRuntime) -> some View {
        if session.sleep != .awake {
            Button("Acordar") { model.wake(session.id) }.controlSize(.small)
        } else if session.host.isRunning, !session.shellOnly, [.done, .idle].contains(session.status) {
            Button(session.hasConversation ? "Hibernar agora" : "Congelar agora") { model.sleepNow(session.id) }
                .controlSize(.small)
                .disabled(model.isOnScreen(session.id))
                .help(model.isOnScreen(session.id) ? "Está aberta numa janela" : "Libera os recursos agora; volta ao abrir")
        }
    }
}
