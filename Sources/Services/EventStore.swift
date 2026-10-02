import Foundation

// MARK: - EventStore

/// Persists raw poll event data to disk for debugging and auditing.
///
/// Events are stored in `~/Library/Application Support/ghBonk/events/`
/// organized by date: `events/2024-01-15/poll_103045.json`
///
/// Each poll cycle writes a JSON file containing the raw events and
/// the tracked PR state at that point in time.
actor EventStore {

    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f
    }()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = appSupport
            .appendingPathComponent("ghBonk", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
        self.fileManager = .default
    }

    init(directory: URL) {
        self.directory = directory
        self.fileManager = .default
    }

    // MARK: - Public API

    /// Records a poll cycle's results to disk.
    ///
    /// - Parameters:
    ///   - events: The PR events produced by this poll cycle.
    ///   - trackedPRs: The current tracked PR state after this cycle.
    func recordPollCycle(events: [PREvent], trackedPRs: [TrackedPR]) {
        let now = Date()
        let dayDir = directory.appendingPathComponent(dateFormatter.string(from: now), isDirectory: true)

        do {
            try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        } catch {
            return  // Best-effort; don't crash on write failures
        }

        let filename = "poll_\(timeFormatter.string(from: now)).json"
        let fileURL = dayDir.appendingPathComponent(filename)

        let record = PollCycleRecord(
            timestamp: now,
            eventCount: events.count,
            trackedPRCount: trackedPRs.count,
            events: events,
            trackedPRs: trackedPRs
        )

        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - PollCycleRecord

/// The raw data written for each poll cycle.
struct PollCycleRecord: Codable {
    let timestamp: Date
    let eventCount: Int
    let trackedPRCount: Int
    let events: [PREvent]
    let trackedPRs: [TrackedPR]
}
