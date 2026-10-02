import Foundation

// MARK: - FilterRulesViewModel

/// ViewModel for the Filtering Rules section that exposes the rules list
/// and handles toggling individual rules on or off.
///
/// Requirements:
/// - 5.1: Displays all filtering rules with name, description, and enabled state.
/// - 5.2: Allows toggling each rule independently without affecting others.
@MainActor
final class FilterRulesViewModel: ObservableObject {

    // MARK: - Published State

    @Published var rules: [FilteringRule] = []

    // MARK: - Dependencies

    private let appState: AppState

    // MARK: - Initialization

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Public Methods

    /// Refreshes the rules list from AppState.
    func refresh() {
        rules = appState.filterRules
    }

    /// Toggles the enabled state of a single filtering rule by its ID.
    /// Persists the change and updates AppState.
    func toggleRule(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled.toggle()
        appState.filterRules = rules
        appState.saveFilterRules()
    }
}
