import Foundation

/// `<helper> tool <name> [json]`: runs one MCP tool in the app (or the server daemon) from a script.
/// The obra's despachante opens, lists, recycles and closes sessions this way, as no session. Run
/// from inside a session (`WORKSPACES_SESSION` set), it acts as that session, with its limits.
public enum ToolCommand {
    public static let usage = "uso: tool <nome> ['{\"arg\": \"valor\"}']"

    /// The request for the arguments after "tool", or a message saying what is wrong with them.
    public static func request(_ arguments: [String],
                               session: String? = ProcessInfo.processInfo.environment[ClaudeLaunch.sessionEnvKey])
        -> Result<IPCRequest, ToolCommandError> {
        guard let name = arguments.first, !name.isEmpty, arguments.count <= 2 else { return .failure(.usage) }
        var toolArguments = JSONValue.object([:])
        if arguments.count == 2 {
            guard let parsed = JSONValue.parse(Data(arguments[1].utf8)), case .object = parsed else {
                return .failure(.badArguments)
            }
            toolArguments = parsed
        }
        return .success(IPCRequest(kind: .tool, session: session, tool: name, arguments: toolArguments))
    }

    /// Sends it and prints the reply. Exit status: 0 done, 1 the tool refused, 2 bad usage, 3 nobody answered.
    public static func run(_ arguments: [String], socketPath: String = AppPaths.socketFile.path,
                           timeout: TimeInterval = 30) -> Int32 {
        let request: IPCRequest
        switch self.request(arguments) {
        case .failure(let error):
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            return 2
        case .success(let value):
            request = value
        }
        do {
            let reply = try IPCClient.send(request, socketPath: socketPath, timeout: timeout)
            let out = reply.ok ? FileHandle.standardOutput : FileHandle.standardError
            out.write(Data((reply.text + "\n").utf8))
            return reply.ok ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("ninguém respondeu em \(socketPath) (\(error))\n".utf8))
            return 3
        }
    }
}

public enum ToolCommandError: Error, Equatable, CustomStringConvertible {
    case usage
    case badArguments

    public var description: String {
        switch self {
        case .usage: return ToolCommand.usage
        case .badArguments: return "os argumentos da ferramenta precisam ser um objeto JSON. " + ToolCommand.usage
        }
    }
}
