import Foundation
import WorkspacesCore

// Claude Code runs this on every hook and on every status line refresh. It links only Foundation,
// so it starts in a few milliseconds instead of loading AppKit and SwiftUI like the app binary.
// Never blocks Claude: when the app does not answer, the hook prints nothing and exits 0.
// A copy of it also applies an update ("apply-update <plan.json>"), after the app quit.
let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "statusline" {
    StatusLineRelay.run()
} else if arguments.first == "apply-update" {
    guard let path = arguments.dropFirst().first, let data = FileManager.default.contents(atPath: path),
          let plan = try? JSONDecoder().decode(UpdatePlan.self, from: data) else {
        FileHandle.standardError.write(Data("apply-update: plano ilegível\n".utf8))
        exit(2)
    }
    let outcome = UpdateInstaller(plan: plan, env: .live(logFile: plan.paths.applyLog)).run()
    exit(outcome == .installed ? 0 : 1)
} else if let session = ProcessInfo.processInfo.environment[ClaudeLaunch.sessionEnvKey] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let payload = JSONValue.parse(data) ?? .null
    let reply = try? IPCClient.send(IPCRequest(kind: .hook, session: session, payload: payload,
                                               launch: ProcessInfo.processInfo.environment[ClaudeLaunch.launchEnvKey]), timeout: 2)
    // The app answers some hooks with JSON for Claude Code (context to add); the rest get "".
    if let text = HookReply.stdout(reply) { FileHandle.standardOutput.write(Data(text.utf8)) }
}
