import AppKit
import SwiftUI
import WorkspacesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Workspace windows have their own sessions; window tabs would also claim ⌘T.
        NSWindow.allowsAutomaticWindowTabbing = false
        // A write to a pipe or socket whose reader is gone must fail with EPIPE instead of killing
        // the app and every session in it. A handler, unlike SIG_IGN, is reset by exec, so the
        // shells and Claude processes started from here keep the default.
        signal(SIGPIPE) { _ in }
        // A `kill` or a logout skips applicationWillTerminate; without this the sessions outlive the app.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { AppModel.shared.shutdown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

struct WorkspacesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Workspace", id: "workspace", for: UUID.self) { $workspaceId in
            RootWindow(workspaceId: $workspaceId)
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands { WorkspaceCommands(model: model) }

        Window("Consumo", id: "usage") {
            UsageView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 860)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel(count: model.sessionsNeedingYou.count, limit: menuBarLimit)
        }
        .menuBarExtraStyle(.window)
    }

    /// The 5 h window shows in the menu bar only when it matters: past 80%, or running out before it resets.
    private var menuBarLimit: (text: String, alert: Bool)? {
        guard let limit = model.tokens.fiveHourLimit, !limit.estimated else { return nil }
        let alert = model.tokens.windowAtRisk
        return alert || limit.used >= 80 ? (TokenFormat.percent(limit.used), alert) : nil
    }
}

private struct MenuBarLabel: View {
    let count: Int
    let limit: (text: String, alert: Bool)?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.stack")
            if count > 0 { Text("\(count)") }
            if let limit {
                if limit.alert { Image(systemName: "exclamationmark.triangle") }
                Text(limit.text)
            }
        }
        .accessibilityLabel((count > 0 ? "Workspaces, \(count) esperando você" : "Workspaces") + (limit.map { ", janela de 5 horas em \($0.text)" } ?? ""))
    }
}

private struct WorkspaceCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            NewSessionItems(model: model)
        }
        CommandMenu("Workspaces") {
            WorkspaceMenuItems(model: model)
        }
    }
}

/// File menu: ⌘T and ⇧⌘T act on the workspace window in front.
private struct NewSessionItems: View {
    let model: AppModel

    var body: some View {
        Button("Nova sessão do Claude") { model.frontWindowActions?.newSession() }
            .keyboardShortcut("t", modifiers: .command)
        Button("Novo terminal") { model.frontWindowActions?.newTerminal() }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

private struct WorkspaceMenuItems: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(model.config.workspaces.prefix(9).enumerated()), id: \.element.id) { index, workspace in
            Button(workspace.name) { openWindow(id: "workspace", value: workspace.id) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
        }
    }
}

/// A window starts without a workspace (first launch, ⌘N) and shows the picker.
private struct RootWindow: View {
    @Binding var workspaceId: UUID?
    /// Restored windows ignore writes to `workspaceId` made while appearing, so the choice is also kept here.
    @State private var chosen: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var current: UUID? {
        [workspaceId, chosen].compactMap { $0 }.first { model.workspace($0) != nil }
    }

    var body: some View {
        Group {
            if let id = current {
                WorkspaceWindow(workspaceId: id)
            } else {
                WorkspacePicker { choose($0) }
            }
        }
        .onAppear {
            model.openWindow = openWindow
            model.openSettings = openSettings
            if current == nil, let id = model.takePendingOpen() { choose(id) }
        }
    }

    private func choose(_ id: UUID) {
        chosen = id
        workspaceId = id
    }
}
