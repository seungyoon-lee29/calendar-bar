import XCTest
@testable import MenuBar

@MainActor
final class LoginItemControllerTests: XCTestCase {
    final class Backend: LoginItemBackend {
        var state: LoginItemState = .disabled
        var registrations = 0
        var unregistrations = 0
        var error: Error?
        var queryError: Error?
        func currentState() throws -> LoginItemState {
            if let queryError { throw queryError }
            return state
        }
        func register() throws {
            registrations += 1
            if let error { throw error }
            state = .enabled
        }
        func unregister() throws {
            unregistrations += 1
            if let error { throw error }
            state = .disabled
        }
    }
    final class Store: LoginItemInitializationStore {
        var hasInitializedLoginItem = false
    }
    enum Failure: Error { case denied }

    func testFirstRealLaunchRegistersExactlyOnceAndRespectsLaterDisable() async {
        let backend = Backend(), store = Store()
        let first = LoginItemController(backend: backend, store: store)
        first.initializeForLaunch()
        XCTAssertEqual(first.state, .enabled)
        XCTAssertTrue(store.hasInitializedLoginItem)
        backend.state = .disabled
        let later = LoginItemController(backend: backend, store: store)
        later.initializeForLaunch()
        XCTAssertEqual(later.state, .disabled)
        XCTAssertEqual(backend.registrations, 1)
    }

    func testFirstLaunchRegistersWhenSystemReportsNotFound() async {
        let backend = Backend(), store = Store()
        backend.state = .failure("로그인 항목을 찾을 수 없습니다.")
        let controller = LoginItemController(backend: backend, store: store)
        controller.initializeForLaunch()
        XCTAssertEqual(backend.registrations, 1)
        XCTAssertEqual(controller.state, .enabled)
        XCTAssertTrue(store.hasInitializedLoginItem)

        backend.state = .disabled
        LoginItemController(backend: backend, store: store).initializeForLaunch()
        XCTAssertEqual(backend.registrations, 1)
    }

    func testStatusQueryThrowPreservesFailureWithoutRegistering() async {
        let backend = Backend(), store = Store()
        backend.queryError = Failure.denied
        let controller = LoginItemController(backend: backend, store: store)
        controller.initializeForLaunch()
        XCTAssertEqual(backend.registrations, 0)
        XCTAssertEqual(controller.state, .failure(Failure.denied.localizedDescription))
    }

    func testPreviewDoesNotConsumeFirstRealLaunch() async {
        let backend = Backend(), store = Store()
        let controller = LoginItemController(backend: backend, store: store)
        controller.initializeForLaunch(automaticallyRegister: false)
        XCTAssertFalse(store.hasInitializedLoginItem)
        XCTAssertEqual(backend.registrations, 0)
        controller.initializeForLaunch()
        XCTAssertEqual(backend.registrations, 1)
    }

    func testApprovalAndFailureAreDistinctAndFailureDoesNotRetryNextLaunch() async {
        let backend = Backend(), store = Store()
        backend.state = .requiresApproval
        let controller = LoginItemController(backend: backend, store: store)
        controller.initializeForLaunch()
        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertEqual(backend.registrations, 0)
        backend.state = .disabled
        backend.error = Failure.denied
        controller.setEnabled(true)
        guard case .failure = controller.state else { return XCTFail("Expected failure") }
        controller.initializeForLaunch()
        XCTAssertEqual(backend.registrations, 1)
    }

    func testFailedFirstRegistrationIsNotRepeatedOnLaterLaunch() async {
        let backend = Backend(), store = Store()
        backend.error = Failure.denied
        LoginItemController(backend: backend, store: store).initializeForLaunch()
        XCTAssertTrue(store.hasInitializedLoginItem)
        LoginItemController(backend: backend, store: store).initializeForLaunch()
        XCTAssertEqual(backend.registrations, 1)
    }

    func testExplicitDisableBeforeInitializationPreventsAutomaticEnable() async {
        let backend = Backend(), store = Store()
        let controller = LoginItemController(backend: backend, store: store)
        controller.setEnabled(false)
        controller.initializeForLaunch()
        XCTAssertEqual(backend.registrations, 0)
        XCTAssertEqual(controller.state, .disabled)
    }

    func testToggleAndRefreshUseSystemState() async {
        let backend = Backend(), store = Store()
        let controller = LoginItemController(backend: backend, store: store)
        controller.setEnabled(true)
        XCTAssertEqual(controller.state, .enabled)
        controller.setEnabled(false)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertEqual(backend.unregistrations, 1)
        backend.state = .requiresApproval
        controller.refresh()
        XCTAssertEqual(controller.state, .requiresApproval)
    }
}
