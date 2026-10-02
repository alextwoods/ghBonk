import Foundation
import OSLog

// MARK: - FileLogger

/// A file-based logger that writes timestamped log entries to disk.
///
/// Log files are stored in `~/Library/Application Support/ghBonk/logs/`
/// with one file per day (e.g., `2024-01-15.log`).
///
/// Also integrates with OSLog so messages appear in both Console.app and on disk.
actor FileLogger {

    static let shared = FileLogger()

    private let directory: URL
    private let fileManager: FileManager
    private let osLogger = Logger(subsystem: "dev.ghbonk", category: "app")
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = appSupport
            .appendingPathComponent("ghBonk", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        self.fileManager = .default

        // Ensure directory exists
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // For testing
    init(directory: URL) {
        self.directory = directory
        self.fileManager = .default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func info(_ message: String, category: String = "general") {
        let entry = formatEntry(level: "INFO", category: category, message: message)
        appendToFile(entry)
        osLogger.info("\(message)")
    }

    func warning(_ message: String, category: String = "general") {
        let entry = formatEntry(level: "WARN", category: category, message: message)
        appendToFile(entry)
        osLogger.warning("\(message)")
    }

    func error(_ message: String, category: String = "general") {
        let entry = formatEntry(level: "ERROR", category: category, message: message)
        appendToFile(entry)
        osLogger.error("\(message)")
    }

    func debug(_ message: String, category: String = "general") {
        let entry = formatEntry(level: "DEBUG", category: category, message: message)
        appendToFile(entry)
        osLogger.debug("\(message)")
    }

    // MARK: - Private

    private func formatEntry(level: String, category: String, message: String) -> String {
        let timestamp = timestampFormatter.string(from: Date())
        return "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
    }

    private func appendToFile(_ entry: String) {
        let filename = dateFormatter.string(from: Date()) + ".log"
        let fileURL = directory.appendingPathComponent(filename)

        guard let data = entry.data(using: .utf8) else { return }

        if fileManager.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
