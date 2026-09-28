import Combine
import Foundation
import ServiceManagement

public enum LoginItemState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case failure(String)
}

@MainActor
public protocol LoginItemBackend {
    func currentState() throws -> LoginItemState
    func register() throws
    func unregister() throws
}

@MainActor
public protocol LoginItemInitializationStore: AnyObject {
    var hasInitializedLoginItem: Bool { get set }
}

@MainActor
public final class UserDefaultsLoginItemStore: LoginItemInitializationStore {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "loginItem.initialized") {
        self.defaults = defaults
        self.key = key
    }
    public var hasInitializedLoginItem: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

@MainActor
public final class SystemLoginItemBackend: LoginItemBackend {
    public init() {}
    public func currentState() throws -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .failure("로그인 항목을 찾을 수 없습니다. 앱 설치 위치를 확인하세요.")
        @unknown default: return .failure("로그인 항목 상태를 확인할 수 없습니다.")
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Create once for the app lifetime; call refresh when returning from System Settings.
@MainActor
public final class LoginItemController: ObservableObject {
    @Published public private(set) var state: LoginItemState = .disabled
    private let backend: LoginItemBackend
    private let store: LoginItemInitializationStore

    public init(backend: LoginItemBackend, store: LoginItemInitializationStore) {
        self.backend = backend
        self.store = store
        refresh()
    }

    public convenience init() {
        self.init(backend: SystemLoginItemBackend(), store: UserDefaultsLoginItemStore())
    }

    /// Preview/smoke launches must pass false so the first real launch remains eligible.
    public func initializeForLaunch(automaticallyRegister: Bool = true) {
        refresh()
        guard automaticallyRegister, !store.hasInitializedLoginItem else { return }
        // Mark the attempt before registration, including failure/approval, to respect later opt-out.
        store.hasInitializedLoginItem = true
        if state == .disabled { setEnabled(true) }
    }

    public func refresh() {
        do { state = try backend.currentState() }
        catch { state = .failure(error.localizedDescription) }
    }

    public func setEnabled(_ enabled: Bool) {
        // An explicit choice also ends first-launch eligibility.
        store.hasInitializedLoginItem = true
        do {
            let actual = try backend.currentState()
            if enabled {
                if actual != .enabled && actual != .requiresApproval { try backend.register() }
            } else if actual != .disabled {
                try backend.unregister()
            }
            state = try backend.currentState()
        } catch {
            state = .failure(error.localizedDescription)
        }
    }
}
