import Foundation

/// Keeps a user request alive briefly while AppKit attaches the status item.
/// Accessory apps can remain inactive without a window: show first, then request activation.
/// Cancellation and a fixed attempt limit prevent a hidden app from reopening much later.
@MainActor final class PopoverPresentation {
    private var task: Task<Void, Never>?
    private let maximumAttempts: Int
    private let wait: () async throws -> Void

    init(maximumAttempts: Int = 40, wait: @escaping () async throws -> Void = {
        try await Task.sleep(nanoseconds: 50_000_000)
    }) {
        self.maximumAttempts = maximumAttempts
        self.wait = wait
    }
    deinit { task?.cancel() }

    func request(activate: @escaping () -> Void, attempt: @escaping () -> Bool) {
        cancel()
        if attempt() { activate(); return }
        guard maximumAttempts > 1 else { return }
        let wait = wait
        let maximumAttempts = maximumAttempts
        task = Task {
            for _ in 1..<maximumAttempts {
                do { try await wait() } catch { return }
                guard !Task.isCancelled else { return }
                if attempt() { activate(); return }
            }
        }
    }
    func cancel() { task?.cancel(); task = nil }
    func waitUntilIdle() async { await task?.value }
}
