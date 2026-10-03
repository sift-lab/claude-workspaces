import AppKit
import SwiftUI

/// `WORKSPACES_SCREENSHOTS=<dir>` makes the app photograph its own screens for the README,
/// framed like a macOS window capture (rounded corners, hairline border, soft shadow).
/// It captures only the app's own windows, so it needs no screen recording permission.
@MainActor
enum ScreenshotMode {
    static var directory: String? { ProcessInfo.processInfo.environment["WORKSPACES_SCREENSHOTS"] }

    /// Seconds to wait before the first shot, so sessions settle (and some fall asleep).
    static var delay: TimeInterval {
        Double(ProcessInfo.processInfo.environment["WORKSPACES_SCREENSHOTS_DELAY"] ?? "") ?? 10
    }

    static func start(model: AppModel) {
        guard let directory else { return }
        acceptTrustPrompts(model: model, until: Date().addingTimeInterval(60))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            run(model: model, directory: directory)
        }
    }

    /// The demo folders are new, so Claude asks whether to trust them. Only in this mode, and
    /// only for the folders the screenshot script creates, the answer is typed for the person.
    private static func acceptTrustPrompts(model: AppModel, until deadline: Date) {
        guard Date() < deadline else { return }
        let demo = ProcessInfo.processInfo.environment["WORKSPACES_SCREENSHOTS_TRUST"] ?? "/nonexistent"
        for session in model.sessions {
            guard let project = model.project(session.projectId)?.project, project.path.hasPrefix(demo) else { continue }
            let screen = session.host.snapshot(lines: 40).joined(separator: "\n")
            if screen.contains("Yes, I trust this folder") {
                session.host.view.send(txt: "\u{1b}[B")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { session.host.view.send(txt: "\r") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { acceptTrustPrompts(model: model, until: deadline) }
    }

    private static func run(model: AppModel, directory: String) {
        let steps: [(TimeInterval, () -> Void)] = [
            (0, {
                // Show the session that waits for the person, like opening it from a notification.
                if let session = model.sessionsNeedingYou.first { model.focusRequest = (session.workspaceId, session.id) }
            }),
            (1.5, { capture(window: workspaceWindow(), name: "window", in: directory) }),
            (2, { model.requestedMode = .grid }),
            (4.5, { capture(window: workspaceWindow(), name: "grid", in: directory) }),
            (5, { model.requestedMode = .single; model.openWindow?(id: "usage") }),
            (8.5, { capture(window: window(titled: "Consumo"), name: "usage", in: directory) }),
            (9, { model.openSettings?() }),
            (11.5, { capture(window: settingsWindow(), name: "settings", in: directory) }),
            (12, { showMenuPanel(model: model) }),
            (14.5, { capture(window: menuPanel, name: "menubar", in: directory, radius: 12) }),
            (15, { NSApp.terminate(nil) }),
        ]
        for (time, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: step)
        }
    }

    private static func workspaceWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("workspace") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.width >= 900 }
    }

    private static func window(titled title: String) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == title }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.lowercased().contains("settings") == true }
            ?? NSApp.windows.first { $0.isVisible && ($0.title.contains("Ajustes") || $0.title.contains("Settings")) }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.width < 900 && $0.frame.width > 700 && $0.title != "Consumo" }
    }

    private static var menuPanel: NSPanel?

    /// The menu bar popover only exists while clicked, so its content is shown in a panel.
    private static func showMenuPanel(model: AppModel) {
        let host = NSHostingView(rootView: MenuBarView().environment(model).preferredColorScheme(.dark))
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: host.fittingSize),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.backgroundColor = .clear
        panel.orderFrontRegardless()
        menuPanel = panel
    }

    // MARK: Framing

    private static func capture(window: NSWindow?, name: String, in directory: String, radius: CGFloat = 10) {
        guard let window, let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("screenshot: no window for %@", name)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let content = rep.cgImage else { return }

        let scale = window.backingScaleFactor
        let size = CGSize(width: CGFloat(content.width), height: CGFloat(content.height))
        let margin = 56 * scale
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let frame = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let shape = CGPath(roundedRect: frame, cornerWidth: radius * scale, cornerHeight: radius * scale, transform: nil)

        // Shadow like a focused macOS window, then a black body (the terminal paints its
        // background on a layer, which a cached display leaves transparent).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 44 * scale,
                      color: CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(content, in: frame)
        ctx.restoreGState()

        ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5 * scale, dy: 0.5 * scale),
                           cornerWidth: radius * scale, cornerHeight: radius * scale, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()

        guard let image = ctx.makeImage() else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        NSLog("screenshot: %@", url.path)
    }
}

/// `WORKSPACES_TOKEN_SHOTS=<dir>` photographs the token screens with this Mac's real transcripts.
/// The sessions seen in the last hours become rows without starting any Claude, so it costs nothing.
/// With `WORKSPACES_TOKEN_SHOTS_METER=1` the meter reads what the transcripts estimate, to show
/// the screens as they look once the status line has reported.
@MainActor
enum TokenShots {
    static var directory: String? { ProcessInfo.processInfo.environment["WORKSPACES_TOKEN_SHOTS"] }

    static func start(model: AppModel) {
        guard let directory else { return }
        waitForData(model: model, directory: directory, tries: 0)
    }

    private static func waitForData(model: AppModel, directory: String, tries: Int) {
        guard let overview = model.tokens.overview else {
            if tries < 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitForData(model: model, directory: directory, tries: tries + 1) }
            } else {
                NSApp.terminate(nil)
            }
            return
        }
        let first = model.addPreviewSessions(overview.windowSessions + overview.topSessions)
        if ProcessInfo.processInfo.environment["WORKSPACES_TOKEN_SHOTS_METER"] == "1", let runtime = first {
            model.tokens.previewMeter(from: runtime)
        }
        model.tokens.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { shoot(model: model, directory: directory) }
    }

    private static func shoot(model: AppModel, directory: String) {
        let hottest = model.sessions.max { (model.tokens.tokens($0)?.weightSinceFrom ?? 0) < (model.tokens.tokens($1)?.weightSinceFrom ?? 0) }
        render(UsageShot(tab: .now), size: CGSize(width: 1180, height: 1180), name: "tokens-now", model: model, in: directory)
        render(UsageShot(tab: .week), size: CGSize(width: 1180, height: 1240), name: "tokens-week", model: model, in: directory)
        if let hottest {
            render(ScrollView { SessionTokensDetail(session: hottest).padding(28) }, size: CGSize(width: 1180, height: 1000),
                   name: "tokens-session", model: model, in: directory)
            render(SessionTokensPopover(session: hottest, close: {}), size: CGSize(width: 384, height: 640),
                   name: "tokens-popover", model: model, in: directory)
            render(HStack(spacing: 12) { ContextMeter(session: hottest); LimitButton() }.padding(16),
                   size: CGSize(width: 520, height: 60), name: "tokens-toolbar", model: model, in: directory)
        }
        render(MenuBarView(), size: CGSize(width: 320, height: 620), name: "tokens-menubar", model: model, in: directory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }

    /// The Consumo window on a given tab, without the window around it.
    private struct UsageShot: View {
        let tab: UsageTab

        var body: some View {
            ScrollView {
                Group {
                    switch tab {
                    case .now: TokensNowView()
                    case .week: TokensWeekView()
                    case .machine: EmptyView()
                    }
                }
                .padding(28)
            }
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize, name: String, model: AppModel, in directory: String) {
        let root = view.environment(model).preferredColorScheme(.dark)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Theme.background)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("token shot: %@", url.path)
            window.orderOut(nil)
        }
    }
}
