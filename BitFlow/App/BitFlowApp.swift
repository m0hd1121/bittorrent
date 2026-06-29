import SwiftUI
import BackgroundTasks

@main
struct BitFlowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appCoordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .environmentObject(appCoordinator.torrentViewModel)
                .environmentObject(appCoordinator.settingsViewModel)
                .preferredColorScheme(appCoordinator.settingsViewModel.colorScheme)
        }
    }
}
