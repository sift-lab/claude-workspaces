import Foundation

/// Gets a line to the person: the phone on the server (ntfy), a list in tests.
public protocol Notifier: AnyObject {
    /// False when there is nowhere to send it; a send that fails later is only logged.
    func post(title: String, body: String) -> Bool
}

/// POST to `<server>/<topic>` with curl: the body is the message, the title goes in a header.
/// It runs off the daemon's queue, so a slow ntfy never holds the hooks back; a failure is logged.
public final class NtfyNotifier: Notifier {
    let server: String
    let topic: String?
    let log: (String) -> Void

    public init(server: String, topic: String?, log: @escaping (String) -> Void) {
        self.server = server
        self.topic = topic
        self.log = log
    }

    public func post(title: String, body: String) -> Bool {
        guard let topic, !topic.isEmpty else {
            log("aviso sem tópico do ntfy em server.json: \(title): \(body)")
            return false
        }
        DispatchQueue.global(qos: .utility).async { [self] in send(topic: topic, title: title, body: body) }
        return true
    }

    private func send(topic: String, title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // Header values must be ASCII; ntfy decodes RFC 2047 words for the rest.
        let encodedTitle = "=?UTF-8?B?\(Data(title.utf8).base64EncodedString())?="
        process.arguments = ["-sS", "-m", "10", "--fail", "-H", "Title: \(encodedTitle)", "--data-binary", "@-",
                             "\(server.hasSuffix("/") ? String(server.dropLast()) : server)/\(topic)"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch {
            log("ntfy: \(error)")
            return
        }
        input.fileHandleForWriting.write(Data(body.utf8))
        try? input.fileHandleForWriting.close()
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 { log("ntfy saiu com \(process.terminationStatus): \(error)") }
    }
}
