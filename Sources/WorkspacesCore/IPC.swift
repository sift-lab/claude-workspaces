import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One message from a helper process (hook or MCP bridge) to the app, one JSON line per connection.
public struct IPCRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A Claude Code hook fired; `payload` is the hook's stdin.
        case hook
        /// An MCP tool call; `tool` and `arguments` are set.
        case tool
        /// Which tools are enabled right now.
        case tools
        /// Claude Code refreshed its status line; `payload` is what it passed (context, limits).
        case statusLine
    }

    public var kind: Kind
    /// The app's id for the session (`WORKSPACES_SESSION`), not Claude's.
    public var session: String?
    public var tool: String?
    public var arguments: JSONValue?
    public var payload: JSONValue?
    /// Which launch of the session sent it (`WORKSPACES_LAUNCH`), so a hook from a process
    /// that was already replaced can be told apart.
    public var launch: String?

    public init(kind: Kind, session: String?, tool: String? = nil, arguments: JSONValue? = nil, payload: JSONValue? = nil,
                launch: String? = nil) {
        self.kind = kind
        self.session = session
        self.tool = tool
        self.arguments = arguments
        self.payload = payload
        self.launch = launch
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String
    public var enabledTools: [String]?

    public init(ok: Bool, text: String, enabledTools: [String]? = nil) {
        self.ok = ok
        self.text = text
        self.enabledTools = enabledTools
    }
}

public enum IPCError: Error, CustomStringConvertible {
    case pathTooLong
    case system(String, Int32)
    case badReply

    public var description: String {
        switch self {
        case .pathTooLong: return "caminho do socket longo demais"
        case .system(let call, let code): return "\(call) falhou: \(String(cString: strerror(code)))"
        case .badReply: return "resposta inválida do app"
        }
    }
}

public enum UnixSocket {
    /// Fills a `sockaddr_un` for `path`. The path must fit in `sun_path` (104 bytes on macOS).
    public static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw IPCError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Reads until a newline or EOF. Returns nil when nothing arrived.
    public static func readLine(fd: Int32, limit: Int = 4 * 1024 * 1024) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0A) { break }
        }
        if let newline = data.firstIndex(of: 0x0A) { data = data[..<newline] }
        return data.isEmpty ? nil : Data(data)
    }

    public static func writeAll(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

public enum IPCClient {
    /// Sends one request to the app and waits for its reply.
    public static func send(_ request: IPCRequest, socketPath: String = AppPaths.socketFile.path,
                            timeout: TimeInterval = 5) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.system("socket", errno) }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = try UnixSocket.address(for: socketPath)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw IPCError.system("connect", errno) }

        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        guard UnixSocket.writeAll(fd: fd, line) else { throw IPCError.system("write", errno) }
        guard let reply = UnixSocket.readLine(fd: fd),
              let response = try? JSONDecoder().decode(IPCResponse.self, from: reply) else {
            throw IPCError.badReply
        }
        return response
    }
}
