import Foundation
import OSLog

// MARK: - Polling & Auth Status Enums

enum PollingStatus: Equatable {
    case idle
    case polling
    case paused(reason: String)
    case error(String)
}

enum AuthStatus: Equatable {
    case unknown
    case authenticated(GitHubUser)
    case invalid
    case expired
}

// MARK: - AppState

/// Central observable model that aggregates all live application state.
///
/// ViewModels and Views consume published properties for reactive UI updates.
/// Persistence is performed asynchronously (fire-and-forget) on each mutation
/// to avoid blocking the main actor (Requirements 10.1, 10.3).
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    @Published var trackedPRs: [TrackedPR] = []
    @Published var notificationHistory: [NotificationHistoryEntry] = []
    @Published var filterRules: [FilteringRule] = []
    @Published var repoList: [Repository] = []
    @Published var settings: AppSettings = .default
    @Published var pollingStatus: PollingStatus = .idle
    @Published var authStatus: AuthStatus = .unknown
    @Published var unreadCount: Int = 0

    // MARK: - Dependencies

    private let persistence: PersistenceManager
    private let logger = Logger(subsystem: "dev.ghbonk", category: "appState")

    // MARK: - File Constants

    private enum Files {
        static let settings = "settings.json"
        static let repoList = "repo_list.json"
        static let filterRules = "filter_rules.json"
        static let history = "notification_history.json"
        static let prCache = "tracked_prs.json"
    }

    // MARK: - Initialization

    init(persistence: PersistenceManager) {
        self.persistence = persistence
    }

    // MARK: - State Loading

    /// Restores all persisted state at launch (Requirement 10.3).
    ///
    /// Falls back to defaults for any file that is missing or corrupted (Requirement 10.4).
    func loadState() async {
        settings = await persistence.loadOrDefault(
            AppSettings.self,
            from: Files.settings,
            default: .default
        )

        let defaultRepo = Repository(
            id: UUID(),
            owner: "aws",
            name: "aws-sdk-java-v2",
            sortOrder: 0
        )
        repoList = await persistence.loadOrDefault(
            [Repository].self,
            from: Files.repoList,
            default: [defaultRepo]
        )

        filterRules = await persistence.loadOrDefault(
            [FilteringRule].self,
            from: Files.filterRules,
            default: DefaultFilters.create()
        )

        notificationHistory = await persistence.loadOrDefault(
            [NotificationHistoryEntry].self,
            from: Files.history,
            default: []
        )

        trackedPRs = await persistence.loadOrDefault(
            [TrackedPR].self,
            from: Files.prCache,
            default: []
        )
    }

    // MARK: - Persistence Methods

    /// Persists current settings to disk asynchronously.
    func saveSettings() {
        let value = settings
        Task { [persistence] in
            do {
                try await persistence.save(value, to: Files.settings)
            } catch {
                Logger(subsystem: "dev.ghbonk", category: "appState")
                    .error("Failed to save settings: \(error.localizedDescription)")
            }
        }
    }

    /// Persists the repository list to disk asynchronously.
    func saveRepoList() {
        let value = repoList
        Task { [persistence] in
            do {
                try await persistence.save(value, to: Files.repoList)
            } catch {
                Logger(subsystem: "dev.ghbonk", category: "appState")
                    .error("Failed to save repo list: \(error.localizedDescription)")
            }
        }
    }

    /// Persists filtering rules to disk asynchronously.
    func saveFilterRules() {
        let value = filterRules
        Task { [persistence] in
            do {
                try await persistence.save(value, to: Files.filterRules)
            } catch {
                Logger(subsystem: "dev.ghbonk", category: "appState")
                    .error("Failed to save filter rules: \(error.localizedDescription)")
            }
        }
    }

    /// Persists notification history to disk asynchronously.
    func saveHistory() {
        let value = notificationHistory
        Task { [persistence] in
            do {
                try await persistence.save(value, to: Files.history)
            } catch {
                Logger(subsystem: "dev.ghbonk", category: "appState")
                    .error("Failed to save notification history: \(error.localizedDescription)")
            }
        }
    }

    /// Persists the tracked PR cache to disk asynchronously.
    func savePRCache() {
        let value = trackedPRs
        Task { [persistence] in
            do {
                try await persistence.save(value, to: Files.prCache)
            } catch {
                Logger(subsystem: "dev.ghbonk", category: "appState")
                    .error("Failed to save PR cache: \(error.localizedDescription)")
            }
        }
    }
}
