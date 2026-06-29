import Foundation
import Combine
import os.log

// MARK: - Log Entry

struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    enum LogLevel: String, Sendable {
        case debug, info, warning, error, critical

        var emoji: String {
            switch self {
            case .debug: return "🔵"
            case .info: return "⚪"
            case .warning: return "🟡"
            case .error: return "🔴"
            case .critical: return "💥"
            }
        }
    }
}

// MARK: - Log Manager

@MainActor
final class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000

    private init() {}

    func log(_ level: LogEntry.LogLevel, category: String, message: String) {
        let entry = LogEntry(id: UUID(), timestamp: .now, level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func debugLog(_ message: String, category: String = "App") { log(.debug, category: category, message: message) }
    func infoLog(_ message: String, category: String = "App") { log(.info, category: category, message: message) }
    func warnLog(_ message: String, category: String = "App") { log(.warning, category: category, message: message) }
    func errorLog(_ message: String, category: String = "App") { log(.error, category: category, message: message) }
}
