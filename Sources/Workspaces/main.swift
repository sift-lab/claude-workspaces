import Foundation
import WorkspacesCore

// The same binary is the app, the MCP server Claude Code starts, and the hook command.
let arguments = CommandLine.arguments
if arguments.count > 1 {
    switch arguments[1] {
    case "mcp":
        MCPBridge.run()
        exit(0)
    case "hook":
        HookSender.run()
        exit(0)
    case "statusline":
        StatusLineRelay.run()
        exit(0)
    default:
        break
    }
}
WorkspacesApp.main()
