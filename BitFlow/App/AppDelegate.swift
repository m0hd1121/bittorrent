import UIKit
import BackgroundTasks
import os.log

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.bitflow.app", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        configureAppearance()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        logger.info("App entered background")
        BackgroundTaskManager.shared.scheduleBackgroundProcessing()
        BackgroundTaskManager.shared.scheduleAppRefresh()
        TorrentEngine.shared.handleAppBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        logger.info("App entering foreground")
        TorrentEngine.shared.handleAppForeground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        logger.info("App will terminate — persisting state")
        TorrentEngine.shared.persistState()
    }

    // MARK: - Background Tasks Registration

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskManager.processingTaskID,
            using: nil
        ) { task in
            BackgroundTaskManager.shared.handleProcessingTask(task as! BGProcessingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskManager.refreshTaskID,
            using: nil
        ) { task in
            BackgroundTaskManager.shared.handleRefreshTask(task as! BGAppRefreshTask)
        }
    }

    private func configureAppearance() {
        // Liquid Glass / translucent navigation bars
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
}
