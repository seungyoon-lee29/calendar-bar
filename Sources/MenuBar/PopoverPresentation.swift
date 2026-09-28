import Foundation

/// Keeps a user request alive briefly while AppKit activates and attaches the status item.
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

    func request(activate: () -> Void, attempt: @escaping () -> Bool) {
        cancel()
        activate()
        guard !attempt(), maximumAttempts > 1 else { return }
        let wait = wait
        let maximumAttempts = maximumAttempts
        task = Task {
            for _ in 1..<maximumAttempts {
                do { try await wait() } catch { return }
                guard !Task.isCancelled else { return }
                if attempt() { return }
            }
        }
    }
    func cancel() { task?.cancel(); task = nil }
    func waitUntilIdle() async { await task?.value }
}
