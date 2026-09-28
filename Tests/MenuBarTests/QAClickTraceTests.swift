import Foundation
import XCTest
@testable import MenuBar

final class QAClickTraceTests: XCTestCase {
    func testOnlyQAEmitsClosedMetadataAndPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        QAClickTrace.record(.launch, bundleID: "test.production", directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        QAClickTrace.record(.launch, bundleID: "test.qa", directory: directory)
        QAClickTrace.record(.responseWithToken, bundleID: "test.qa", directory: directory)
        let file = directory.appendingPathComponent("qa-click-trace.jsonl")
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap { $0["stage"] as? String }, ["launch", "responseWithToken"])
        for row in rows {
            XCTAssertEqual(Set(row.keys), ["stage", "pid", "monotonic"])
            XCTAssertEqual(row["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
            XCTAssertGreaterThan(row["monotonic"] as? Double ?? 0, 0)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTraceDoesNotFollowExistingSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("qa-click-trace.jsonl"), withDestinationURL: target)
        QAClickTrace.record(.launch, bundleID: "test.qa", directory: directory)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }
}
