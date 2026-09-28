import AppKit
import SwiftUI
import CalendarAccess
import MenuBar

@MainActor public final class CalendarAppCoordinator {
    private let model: CalendarModel
    private let login: LoginItemController
    private let menu: MenuBarController
    public init(smoke: Bool = false) {
        let model = CalendarModel(access: CalendarAccessController())
        let login = LoginItemController()
        self.model = model
        self.login = login
        login.initializeForLaunch(automaticallyRegister: !smoke)
        menu = MenuBarController(
            contentViewController: NSHostingController(rootView: CalendarPopover(model: model, login: login)),
            contentSize: NSSize(width: 340, height: 520),
            onOpen: { model.open(); login.refresh() },
            onDateChange: { model.dateChanged($0) }
        )
    }
    public func show() { menu.togglePopover() }
    public func becameActive() { login.refresh(); model.refresh() }
}
