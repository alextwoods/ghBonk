import Foundation
import OSLog

// MARK: - PersistenceManager

/// Actor responsible for reading/writing all local state to
/// ~/Library/Application Support/ghBonk/.
///
/// Uses JSON encoding with pretty-printed output and ISO 8601 date formatting.
/// On corrupted data, returns defaults and logs the error (Requirement 10.4).
actor PersistenceManager {

    // MARK: - Properties

    private let directory: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "dev.ghbonk", category: "persistence")

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Initialization

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = appSupport.appendingPathComponent("ghBonk", isDirectory: true)
    }

    /// Designated initializer for testing with a custom directory.
    init(directory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory
    }

    // MARK: - Public API

    /// Encodes and persists a value as pretty-printed JSON.
    ///
    /// Creates the storage directory on first use if it does not exist.
    /// - Parameters:
    ///   - value: The Encodable value to persist.
    ///   - filename: The filename within the storage directory (e.g. "settings.json").
    /// - Throws: `GhBonkError.writeError` if encoding or writing fails.
    func save<T: Encodable>(_ value: T, to filename: String) throws {
        try ensureDirectoryExists()

        let fileURL = directory.appendingPathComponent(filename)

        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw GhBonkError.writeError(filename: filename, underlyingError: error)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw GhBonkError.writeError(filename: filename, underlyingError: error)
        }
    }

    /// Loads and decodes a JSON file from the storage directory.
    ///
    /// - Parameters:
    ///   - type: The Decodable type to decode into.
    ///   - filename: The filename within the storage directory.
    /// - Returns: The decoded value.
    /// - Throws: `GhBonkError.dataCorrupted` if the file doesn't exist or JSON is malformed.
    func load<T: Decodable>(_ type: T.Type, from filename: String) throws -> T {
        let fileURL = directory.appendingPathComponent(filename)

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GhBonkError.dataCorrupted(filename: filename, underlyingError: error)
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GhBonkError.dataCorrupted(filename: filename, underlyingError: error)
        }
    }

    /// Attempts to load a value from disk. On any failure (missing file, corrupted data),
    /// logs the error and returns the provided default value (Requirement 10.4).
    ///
    /// - Parameters:
    ///   - type: The Codable type to decode into.
    ///   - filename: The filename within the storage directory.
    ///   - defaultValue: The fallback value returned when loading fails.
    /// - Returns: The decoded value, or `defaultValue` on failure.
    func loadOrDefault<T: Codable>(_ type: T.Type, from filename: String, default defaultValue: T) -> T {
        do {
            return try load(type, from: filename)
        } catch {
            logger.warning("Failed to load '\(filename)', using defaults: \(error.localizedDescription)")
            return defaultValue
        }
    }

    /// Persists raw data (e.g. check failure payloads) to a file within the storage directory.
    ///
    /// Creates the parent directory (including `check_failures/`) on first use.
    /// - Parameters:
    ///   - data: The raw data to persist.
    ///   - filename: The filename or relative path (e.g. "check_failures/run_12345.json").
    /// - Throws: `GhBonkError.writeError` if writing fails.
    func saveRawData(_ data: Data, to filename: String) throws {
        try ensureDirectoryExists()

        let fileURL = directory.appendingPathComponent(filename)

        // Ensure parent directory exists for nested paths like "check_failures/run_123.json"
        let parentDir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            do {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                throw GhBonkError.writeError(filename: filename, underlyingError: error)
            }
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw GhBonkError.writeError(filename: filename, underlyingError: error)
        }
    }

    /// Loads raw data from a file within the storage directory.
    ///
    /// - Parameter filename: The filename or relative path (e.g. "check_failures/run_12345.json").
    /// - Returns: The raw file data.
    /// - Throws: `GhBonkError.dataCorrupted` if the file doesn't exist or can't be read.
    func loadRawData(from filename: String) throws -> Data {
        let fileURL = directory.appendingPathComponent(filename)

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw GhBonkError.dataCorrupted(filename: filename, underlyingError: error)
        }
    }

    // MARK: - Private Helpers

    /// Creates the storage directory (and `check_failures/` subdirectory) if they don't exist.
    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw GhBonkError.writeError(filename: directory.lastPathComponent, underlyingError: error)
            }
        }

        let checkFailuresDir = directory.appendingPathComponent("check_failures", isDirectory: true)
        if !fileManager.fileExists(atPath: checkFailuresDir.path) {
            do {
                try fileManager.createDirectory(at: checkFailuresDir, withIntermediateDirectories: true)
            } catch {
                throw GhBonkError.writeError(filename: "check_failures", underlyingError: error)
            }
        }
    }
}
