import BackgroundTasks
import os.log

/*
 BACKGROUND EXECUTION — iOS LIMITATIONS DOCUMENTATION
 =====================================================

 iOS imposes strict limits on background network access for BitTorrent clients:

 1. BGProcessingTask (BGTaskScheduler)
    - Runs when device is idle, plugged in (often)
    - iOS decides WHEN it runs — not guaranteed
    - Time limit: up to ~1-30 minutes (system discretion)
    - Requires "processing" background mode in Info.plist
    - ✅ Best option for large transfers when idle

 2. BGAppRefreshTask
    - Short duration (~30 seconds)
    - Used for updating UI / re-triggering processing tasks
    - ✅ Good for "did anything change" checks

 3. URLSession Background Downloads (NSURLSession with background configuration)
    - DOES NOT WORK for BitTorrent: BT uses raw TCP/UDP sockets,
      not HTTP/HTTPS URLs. The background URLSession only works for
      HTTP(S) file downloads managed by iOS's daemon.
    - ❌ NOT applicable for native BitTorrent

 4. VoIP push / PushKit
    - Grants ~30s of background time on each push
    - Requires a server to send pushes — violates "no server" requirement
    - ❌ Not applicable

 5. Network Extension / Packet Tunnel
    - Requires special entitlement from Apple
    - Must be used for VPN-like scenarios
    - ❌ Not the right tool, not easily grantable

 VERDICT:
 --------
 Continuous BitTorrent downloading in the background on iOS is NOT possible
 without jailbreak or special Apple entitlements. iOS will suspend network
 sockets when the app is backgrounded, typically within seconds.

 The closest achievable behavior:
 - BGProcessingTask: Download opportunistically when iOS grants time
 - Schedule refresh tasks to re-start downloads
 - Persist all download state so download resumes instantly on foreground
 - Display a "downloading" notification to keep user engaged (foreground)

 This implementation does the best possible within official APIs.
*/

final class BackgroundTaskManager: @unchecked Sendable {
    static let shared = BackgroundTaskManager()

    static let processingTaskID = "com.bitflow.processing"
    static let refreshTaskID = "com.bitflow.refresh"

    private let logger = Logger(subsystem: "com.bitflow.app", category: "BackgroundTask")

    private init() {}

    // MARK: - Schedule

    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled BGProcessingTask")
        } catch {
            logger.warning("Failed to schedule processing task: \(error)")
        }
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled BGAppRefreshTask")
        } catch {
            logger.warning("Failed to schedule refresh task: \(error)")
        }
    }

    // MARK: - Handle Tasks

    func handleProcessingTask(_ task: BGProcessingTask) {
        logger.info("BGProcessingTask started — resuming downloads")

        // Re-schedule for next time
        scheduleBackgroundProcessing()

        let downloadTask = Task.detached(priority: .utility) {
            // Resume active downloads
            await TorrentEngine.shared.resumeAll()

            // Keep running until task expires
            // iOS will call expiration handler when time is up
            try? await Task.sleep(for: .seconds(25 * 60))  // up to 25 min safety
        }

        task.expirationHandler = {
            self.logger.info("BGProcessingTask expiring — persisting state")
            downloadTask.cancel()
            Task {
                await TorrentEngine.shared.pauseAll()
                TorrentEngine.shared.persistState()
                task.setTaskCompleted(success: true)
            }
        }
    }

    func handleRefreshTask(_ task: BGAppRefreshTask) {
        logger.info("BGAppRefreshTask started")

        // Re-schedule
        scheduleAppRefresh()

        Task {
            TorrentEngine.shared.persistState()
            task.setTaskCompleted(success: true)
        }
    }
}
