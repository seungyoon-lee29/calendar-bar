import Foundation

/// Queues opaque notification links until the app graph is ready, including cold launch.
@MainActor public final class ReminderClickRouter {
    private var pending: [String] = []
    private var handler: ((String) async -> Void)?
    private var task: Task<Void, Never>?
    public init() {}
    deinit { task?.cancel() }
    public func receive(_ token: String) {
        guard !token.isEmpty else { return }
        pending.append(token)
        drain()
    }
    public func install(_ handler: @escaping (String) async -> Void) { self.handler = handler; drain() }
    public func waitUntilIdle() async { await task?.value }
    private func drain() {
        guard task == nil, handler != nil else { return }
        task = Task { [weak self] in
            while let self, !pending.isEmpty, !Task.isCancelled, let handler {
                let token = pending.removeFirst()
                await handler(token)
            }
            self?.task = nil
        }
    }
}
