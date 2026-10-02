import SwiftUI
import UserNotifications
import AppKit

@main
struct GhBonkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = AppController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller.appState)
                .environmentObject(controller)
                .onAppear {
                    appDelegate.appController = controller
                }
                .task {
                    await controller.initialize()
                }
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Reference to the AppController for notification interaction handling.
    /// Set from `GhBonkApp` body once the controller is available.
    weak var appController: AppController?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app presents as a regular GUI application with a Dock icon
        // and window, even when launched as a bare executable outside a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Register as the notification center delegate to handle user interactions
        // with delivered notifications (Requirement 4.5, 9.5).
        // Guard: UNUserNotificationCenter.current() crashes outside a .app bundle
        // because bundleProxyForCurrentProcess is nil.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        // Observe system wake from sleep to restart polling immediately.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // After wake, the polling task may have missed cycles.
        // Trigger an immediate poll to refresh state.
        Task { @MainActor in
            await appController?.pollNow()
        }
    }

    /// Re-opens the main window when the user clicks the Dock icon
    /// while the app is running without a visible window (Requirement 11.3).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(self)
        }
        return true
    }

    /// Keeps the app running (and polling) when the user closes the main window (Requirement 11.2).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Flushes any pending persistence writes on termination (Requirement 10).
    func applicationWillTerminate(_ notification: Notification) {
        appController?.flushPersistence()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when the user taps/clicks a delivered notification (Requirement 4.5, 9.5).
    ///
    /// - Opens the PR URL in the default browser.
    /// - Decrements the badge count by 1.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        // Open PR URL in browser (Requirement 9.5)
        if let urlString = userInfo["prURL"] as? String,
           let url = URL(string: urlString) {
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
        }

        // Decrement badge count (Requirement 4.5)
        let engine = await MainActor.run { appController?.notificationEngine }
        if let engine {
            await engine.markRead(count: 1)
        }
    }

    /// Called when a notification is delivered while the app is in the foreground.
    ///
    /// Shows the notification as a banner even when the app is active, so the user
    /// doesn't miss events while working in ghBonk.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .badge, .sound]
    }
}
