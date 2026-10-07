import Foundation

/// The meter readings of one account (the 5 h window and the week), as the status line reports
/// them. One file per account, `limit-readings-<account>.json`, because a reading does not say
/// which account it is from and two accounts can run on the same machine.
public struct LimitReadings: Codable, Equatable, Sendable {
    public var fiveHour: [MeterReading]
    public var sevenDay: [MeterReading]

    public init(fiveHour: [MeterReading] = [], sevenDay: [MeterReading] = []) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// How long readings are kept.
    public static let horizon: TimeInterval = 15 * 86_400
    static let maxCount = 3000

    /// Keeps only readings that changed something. Returns true when the reading is the newest.
    @discardableResult
    public static func record(_ reading: MeterReading, in list: inout [MeterReading], now: Date = Date()) -> Bool {
        if let last = list.last {
            guard reading.time >= last.time else { return false }
            if last.percent == reading.percent, abs(last.resetsAt.timeIntervalSince(reading.resetsAt)) < 60 {
                list[list.count - 1].time = reading.time
                return true
            }
        }
        list.append(reading)
        let cutoff = now.addingTimeInterval(-horizon)
        list.removeAll { $0.time < cutoff }
        if list.count > maxCount { list.removeFirst(list.count - maxCount) }
        return true
    }
}

public struct LimitReadingStore: Sendable {
    /// The environment variable that names a session's account ("conta1", "conta2").
    public static let accountEnvKey = "WORKSPACES_CONTA"
    public static let defaultAccount = "conta1"

    public let account: String
    public let directory: URL

    public init(account: String, directory: URL = AppPaths.supportDirectory) {
        self.account = account
        self.directory = directory
    }

    /// An account name safe to put in a file name: letters, digits, "-" and "_" only.
    public static func isValidAccount(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    /// The account a process runs in: the value of `WORKSPACES_CONTA` when it is valid, otherwise conta1.
    public static func accountName(_ value: String?) -> String {
        guard let value, isValidAccount(value) else { return defaultAccount }
        return value
    }

    public var url: URL { directory.appendingPathComponent("limit-readings-\(account).json") }
    /// The single file the Mac app wrote before readings were kept per account.
    public var legacyURL: URL { directory.appendingPathComponent("limit-readings.json") }

    /// The account's readings; while its file does not exist yet, the old single file when `legacy` is set.
    public func load(legacy: Bool = false) -> LimitReadings {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(LimitReadings.self, from: data) {
            return saved
        }
        guard legacy, !FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: legacyURL),
              let saved = try? JSONDecoder().decode(LimitReadings.self, from: data) else { return LimitReadings() }
        return saved
    }

    public func save(_ readings: LimitReadings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(readings).write(to: url, options: .atomic)
    }
}
