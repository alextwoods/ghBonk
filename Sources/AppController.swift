import Foundation
import OSLog
import ServiceManagement
@preconcurrency import UserNotifications

// MARK: - AppController

/// Composition root that owns the full dependency graph and orchestrates
/// application initialization.
///
/// Responsibilities:
/// - Instantiates all services (Persistence, Keychain, GitHub API) and engines (Polling, Notification)
/// - Restores persisted state on launch
/// - Retrieves and validates the PAT from Keychain
/// - Starts polling when a valid token exists
/// - Requests notification authorization
///
/// Requirements:
/// - 10.3: Restore persisted state on launch without requiring network.
/// - 11.1: Present as a standard macOS Dock application with a main window.
@MainActor
final class AppController: ObservableObject {

    // MARK: - Public Dependencies

    let appState: AppState
    let persistence: PersistenceManager
    let keychainService: KeychainService
    private(set) var apiClient: GitHubAPIClient?
    private(set) var pollingEngine: PollingEngine?
    let notificationEngine: NotificationEngine
    private let notificationService: UNNotificationService

    private let logger = Logger(subsystem: "dev.ghbonk", category: "appController")
    private let fileLogger = FileLogger.shared
    private let eventStore = EventStore()

    // MARK: - Initialization

    init() {
        self.persistence = PersistenceManager()
        self.keychainService = KeychainService()
        self.appState = AppState(persistence: persistence)
        self.notificationService = UNNotificationService()
        self.notificationEngine = NotificationEngine(
            systemService: notificationService
        )
    }

    // MARK: - App Lifecycle

    /// Performs full application initialization sequence:
    /// 1. Load persisted state into AppState
    /// 2. Request notification authorization
    /// 3. Retrieve PAT from Keychain
    /// 4. If PAT exists, validate and start polling
    /// 5. If no PAT, set authStatus to .unknown (UI will show auth prompt)
    func initialize() async {
        await fileLogger.info("ghBonk initializing...", category: "lifecycle")

        // 1. Restore persisted state (Requirement 10.3)
        await appState.loadState()

        // 2. Request notification authorization (best-effort)
        do {
            _ = try await notificationService.requestAuthorization()
        } catch {
            logger.warning("Notification authorization request failed: \(error.localizedDescription)")
        }

        // 3. Retrieve PAT from Keychain
        guard let token = try? keychainService.retrieve(), !token.isEmpty else {
            appState.authStatus = .unknown
            logger.info("No PAT found in Keychain; awaiting user authentication")
            return
        }

        // 4. Create API client and validate token
        let client = GitHubAPIClient(token: token)
        self.apiClient = client

        do {
            let user = try await client.validateToken(token)
            appState.authStatus = .authenticated(user)
            logger.info("Token validated for user: \(user.login)")
            await fileLogger.info("Authenticated as \(user.login)", category: "auth")

            // 5. Start polling
            startPolling(client: client, currentUser: user)
        } catch {
            appState.authStatus = .invalid
            logger.error("Token validation failed: \(error.localizedDescription)")
            await fileLogger.error("Token validation failed: \(error.localizedDescription)", category: "auth")
        }
    }

    // MARK: - Polling Management

    /// Creates and starts the polling engine with the current settings and repos.
    func startPolling(client: GitHubAPIClientProtocol, currentUser: GitHubUser) {
        let engine = PollingEngine(
            apiClient: client,
            interval: appState.settings.pollingInterval,
            repos: appState.repoList,
            currentUser: currentUser
        )
        self.pollingEngine = engine

        Task {
            // Seed with persisted polling state so we detect only genuine new activity
            let snapshot = await persistence.loadOrDefault(
                PollingStateSnapshot.self,
                from: "polling_state.json",
                default: PollingStateSnapshot(trackedPRs: appState.trackedPRs, checkRuns: [:], activityCounts: [:], mergeQueueState: [:])
            )
            await engine.seedState(from: snapshot)

            await engine.setOnEvents { [weak self] events in
                guard let self else { return }
                Task { @MainActor in
                    await self.handlePollEvents(events)
                }
            }
            await engine.setOnCheckRunFailures { [weak self] failures in
                guard let self else { return }
                Task { @MainActor in
                    for failure in failures {
                        self.persistCheckFailure(failure)
                    }
                }
            }
            await engine.start()
            appState.pollingStatus = .polling
        }
    }

    /// Stops the current polling engine.
    func stopPolling() {
        Task {
            await pollingEngine?.stop()
            appState.pollingStatus = .idle
        }
    }

    /// Restarts polling after a token change or settings update.
    /// Call this when the user successfully validates a new PAT.
    func restartPolling(token: String) async {
        stopPolling()

        let client = GitHubAPIClient(token: token)
        self.apiClient = client

        do {
            let user = try await client.validateToken(token)
            appState.authStatus = .authenticated(user)
            startPolling(client: client, currentUser: user)
        } catch {
            appState.authStatus = .invalid
            logger.error("Token re-validation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Polling-to-Notification Pipeline

    /// Processes events from the polling engine through CIEvaluator and NotificationEngine.
    ///
    /// Pipeline:
    /// 1. Update tracked PRs from the current engine state
    /// 2. For each event, determine PR role
    /// 3. For checkCompleted events on authored PRs, evaluate through CIEvaluator
    /// 4. If CIEvaluator says don't notify, skip the event
    /// 5. Otherwise, process through NotificationEngine (which applies FilterEngine + delivery)
    /// 6. Persist updated PR cache and notification history
    ///
    /// Requirements: 3.1, 3.3, 4.1, 6.1, 6.2, 6.3, 6.4, 6.5, 8.1
    private func handlePollEvents(_ events: [PREvent]) async {
        // 1. Update tracked PRs from the polling engine's current state
        if let engine = pollingEngine {
            let currentPRs = await engine.getTrackedPRs()
            appState.trackedPRs = currentPRs
        }

        // 2. Process each event through the filter rules and notification engine
        for event in events {
            let prRole = determinePRRole(for: event)

            // Process through NotificationEngine (applies FilterEngine allowlist + delivery)
            let historyEntry = await notificationEngine.process(
                event: event,
                prRole: prRole,
                rules: appState.filterRules,
                settings: appState.settings
            )

            appState.notificationHistory.append(historyEntry)
        }

        // 6. Persist updated state and sync badge count
        appState.unreadCount = await notificationEngine.getUnreadCount()
        appState.savePRCache()
        appState.saveHistory()

        // 7. Persist polling engine state for next launch
        if let engine = pollingEngine {
            let snapshot = await engine.exportState()
            Task {
                try? await persistence.save(snapshot, to: "polling_state.json")
            }
        }

        // 8. Record raw event data to disk
        await eventStore.recordPollCycle(events: events, trackedPRs: appState.trackedPRs)
        await fileLogger.info(
            "Poll cycle complete: \(events.count) events, \(appState.trackedPRs.count) tracked PRs",
            category: "polling"
        )
    }

    /// Determines the PR role for an event by looking up the tracked PR.
    /// Defaults to `.authored` if the PR isn't found (conservative choice for notifications).
    private func determinePRRole(for event: PREvent) -> PRRole {
        if let trackedPR = appState.trackedPRs.first(where: { $0.id == event.prIdentifier }) {
            return trackedPR.role
        }
        // If we can't find the PR, default to authored (safer: lets CIEvaluator decide)
        return .authored
    }

    /// Evaluates a checkCompleted event through CIEvaluator by reconstructing
    /// the check run information from the event summary.
    ///
    /// The PollingEngine produces checkCompleted events with a summary format of
    /// "checkName: conclusion". This method parses that to construct a CheckRunDTO
    /// suitable for CIEvaluator.
    private func evaluateCIEvent(event: PREvent, prRole: PRRole) -> CINotificationDecision {
        // Parse "checkName: conclusion" from event.summary
        let (checkName, conclusion) = parseCheckRunSummary(event.summary)

        let checkRunDTO = CheckRunDTO(
            id: 0,  // Not needed for evaluation
            name: checkName,
            status: "completed",
            conclusion: conclusion,
            htmlURL: URL(string: "https://github.com")!  // Placeholder, not used in evaluation
        )

        return CIEvaluator.evaluate(checkRun: checkRunDTO, prRole: prRole)
    }

    /// Parses the PollingEngine's check run summary format "name: conclusion"
    /// into separate name and conclusion components.
    private func parseCheckRunSummary(_ summary: String) -> (name: String, conclusion: String?) {
        // The summary format from PollingEngine.diffCheckRuns is "\(checkRun.name): \(conclusion)"
        // Find the last occurrence of ": " to handle check names that contain ": "
        guard let separatorRange = summary.range(of: ": ", options: .backwards) else {
            return (name: summary, conclusion: nil)
        }
        let name = String(summary[summary.startIndex..<separatorRange.lowerBound])
        let conclusion = String(summary[separatorRange.upperBound...])
        return (name: name, conclusion: conclusion.isEmpty ? nil : conclusion)
    }

    // MARK: - Launch at Login (Requirement 11.4)

    /// Registers or unregisters the app for launch at login using SMAppService.
    /// Available on macOS 13+ (our target is macOS 14).
    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence Flush

    /// Flushes any pending persistence writes. Called on app termination (Requirement 10).
    func flushPersistence() {
        appState.saveSettings()
        appState.saveRepoList()
        appState.saveFilterRules()
        appState.saveHistory()
        appState.savePRCache()
    }


    // MARK: - Manual Actions

    /// Triggers an immediate poll cycle and processes the results.
    /// Called from the Dashboard "Refresh" button.
    func pollNow() async {
        guard let engine = pollingEngine else {
            logger.warning("Cannot poll: polling engine not running")
            return
        }

        await fileLogger.info("Manual poll triggered", category: "polling")
        appState.pollingStatus = .polling
        let events = await engine.pollOnce()

        // Update tracked PRs
        let currentPRs = await engine.getTrackedPRs()
        appState.trackedPRs = currentPRs
        appState.savePRCache()

        if !events.isEmpty {
            await handlePollEvents(events)
        }

        appState.pollingStatus = .polling  // back to normal polling state
    }

    /// Marks all unread notifications as read and clears the badge.
    func markAllRead() async {
        for i in appState.notificationHistory.indices {
            if appState.notificationHistory[i].disposition == .delivered {
                appState.notificationHistory[i].isRead = true
            }
        }
        let count = await notificationEngine.getUnreadCount()
        if count > 0 {
            await notificationEngine.markRead(count: count)
        }
        appState.unreadCount = 0
        appState.saveHistory()
    }

    /// Marks a specific notification as read by ID and decrements the badge by 1.
    func markOneRead(id: UUID) async {
        if let idx = appState.notificationHistory.firstIndex(where: { $0.id == id }) {
            appState.notificationHistory[idx].isRead = true
        }
        await notificationEngine.markRead(count: 1)
        appState.unreadCount = await notificationEngine.getUnreadCount()
        appState.saveHistory()
    }

    /// Sends a test notification to verify the notification pipeline is working.
    /// Called from Settings → Notifications → "Test Notification" button.
    @Published var testNotificationStatus: String?

    func sendTestNotification() async {
        testNotificationStatus = "Sending..."
        logger.info("sendTestNotification called")
        logger.info("Bundle.main.bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "nil")")
        logger.info("Bundle.main.bundleURL: \(Bundle.main.bundleURL.path)")

        let center = UNUserNotificationCenter.current()

        // Check current authorization status first
        let settings = await center.notificationSettings()
        logger.info("Authorization status: \(String(describing: settings.authorizationStatus.rawValue))")

        if settings.authorizationStatus == .notDetermined {
            logger.info("Requesting authorization...")
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                logger.info("Authorization granted: \(granted)")
                if !granted {
                    testNotificationStatus = "Permission denied"
                    return
                }
            } catch {
                logger.error("Authorization error: \(error.localizedDescription)")
                testNotificationStatus = "Auth error: \(error.localizedDescription)"
                return
            }
        } else if settings.authorizationStatus == .denied {
            testNotificationStatus = "Notifications denied in System Settings"
            logger.warning("Notifications denied — user must enable in System Settings")
            return
        }

        // Build and deliver
        let content = UNMutableNotificationContent()
        content.title = "ghBonk Test"
        content.subtitle = "Notification system check"
        content.body = "If you see this, notifications are working correctly."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            testNotificationStatus = "Sent! Check your notifications."
            logger.info("Test notification delivered successfully")
        } catch {
            testNotificationStatus = "Failed: \(error.localizedDescription)"
            logger.error("Test notification failed: \(error.localizedDescription)")
        }
    }

    /// Clears all persisted polling state (check runs, comment counts, merge queue state).
    /// Forces the next poll to re-establish a fresh baseline.
    func clearPollingState() async {
        // Clear in-memory state on the engine
        if let engine = pollingEngine {
            let emptySnapshot = PollingStateSnapshot(
                trackedPRs: [], checkRuns: [:], activityCounts: [:], mergeQueueState: [:]
            )
            await engine.seedState(from: emptySnapshot)
        }
        // Clear persisted state
        try? await persistence.save(
            PollingStateSnapshot(trackedPRs: [], checkRuns: [:], activityCounts: [:], mergeQueueState: [:]),
            to: "polling_state.json"
        )
        appState.trackedPRs = []
        appState.notificationHistory = []
        appState.unreadCount = 0
        appState.savePRCache()
        appState.saveHistory()
        await fileLogger.info("Polling state cleared by user", category: "lifecycle")
    }

    // MARK: - Check Failure Persistence (Requirement 12.3)

    /// Persists a check run failure payload to `check_failures/run_<runID>.json`.
    ///
    /// Errors are logged but do not propagate — failure persistence is best-effort
    /// and must not disrupt the polling or notification pipeline.
    private func persistCheckFailure(_ failure: CheckRunFailure) {
        Task {
            do {
                try await persistence.saveRawData(
                    failure.rawPayload,
                    to: "check_failures/run_\(failure.runID).json"
                )
                logger.info("Persisted check failure: \(failure.checkName) (run \(failure.runID))")
            } catch {
                logger.error("Failed to persist check failure \(failure.runID): \(error.localizedDescription)")
            }
        }
    }
}
