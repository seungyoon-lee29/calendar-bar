// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CalendarBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CalendarBar", targets: ["CalendarBar"])],
    targets: [
        .target(name: "CalendarCore"),
        .target(name: "MenuBar"),
        .target(name: "CalendarAccess", dependencies: ["CalendarCore"]),
        .target(name: "CalendarUI", dependencies: ["CalendarCore", "CalendarAccess", "MenuBar"]),
        .executableTarget(name: "CalendarBar", dependencies: ["CalendarUI", "MenuBar"]),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore"]),
        .testTarget(name: "MenuBarTests", dependencies: ["MenuBar"]),
        .testTarget(name: "CalendarAccessTests", dependencies: ["CalendarAccess", "CalendarCore"]),
        .testTarget(name: "CalendarUITests", dependencies: ["CalendarUI"])
    ],
    swiftLanguageModes: [.v5]
)
