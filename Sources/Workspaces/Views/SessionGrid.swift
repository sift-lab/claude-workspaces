import SwiftUI
import WorkspacesCore

/// Every session of the workspace at once, three per row, grouped by project.
struct SessionGrid: View {
    let workspaceId: UUID
    let open: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @State private var onlyWaiting = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        let projects = (model.workspace(workspaceId)?.projects ?? []).filter { !visible(in: $0.id).isEmpty || !onlyWaiting }
        VStack(spacing: 0) {
            HStack {
                SegmentedSwitch(options: [("Todas", false), ("Esperando \(waitingCount)", true)], selection: $onlyWaiting)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(projects) { project in
                        HStack {
                            SectionLabel(text: project.name)
                            Spacer()
                            Button("Nova sessão") { model.newSession(projectId: project.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visible(in: project.id)) { session in
                                SessionTile(session: session) { open(session.id) }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        // Screens are read once a second only while a grid is open.
        .onAppear { model.gridAppeared() }
        .onDisappear { model.gridDisappeared() }
    }

    private var waitingCount: Int { model.sessions(inWorkspace: workspaceId).filter(\.needsYou).count }

    private func visible(in projectId: UUID) -> [SessionRuntime] {
        model.sessions(inProject: projectId).filter { !onlyWaiting || $0.needsYou }
    }
}

private struct SessionTile: View {
    let session: SessionRuntime
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        StatusGlyph(status: session.status, attention: session.attention, terminal: session.isTerminal)
                        Text(model.displayLabel(session))
                            .font(.system(size: 12, weight: session.needsYou ? .semibold : .regular))
                            .foregroundStyle(session.needsYou ? Theme.primary : Theme.support)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(RelativeTime.short(since: session.lastChange, now: model.now))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                    if !session.isTerminal {
                        Text(session.label)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 20)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .help(model.tooltip(session))
                Rectangle().fill(Theme.divider).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(session.snapshot.enumerated()), id: \.offset) { _, line in
                        Text(line).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(height: 130)
                .clipped()
                Rectangle().fill(Theme.divider).frame(height: 1)
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(session.needsYou ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(session.needsYou ? Color.white.opacity(0.45) : Color.white.opacity(hovering ? 0.2 : 0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(model.displayLabel(session)), \(footer)")
    }

    private var footer: String {
        if session.status == .waiting { return session.message.map { "Esperando você: \($0)" } ?? "Esperando você" }
        if session.attention { return "Pede sua atenção" }
        return session.detail
    }
}
