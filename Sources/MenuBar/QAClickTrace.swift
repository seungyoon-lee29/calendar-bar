import Foundation
import Darwin

/// Temporary, synthetic-QA-only lifecycle probe. Remove after notification click replay.
/// The closed enum deliberately cannot carry tokens, event content, identities or dates.
public enum QAClickTrace {
    public enum Stage: String {
        case launch, becameActive, responseWithToken, responseWithoutToken
        case reopenNotification, reopenOrdinary, routeBegin, routeHighlighted, routeMessage, routeNoDestination
        case showRequested, waitingActivation, waitingAnchor, showSucceeded, showFailed
        case popoverDidShow, popoverWillClose, closeRequested, deactivated
    }
    private static let lock = NSLock()
    public static func record(_ stage: Stage) {
        record(stage, bundleID: Bundle.main.bundleIdentifier)
    }
    // Internal directory injection keeps tests entirely outside app storage.
    static func record(_ stage: Stage, bundleID: String?, directory: URL? = nil) {
        guard let bundleID, bundleID.hasSuffix(".qa") else { return }
        NSLog("[DEBUG-click] %@", stage.rawValue)
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID)
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("qa-click-trace.jsonl")
            let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  fchmod(descriptor, mode_t(0o600)) == 0 else { return }
            let row: [String: Any] = ["stage": stage.rawValue, "pid": Int(ProcessInfo.processInfo.processIdentifier), "monotonic": ProcessInfo.processInfo.systemUptime]
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                _ = write(descriptor, base, bytes.count)
            }
        } catch { /* Diagnostics never change application behavior. */ }
    }
}
