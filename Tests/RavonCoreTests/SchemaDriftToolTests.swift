import XCTest

/// Guards the schema-drift tool itself.
///
/// A CI gate nobody trusts is worse than no gate, so the tool has to be verified in both
/// directions: it must pass on the current repo, and it must actually fail when drift is
/// introduced. The second half is the part that matters — a checker that can only pass is
/// indistinguishable from `exit 0`.
final class SchemaDriftToolTests: XCTestCase {

    private var repoRoot: URL {
        // .../Tests/RavonCoreTests/SchemaDriftToolTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runTool(extraSwiftFile: (name: String, contents: String)? = nil) throws -> Int32 {
        var planted: URL?
        if let extra = extraSwiftFile {
            let url = repoRoot
                .appendingPathComponent("Sources/RavonCore/Models")
                .appendingPathComponent(extra.name)
            try extra.contents.write(to: url, atomically: true, encoding: .utf8)
            planted = url
        }
        defer { if let planted { try? FileManager.default.removeItem(at: planted) } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "scripts/schema_drift.py"]
        process.currentDirectoryURL = repoRoot
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func test_toolPassesOnCurrentRepo() throws {
        XCTAssertEqual(try runTool(), 0, "schema drift detected in the committed state")
    }

    /// Plant a Swift enum case that Postgres cannot produce and confirm the tool fails.
    ///
    /// `order_status` is the one enum whose migration record is partially complete
    /// (migrations 09 and 06 add values), so a *Postgres* value absent from Swift is
    /// provable drift. Here we invert it: declare the reverse direction by shadowing the
    /// enum map's expectations.
    func test_toolDetectsPostgresValueSwiftCannotDecode() throws {
        // A Swift enum mapped to `order_status` that omits values the migrations prove
        // exist (`scheduled`, `cancelled_by_courier` are added by migrations 06 and 09).
        let planted = """
        // Temporary fixture written by SchemaDriftToolTests. Safe to delete.
        public enum OrderStatus: String, Codable, CaseIterable, Sendable {
            case created
        }
        """
        let status = try runTool(extraSwiftFile: ("ZZZDriftFixture.swift", planted))
        XCTAssertEqual(
            status, 1,
            "tool did not fail on a Swift enum missing Postgres values it must decode"
        )
    }
}
