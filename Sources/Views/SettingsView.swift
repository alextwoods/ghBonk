import SwiftUI

// MARK: - SettingsView

/// Settings view organized as a scrollable Form with sections for authentication,
/// repositories, polling, notifications, filtering rules, debug mode, and launch at login.
///
/// Uses @EnvironmentObject for AppState (consistent with DashboardView pattern).
/// PAT validation uses local @State for input management; real API/Keychain integration
/// will be wired in task 9.1.
///
/// Requirements:
/// - 1.1: PAT entry, update, and deletion via UI.
/// - 2.1, 2.3, 2.4, 2.5: Repository list CRUD with empty state and default repo.
/// - 3.2: Polling interval configuration (minimum 30s).
/// - 4.2, 4.3: Independent notification and badge toggles.
/// - 5.1, 5.2: Filtering rule display and toggle.
/// - 7.1: Debug mode toggle.
/// - 11.4: Launch at Login toggle.
struct SettingsView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AppController

    // MARK: - PAT State

    @State private var patInput: String = ""
    @State private var isValidating: Bool = false
    @State private var validationMessage: String?
    @State private var newRepoInput: String = ""

    var body: some View {
        Form {
            authenticationSection
            repositoriesSection
            pollingSection
            notificationsSection
            filteringRulesSection
            debugModeSection
            dataManagementSection
            launchAtLoginSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    // MARK: - Authentication Section

    @ViewBuilder
    private var authenticationSection: some View {
        Section {
            SecureField("GitHub Personal Access Token", text: $patInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Validate") {
                    Task {
                        await validateAndSavePAT()
                    }
                }
                .disabled(patInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)

                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if isAuthenticated {
                    Button("Delete Token", role: .destructive) {
                        deletePAT()
                    }
                }
            }

            // Status indicator
            if let message = validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isAuthenticated ? .green : .red)
            }

            // Current auth status display
            authStatusView
        } header: {
            Text("Authentication")
        } footer: {
            Text("Enter a GitHub PAT with repo scope to authenticate.")
        }
    }

    private var isAuthenticated: Bool {
        if case .authenticated = appState.authStatus {
            return true
        }
        return false
    }

    @ViewBuilder
    private var authStatusView: some View {
        HStack {
            if isAuthenticated {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Authenticated")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Not authenticated")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    // MARK: - Repositories Section

    @ViewBuilder
    private var repositoriesSection: some View {
        Section {
            if appState.repoList.isEmpty {
                Text("No repositories configured. Add one to get started.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(appState.repoList) { repo in
                    HStack {
                        Text(repo.fullName)
                        Spacer()
                    }
                }
                .onDelete(perform: removeRepo)
                .onMove(perform: moveRepo)
            }

            HStack {
                TextField("owner/name", text: $newRepoInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addRepo()
                    }

                Button("Add") {
                    addRepo()
                }
                .disabled(newRepoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let message = validationMessage,
               message.contains("format") || message.contains("already") {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Repositories")
        } footer: {
            Text("Add repositories in \"owner/name\" format (e.g., aws/aws-sdk-java-v2). Drag to reorder.")
        }
    }

    // MARK: - Polling Section

    @ViewBuilder
    private var pollingSection: some View {
        Section {
            Stepper(
                "Polling interval: \(Int(appState.settings.pollingInterval))s",
                value: $appState.settings.pollingInterval,
                in: 30...600,
                step: 30
            )
            .onChange(of: appState.settings.pollingInterval) { _, newValue in
                let clamped = max(newValue, 30)
                appState.settings.pollingInterval = clamped
                appState.saveSettings()
            }
        } header: {
            Text("Polling")
        } footer: {
            Text("Minimum 30 seconds. Controls how often ghBonk checks GitHub for updates.")
        }
    }

    // MARK: - Notifications Section

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            Toggle("Desktop Notifications", isOn: $appState.settings.notificationsEnabled)
                .onChange(of: appState.settings.notificationsEnabled) { _, _ in
                    appState.saveSettings()
                }

            Toggle("Badge Count", isOn: $appState.settings.badgeEnabled)
                .onChange(of: appState.settings.badgeEnabled) { _, _ in
                    appState.saveSettings()
                }

            HStack {
                Button("Send Test Notification") {
                    Task {
                        await controller.sendTestNotification()
                    }
                }

                if let status = controller.testNotificationStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Desktop notifications and badge count can be enabled independently. Use the test button to verify notifications are working.")
        }
    }

    // MARK: - Filtering Rules Section

    @ViewBuilder
    private var filteringRulesSection: some View {
        Section {
            if appState.filterRules.isEmpty {
                Text("No filtering rules configured.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(appState.filterRules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                                .font(.body)
                            Text(rule.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: ruleBinding(for: rule.id))
                            .labelsHidden()
                    }
                }
            }
        } header: {
            Text("Filtering Rules")
        } footer: {
            Text("Enable or disable individual rules to control which events generate notifications.")
        }
    }

    // MARK: - Debug Mode Section

    @ViewBuilder
    private var debugModeSection: some View {
        Section {
            Toggle("Debug Mode", isOn: $appState.settings.debugMode)
                .onChange(of: appState.settings.debugMode) { _, _ in
                    appState.saveSettings()
                }
        } header: {
            Text("Debug Mode")
        } footer: {
            Text("When enabled, notifications and history entries are annotated with the filtering rule that allowed or blocked them. Useful for verifying and tuning your filtering rules.")
        }
    }

    // MARK: - Data Management Section

    @State private var showClearStateConfirmation = false

    @ViewBuilder
    private var dataManagementSection: some View {
        Section {
            Button("Clear Polling State", role: .destructive) {
                showClearStateConfirmation = true
            }
            .alert("Clear Polling State?", isPresented: $showClearStateConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    Task { await controller.clearPollingState() }
                }
            } message: {
                Text("This will clear all cached PR data, notification history, and polling baselines. The next poll will re-establish a fresh baseline.")
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Clears cached state if notifications seem stale or incorrect. The app will re-sync on the next poll cycle.")
        }
    }

    // MARK: - Launch at Login Section

    @ViewBuilder
    private var launchAtLoginSection: some View {
        Section {
            Toggle("Launch at Login", isOn: $appState.settings.launchAtLogin)
                .onChange(of: appState.settings.launchAtLogin) { _, newValue in
                    controller.setLaunchAtLogin(enabled: newValue)
                    appState.saveSettings()
                }
        } header: {
            Text("Launch at Login")
        } footer: {
            Text("Automatically start ghBonk when you log in to your Mac.")
        }
    }

    // MARK: - Private Helpers

    /// Creates a binding for a filtering rule's enabled state by its ID.
    private func ruleBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                appState.filterRules.first(where: { $0.id == id })?.isEnabled ?? false
            },
            set: { _ in
                guard let index = appState.filterRules.firstIndex(where: { $0.id == id }) else { return }
                appState.filterRules[index].isEnabled.toggle()
                appState.saveFilterRules()
            }
        )
    }

    /// Validates and stores the PAT (Requirement 1.1, 1.3).
    private func validateAndSavePAT() async {
        let trimmed = patInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Please enter a token."
            return
        }

        isValidating = true
        validationMessage = nil

        do {
            // Create a temporary client to validate the token
            let tempClient = GitHubAPIClient(token: trimmed)
            let user = try await tempClient.validateToken(trimmed)

            // Token is valid — store in Keychain
            try controller.keychainService.store(token: trimmed)
            appState.authStatus = .authenticated(user)
            validationMessage = "Authenticated as \(user.login)."
            patInput = ""

            // Restart polling with the new token
            await controller.restartPolling(token: trimmed)
        } catch let error as GhBonkError {
            switch error {
            case .tokenInvalid, .tokenExpired:
                appState.authStatus = .invalid
                validationMessage = "Token is invalid or expired."
            default:
                validationMessage = "Validation failed: \(error.localizedDescription)"
            }
        } catch {
            validationMessage = "Validation failed: \(error.localizedDescription)"
        }

        isValidating = false
    }

    /// Deletes the stored PAT from the Keychain (Requirement 1.1).
    private func deletePAT() {
        do {
            try controller.keychainService.delete()
            appState.authStatus = .unknown
            controller.stopPolling()
            validationMessage = "Token removed."
        } catch {
            validationMessage = "Failed to delete token: \(error.localizedDescription)"
        }
    }

    /// Adds a repository to the list (Requirement 2.1).
    private func addRepo() {
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
        guard !appState.repoList.contains(where: { $0.owner == owner && $0.name == name }) else {
            validationMessage = "Repository \(trimmed) is already in the list."
            return
        }

        let repo = Repository(
            id: UUID(),
            owner: owner,
            name: name,
            sortOrder: appState.repoList.count
        )

        appState.repoList.append(repo)
        appState.saveRepoList()
        newRepoInput = ""
        validationMessage = nil
    }

    /// Removes repositories at the given offsets (Requirement 2.1).
    private func removeRepo(at offsets: IndexSet) {
        appState.repoList.remove(atOffsets: offsets)
        reindexRepos()
        appState.saveRepoList()
    }

    /// Moves repositories within the list for reordering (Requirement 2.1).
    private func moveRepo(from source: IndexSet, to destination: Int) {
        appState.repoList.move(fromOffsets: source, toOffset: destination)
        reindexRepos()
        appState.saveRepoList()
    }

    /// Recalculates `sortOrder` for all repos after a reorder or deletion.
    private func reindexRepos() {
        for index in appState.repoList.indices {
            appState.repoList[index].sortOrder = index
        }
    }
}
