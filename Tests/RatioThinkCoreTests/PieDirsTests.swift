import XCTest
@testable import RatioThinkCore

/// Unit tests for `PieDirs` resolution. Routes all in-process
/// configuration through the `@TaskLocal homeOverride` injection seam
/// — no setenv calls in this file (those mutate process-global state
/// and would race with CLIScenarioTests if cross-bundle parallelism is
/// enabled, per  finding F6). Tests covering the
/// `$PIE_HOME` env fallback spawn the `pie-resolve-probe` binary so
/// env mutation is contained and the assertion exercises the real
/// `PieDirs.applicationSupport()` code path (review v4 F9).
final class PieDirsTests: XCTestCase {

  // MARK: - homeOverride injection seam (primary contract)

  func test_homeOverride_routes_root_through_temp() throws {
    try withTempRoot { temp in
      try PieDirs.$homeOverride.withValue(temp) {
        let root = try PieDirs.applicationSupport()
        XCTAssertEqual(root.standardizedFileURL.path, temp.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        let profiles = try PieDirs.profiles()
        XCTAssertEqual(profiles.deletingLastPathComponent().standardizedFileURL.path,
                       temp.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profiles.path))
      }
    }
  }

  func test_homeOverride_scope_does_not_leak_beyond_withValue() throws {
    try withTempRoot { temp in
      PieDirs.$homeOverride.withValue(temp) {
        XCTAssertEqual(PieDirs.homeOverride?.standardizedFileURL.path,
                       temp.standardizedFileURL.path)
      }
      XCTAssertNil(PieDirs.homeOverride,
                   "@TaskLocal must clear on withValue exit")
    }
  }

  func test_models_dir_is_excluded_from_backup_under_override() throws {
    try withTempRoot { temp in
      try PieDirs.$homeOverride.withValue(temp) {
        let models = try PieDirs.models()
        let vals = try models.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(vals.isExcludedFromBackup, true)
      }
    }
  }

  func test_derived_paths_compose_off_override_root() throws {
    try withTempRoot { temp in
      try PieDirs.$homeOverride.withValue(temp) {
        let chats = try PieDirs.chatsSQLite()
        XCTAssertEqual(chats.deletingLastPathComponent().standardizedFileURL.path,
                       temp.standardizedFileURL.path)
        XCTAssertEqual(chats.lastPathComponent, "chats.sqlite")
      }
    }
  }

  // MARK: - errors

  func test_rootMkdirFailed_when_override_points_at_unwritable_parent() {
    let unwritable = URL(fileURLWithPath: "/System/Library/pie-test-cannot-create")
    PieDirs.$homeOverride.withValue(unwritable) {
      do {
        _ = try PieDirs.applicationSupport()
        XCTFail("expected throw, got success")
      } catch let err as PieDirsError {
        guard case .rootMkdirFailed(let path, _) = err else {
          XCTFail("expected .rootMkdirFailed, got \(err)")
          return
        }
        XCTAssertEqual(path, unwritable.path)
      } catch {
        XCTFail("expected PieDirsError, got \(error)")
      }
    }
  }

  // MARK: - $PIE_HOME env fallback (out-of-process via real probe binary)

  func test_PIE_HOME_env_fallback_through_real_PieDirs() throws {
    let temp = try Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }

    let probe = try ResolveProbe.find()
    let result = try ResolveProbe.run(probe: probe, env: [
      "PIE_HOME":         temp.path,
      "PIE_XPC_SERVICE":  "com.ratiothink.helper.test.\(UUID().uuidString.prefix(8))",
      "PIE_TEST_MODE":    "1",
    ], mode: "dirs")
    XCTAssertEqual(result.exitCode, 0, "probe stderr=\(result.stderr)")
    XCTAssertTrue(result.stdout.contains("appSupport=\(temp.standardizedFileURL.path)"),
                  "probe stdout=\(result.stdout)")
  }

  // MARK: - helpers

  /// Wraps a block in a fresh temp root, guaranteed cleanup. Uses
  /// `try` (not `try?`) — cleanup failure fails the test red instead
  /// of leaking /tmp dirs (review v1 F5).
  private func withTempRoot(_ body: (URL) throws -> Void) throws {
    let temp = try Self.makeTempRoot()
    var bodyError: Error?
    do { try body(temp) } catch { bodyError = error }
    try FileManager.default.removeItem(at: temp)
    if let bodyError { throw bodyError }
  }

  fileprivate static func makeTempRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
