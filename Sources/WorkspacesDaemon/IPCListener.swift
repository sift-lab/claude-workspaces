import Foundation
import WorkspacesCore
#if canImport(Glibc)
import Glibc
#endif

/// Listens on a unix socket for the hook, the MCP bridge and the CLI. One request and one reply per
/// connection. Copy of the app's IPCServer; the handler runs on the daemon's queue.
public final class IPCListener {
    private let path: String
    private let queue: DispatchQueue
    private let handler: (IPCRequest) -> IPCResponse
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, queue: DispatchQueue, handler: @escaping (IPCRequest) -> IPCResponse) {
        self.path = path
        self.queue = queue
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, UnixSocket.stream, 0)
        guard fd >= 0 else { throw IPCError.system("socket", errno) }
        var addr = try UnixSocket.address(for: path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw IPCError.system("bind", errno) }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { throw IPCError.system("listen", errno) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async { [handler, queue] in
            defer { close(client) }
            var tv = UnixSocket.timeout(5)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            UnixSocket.ignoreSigPipe(fd: client)

            let response: IPCResponse
            if let line = UnixSocket.readLine(fd: client),
               let request = try? JSONDecoder().decode(IPCRequest.self, from: line) {
                response = queue.sync { handler(request) }
            } else {
                response = IPCResponse(ok: false, text: "pedido inválido")
            }
            var data = (try? JSONEncoder().encode(response)) ?? Data()
            data.append(0x0A)
            _ = UnixSocket.writeAll(fd: client, data)
        }
    }
}

/// `workspacesd mcp`: stdio MCP server that forwards tool calls to the daemon (the app's MCPBridge).
public enum MCPBridge {
    public static func run(socketPath: String) {
        let session = ProcessInfo.processInfo.environment[ClaudeLaunch.sessionEnvKey]
        let server = MCPServer(
            enabledTools: {
                (try? IPCClient.send(IPCRequest(kind: .tools, session: session), socketPath: socketPath, timeout: 2))?.enabledTools
            },
            callTool: { name, arguments in
                do {
                    let reply = try IPCClient.send(IPCRequest(kind: .tool, session: session, tool: name, arguments: arguments),
                                                   socketPath: socketPath, timeout: 30)
                    return ToolResult(text: reply.text, isError: !reply.ok)
                } catch {
                    return ToolResult(text: "O workspacesd não respondeu (\(error)). Confira com systemctl --user status workspacesd.", isError: true)
                }
            },
            tools: ServerTools.all,
            instructions: ServerTools.instructions
        )
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let message = JSONValue.parse(Data(line.utf8)) else { continue }
            if let reply = server.handle(message) {
                FileHandle.standardOutput.write(reply.encodedLine())
            }
        }
    }
}
