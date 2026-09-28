import Foundation

/// A QA bundle stays isolated when macOS launches it without command-line arguments.
public struct CalendarLaunchOptions {
    public enum NotificationReportMode: Equatable { case none, denied, readOnly }
    /// Evaluated before constructing launch options, which can persist QA settings.
    public static func notificationReportMode(arguments: [String], bundleID: String?) -> NotificationReportMode {
        guard arguments.contains("--qa-notification-report") else { return .none }
        return bundleID?.hasSuffix(".qa") == true ? .readOnly : .denied
    }

    public let qa: Bool
    public let smoke: Bool
    public let qaNotifications: Bool
    public let qaWindow: Bool
    public let qaSeed: Date?
    public let show: Bool
    public init(arguments: [String], bundleID: String?, qaConfigurationURL: URL? = nil) {
        let isolatedBundle = bundleID?.hasSuffix(".qa") ?? false
        qa = isolatedBundle || arguments.contains("--qa")
        smoke = arguments.contains("--smoke")
        show = arguments.contains("--show")
        qaWindow = qa && arguments.contains("--qa-window")
        let explicitSeed: Date? = {
            guard let index = arguments.firstIndex(of: "--qa-seed"), arguments.indices.contains(index + 1), let value = Double(arguments[index + 1]), value.isFinite, abs(value) < 100_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: value)
        }()
        guard isolatedBundle, let bundleID else {
            qaNotifications = false
            qaSeed = qa ? explicitSeed : nil
            return
        }
        let url = qaConfigurationURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID + "/qa-launch.json")
        let old = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(QAConfiguration.self, from: $0) }
        let configuration = QAConfiguration(seed: explicitSeed ?? old?.seed ?? Date(), notifications: !smoke && (arguments.contains("--qa-notifications") || old?.notifications == true))
        // Never turn on OS notifications unless isolated configuration is durably saved.
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
            qaNotifications = configuration.notifications
        } catch { qaNotifications = false }
        qaSeed = configuration.seed
    }
}
private struct QAConfiguration: Codable { let seed: Date; let notifications: Bool }
