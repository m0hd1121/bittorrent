import SwiftUI
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let torrentViewModel: TorrentListViewModel
    let settingsViewModel: SettingsViewModel

    init() {
        let engine = TorrentEngine.shared
        self.settingsViewModel = SettingsViewModel()
        self.torrentViewModel = TorrentListViewModel(engine: engine)
    }
}
