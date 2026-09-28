import AppKit
import Foundation

// Read-only application identity inventory. Never query notification/event data.
let id = CommandLine.arguments[1]
let object: [String: Any] = [
    "candidates": NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path),
    "running": NSRunningApplication.runningApplications(withBundleIdentifier: id).map { ["pid": Int($0.processIdentifier), "path": $0.bundleURL?.path ?? ""] }
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
