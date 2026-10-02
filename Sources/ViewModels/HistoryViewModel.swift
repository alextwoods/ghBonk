import Foundation

// MARK: - HistoryViewModel

/// ViewModel for the Notification History view that exposes filtered
/// and sorted notification history entries.
///
/// Requirements:
/// - 8.2: Lists all notification history in reverse chronological order.
/// - 8.4: Allows filtering by disposition (delivered, suppressed, or all).
/// - 8.5: Allows clearing the history.
@MainActor
final class HistoryViewModel: ObservableObject {

    // MARK: - Disposition Filter

    enum DispositionFilter: String, CaseIterable {
        case all
        case delivered
        case suppressed
    }

    // MARK: - Published State

    @Published var dispositionFilter: DispositionFilter = .all
    @Published var filteredHistory: [NotificationHistoryEntry] = []

    // MARK: - Dependencies

    private let appState: AppState

    // MARK: - Initialization

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Public Methods

    /// Refreshes the filtered history list from AppState.
    /// Applies the current disposition filter and sorts by timestamp descending.
    func refresh() {
        let history = appState.notificationHistory

        let filtered: [NotificationHistoryEntry]
        switch dispositionFilter {
        case .all:
            filtered = history
        case .delivered:
            filtered = history.filter { $0.disposition == .delivered }
        case .suppressed:
            filtered = history.filter { $0.disposition == .suppressed }
        }

        filteredHistory = filtered.sorted { $0.timestamp > $1.timestamp }
    }

    /// Clears all notification history entries and persists the change.
    func clearHistory() {
        appState.notificationHistory = []
        filteredHistory = []
        appState.saveHistory()
    }
}
