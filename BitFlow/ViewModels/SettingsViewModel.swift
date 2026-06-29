import SwiftUI
import Combine

enum Theme: String, CaseIterable, Codable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @AppStorage("maxConnections") var maxConnections: Int = 200
    @AppStorage("maxDownloadSpeed") var maxDownloadSpeed: Int = 0
    @AppStorage("maxUploadSpeed") var maxUploadSpeed: Int = 0
    @AppStorage("listenPort") var listenPort: Int = 6881
    @AppStorage("enableDHT") var enableDHT: Bool = true
    @AppStorage("enablePEX") var enablePEX: Bool = true
    @AppStorage("enableLSD") var enableLSD: Bool = true
    @AppStorage("allowCellular") var allowCellular: Bool = false
    @AppStorage("sequentialDownload") var sequentialDownload: Bool = false
    @AppStorage("startDownloadsImmediately") var startDownloadsImmediately: Bool = true
    @AppStorage("seedAfterComplete") var seedAfterComplete: Bool = true
    @AppStorage("seedRatio") var seedRatio: Double = 2.0
    @AppStorage("theme") var themeRaw: String = Theme.system.rawValue

    var theme: Theme {
        get { Theme(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    var colorScheme: ColorScheme? { theme.colorScheme }

    func applyToEngine() {
        var config = TorrentEngine.shared.configuration
        config.maxConnections = maxConnections
        config.maxDownloadSpeed = maxDownloadSpeed
        config.maxUploadSpeed = maxUploadSpeed
        config.listenPort = UInt16(listenPort)
        config.enableDHT = enableDHT
        config.enablePEX = enablePEX
        config.enableLSD = enableLSD
        config.sequentialDownload = sequentialDownload
        TorrentEngine.shared.configuration = config
    }
}
