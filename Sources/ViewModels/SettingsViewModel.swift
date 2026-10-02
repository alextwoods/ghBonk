import Foundation
import OSLog

// MARK: - SettingsViewModel

/// ViewModel for the Settings view handling PAT entry/validation,
/// repository list CRUD, polling interval, notification toggles,
/// debug mode, and launch-at-login configuration.
///
/// Requirements:
/// - 1.1: PAT entry, update, and deletion via UI.
/// - 2.1: Repository list add, remove, and reorder.
/// - 5.1, 5.2: Filtering rule display and toggle (delegated to FilterRulesViewModel).
/// - 7.1: Debug mode toggle.
/// - 8.4, 8.5: Notification history filtering and clearing (delegated to HistoryViewModel).
@MainActor
final class SettingsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var patInput: String = ""
    @Published var isValidating: Bool = false
    @Published var validationMessage: String?
    @Published var repos: [Repository] = []
    @Published var newRepoInput: String = ""  // "owner/name" format
    @Published var pollingInterval: TimeInterval = 60
    @Published var notificationsEnabled: Bool = true
    @Published var badgeEnabled: Bool = true
    @Published var debugMode: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var isAuthenticated: Bool = false

    // MARK: - Dependencies

    private let appState: AppState
    private let keychainService: KeychainServiceProtocol
    private let apiClient: GitHubAPIClientProtocol
    private let logger = Logger(subsystem: "dev.ghbonk", category: "settingsVM")

    // MARK: - Initialization

    init(
        appState: AppState,
        keychainService: KeychainServiceProtocol,
        apiClient: GitHubAPIClientProtocol
    ) {
        self.appState = appState
        self.keychainService = keychainService
        self.apiClient = apiClient
    }

    // MARK: - State Sync

    /// Loads current settings from AppState into the ViewModel's published properties.
    func refresh() {
        repos = appState.repoList
        pollingInterval = appState.settings.pollingInterval
        notificationsEnabled = appState.settings.notificationsEnabled
        badgeEnabled = appState.settings.badgeEnabled
        debugMode = appState.settings.debugMode
        launchAtLogin = appState.settings.launchAtLogin

        switch appState.authStatus {
        case .authenticated:
            isAuthenticated = true
        default:
            isAuthenticated = false
        }
    }

    // MARK: - PAT Management

    /// Validates the entered PAT by making a test API call, then stores it in the Keychain
    /// on success. Updates `authStatus` in AppState accordingly.
    func validateAndSavePAT() async {
        let trimmed = patInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Please enter a token."
            return
        }

        isValidating = true
        validationMessage = nil

        do {
            let user = try await apiClient.validateToken(trimmed)
            try keychainService.store(token: trimmed)
            appState.authStatus = .authenticated(user)
            isAuthenticated = true
            validationMessage = "Authenticated as \(user.login)."
            patInput = ""
            logger.info("PAT validated and stored for user: \(user.login)")
        } catch let error as GhBonkError {
            switch error {
            case .tokenInvalid, .tokenExpired:
                appState.authStatus = .invalid
                validationMessage = "Token is invalid or expired."
            default:
                validationMessage = "Validation failed: \(error.localizedDescription)"
            }
            isAuthenticated = false
            logger.error("PAT validation failed: \(error.localizedDescription)")
        } catch {
            validationMessage = "Validation failed: \(error.localizedDescription)"
            isAuthenticated = false
            logger.error("PAT validation failed: \(error.localizedDescription)")
        }

        isValidating = false
    }

    /// Deletes the stored PAT from the Keychain and resets auth state.
    func deletePAT() {
        do {
            try keychainService.delete()
            appState.authStatus = .unknown
            isAuthenticated = false
            validationMessage = "Token removed."
            logger.info("PAT deleted from Keychain")
        } catch {
            validationMessage = "Failed to delete token: \(error.localizedDescription)"
            logger.error("Failed to delete PAT: \(error.localizedDescription)")
        }
    }

    // MARK: - Repository Management

    /// Adds a new repository from `newRepoInput` ("owner/name" format).
    /// Validates the input format before adding.
    func addRepo() {
        let trimmed = newRepoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            validationMessage = "Invalid format. Use \"owner/name\"."
            return
        }

        let owner = String(parts[0])
        let name = String(parts[1])

        // Check for duplicates
        guard !repos.contains(where: { $0.owner == owner && $0.name == name }) else {
            validationMessage = "Repository \(trimmed) is already in the list."
            return
        }

        let repo = Repository(
            id: UUID(),
            owner: owner,
            name: name,
            sortOrder: repos.count
        )

        repos.append(repo)
        appState.repoList = repos
        appState.saveRepoList()
        newRepoInput = ""
        validationMessage = nil
        logger.info("Added repository: \(trimmed)")
    }

    /// Removes repositories at the given offsets.
    func removeRepo(at offsets: IndexSet) {
        repos.remove(atOffsets: offsets)
        reindexRepos()
        appState.repoList = repos
        appState.saveRepoList()
    }

    /// Moves repositories within the list for reordering.
    func moveRepo(from source: IndexSet, to destination: Int) {
        repos.move(fromOffsets: source, toOffset: destination)
        reindexRepos()
        appState.repoList = repos
        appState.saveRepoList()
    }

    // MARK: - Settings Persistence

    /// Saves the polling interval to AppState and persists it.
    /// Clamps the value to the minimum of 30 seconds.
    func savePollingInterval() {
        let clamped = max(pollingInterval, 30)
        pollingInterval = clamped
        appState.settings.pollingInterval = clamped
        appState.saveSettings()
        logger.info("Polling interval set to \(clamped)s")
    }

    /// Saves notification toggle states to AppState and persists them.
    func saveNotificationToggles() {
        appState.settings.notificationsEnabled = notificationsEnabled
        appState.settings.badgeEnabled = badgeEnabled
        appState.saveSettings()
    }

    /// Saves the debug mode setting to AppState and persists it.
    func saveDebugMode() {
        appState.settings.debugMode = debugMode
        appState.saveSettings()
    }

    /// Saves the launch-at-login setting to AppState and persists it.
    func saveLaunchAtLogin() {
        appState.settings.launchAtLogin = launchAtLogin
        appState.saveSettings()
    }

    // MARK: - Private Helpers

    /// Recalculates `sortOrder` for all repos after a reorder or deletion.
    private func reindexRepos() {
        for index in repos.indices {
            repos[index].sortOrder = index
        }
    }
}
