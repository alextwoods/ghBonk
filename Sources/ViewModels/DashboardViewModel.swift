import Foundation
import AppKit

// MARK: - DashboardViewModel

/// ViewModel for the Dashboard view that groups tracked PRs by role
/// and provides sorted lists for the UI.
///
/// Requirements:
/// - 9.1: Displays all tracked PRs grouped by role.
/// - 9.5: Clicking a PR opens it in the default browser.
@MainActor
final class DashboardViewModel: ObservableObject {

    // MARK: - Published State

    @Published var authoredPRs: [TrackedPR] = []
    @Published var reviewingPRs: [TrackedPR] = []

    // MARK: - Dependencies

    private let appState: AppState

    // MARK: - Initialization

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Public Methods

    /// Refreshes the grouped PR lists from AppState.
    /// Called by the view in `onAppear` or `.task`.
    func refresh() {
        let tracked = appState.trackedPRs

        authoredPRs = tracked
            .filter { $0.role == .authored }
            .sorted { $0.updatedAt > $1.updatedAt }

        reviewingPRs = tracked
            .filter { $0.role == .reviewing }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Opens the given PR's GitHub URL in the default browser.
    func openPR(_ pr: TrackedPR) {
        let urlString = "https://github.com/\(pr.repository.fullName)/pull/\(pr.number)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
