// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CalendarBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CalendarBar", targets: ["CalendarBar"])],
    targets: [
        .target(name: "CalendarCore", exclude: ["AGENTS.md"]),
        .target(name: "MenuBar", exclude: ["AGENTS.md"]),
        .target(name: "CalendarAccess", dependencies: ["CalendarCore"], exclude: ["AGENTS.md"]),
        .target(name: "CalendarNotifications", dependencies: ["CalendarCore", "CalendarAccess"], exclude: ["AGENTS.md"]),
        .target(name: "CalendarUI", dependencies: ["CalendarCore", "CalendarAccess", "CalendarNotifications", "MenuBar"], exclude: ["AGENTS.md"]),
        .executableTarget(name: "CalendarBar", dependencies: ["CalendarUI", "CalendarNotifications", "MenuBar"], exclude: ["AGENTS.md"]),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore"]),
        .testTarget(name: "MenuBarTests", dependencies: ["MenuBar"]),
        .testTarget(name: "CalendarAccessTests", dependencies: ["CalendarAccess", "CalendarCore"]),
        .testTarget(name: "CalendarNotificationsTests", dependencies: ["CalendarNotifications", "CalendarAccess", "CalendarCore"]),
        .testTarget(name: "CalendarUITests", dependencies: ["CalendarUI"])
    ],
    swiftLanguageModes: [.v5]
)
