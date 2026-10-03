import Foundation
import WorkspacesCore

// Claude Code runs this on every hook and on every status line refresh. It links only Foundation,
// so it starts in a few milliseconds instead of loading AppKit and SwiftUI like the app binary.
// Never blocks Claude.
if CommandLine.arguments.dropFirst().first == "statusline" {
    StatusLineRelay.run()
} else if let session = ProcessInfo.processInfo.environment[ClaudeLaunch.sessionEnvKey] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let payload = JSONValue.parse(data) ?? .null
    _ = try? IPCClient.send(IPCRequest(kind: .hook, session: session, payload: payload,
                                          launch: ProcessInfo.processInfo.environment[ClaudeLaunch.launchEnvKey]), timeout: 2)
}
