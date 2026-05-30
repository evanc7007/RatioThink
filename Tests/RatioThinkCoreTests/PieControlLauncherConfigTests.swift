import Darwin
import Foundation
import XCTest
@testable import RatioThinkCore

/// Pins `PieControlLauncher.renderConfigBody` so a future TOML drift
/// in `pie serve --config` is caught at the unit-test layer instead
/// of surfacing as a runtime "engine exited early" on the helper
/// boot path.  introduced the `.portable` variant; the
/// existing `.dummy` body is pinned for the S0 isolation test
/// (which depends on the same emission shape).
final class PieControlLauncherConfigTests: XCTestCase {

  func test_dummy_body_emits_dummy_driver_with_qwen3_fixture() {
    let body = PieControlLauncher.renderConfigBody(modelConfig: .dummy)
    XCTAssertTrue(body.contains("type = \"dummy\""),
                  "dummy config must declare the dummy driver")
    XCTAssertTrue(body.contains("hf_repo = \"Qwen/Qwen3-0.6B\""),
                  "dummy config must keep the existing Qwen fixture so S0 tests stay stable")
    XCTAssertTrue(body.contains("name = \"default\""),
                  "model name must remain \"default\" — chat-apc resolves against this name")
  }

  func test_portable_body_emits_portable_driver_with_resolved_hf_repo_path() {
    let modelsRoot = URL(fileURLWithPath: "/tmp/pie/models")
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portable(modelSlug: "Qwen3-0.6B-Q4_K_M.gguf",
                             modelsRoot: modelsRoot)
    )
    XCTAssertTrue(body.contains("type = \"portable\""),
                  "production config must declare the portable driver (Metal on macOS)")
    XCTAssertTrue(body.contains("hf_repo = \"/tmp/pie/models/Qwen3-0.6B-Q4_K_M.gguf\""),
                  "pie serve config must pass the resolved local model path through model.hf_repo")
    XCTAssertTrue(body.contains("name = \"Qwen3-0.6B-Q4_K_M.gguf\""),
                  "served model name must be the profile slug (the id the App's chat requests carry), not \"default\"")
    XCTAssertTrue(body.contains("device = [\"metal\"]"),
                  "v1 macOS production config should request Metal explicitly instead of relying on an implicit default")
    XCTAssertFalse(body.contains("hf_path"),
                   "pie serve config no longer accepts top-level hf_path; it resolves model.hf_repo")
    XCTAssertFalse(body.contains("type = \"dummy\""),
                   "portable config must not emit the dummy-driver block")
  }

  func test_portableResolved_serves_under_profile_slug_with_distinct_hf_repo_path() {
    // The crux of the id-unification fix ( follow-up): the engine's
    // served `name` is the profile slug the App carries everywhere, while
    // `hf_repo` is the separately-resolved on-disk path. The two are
    // intentionally different strings — the public id is NOT the resolved
    // path, and it is NOT the old hardcoded "default".
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portableResolved(
        servedModelID: "Qwen/Qwen3-0.6B",
        modelRef: "/Users/me/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B/snapshots/abc"
      )
    )
    XCTAssertTrue(body.contains("name = \"Qwen/Qwen3-0.6B\""),
                  "served name must be the profile slug verbatim so /v1/models and the chat `model` field agree")
    XCTAssertTrue(body.contains("hf_repo = \"/Users/me/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B/snapshots/abc\""),
                  "hf_repo must carry the resolved on-disk path, independent of the served id")
    XCTAssertFalse(body.contains("name = \"default\""),
                   "production bodies must no longer hardcode the served name to \"default\"")
  }

  func test_portable_body_joins_multi_segment_slug_without_percent_escaping() {
    // Mirrors `LaunchSpecResolver.joinModelPath` — the downloader
    // writes `<repo>/<file>` slugs to disk, and the production
    // config must point pie at the same on-disk layout. Without
    // explicit path-component splitting, Foundation would emit
    // `repo%2Ffile`.
    let modelsRoot = URL(fileURLWithPath: "/tmp/pie/models")
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portable(modelSlug: "TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b.gguf",
                             modelsRoot: modelsRoot)
    )
    XCTAssertTrue(body.contains("hf_repo = \"/tmp/pie/models/TheBloke/Llama-2-7B-Chat-GGUF/llama-2-7b.gguf\""),
                  "portable hf_repo path must preserve `/`-segmented downloader layout")
  }

  func test_portable_body_escapes_embedded_quotes_in_slug() {
    // Defensive: a profile-supplied model slug containing a literal
    // `"` would otherwise emit malformed TOML. macOS filesystem
    // paths can technically contain `"`; the launcher must escape
    // before writing.
    let modelsRoot = URL(fileURLWithPath: "/tmp")
    let body = PieControlLauncher.renderConfigBody(
      modelConfig: .portable(modelSlug: "weird\"name.gguf",
                             modelsRoot: modelsRoot)
    )
    XCTAssertTrue(body.contains(#"hf_repo = "/tmp/weird\"name.gguf""#),
                  "embedded quotes must be backslash-escaped; got:\n\(body)")
  }

  func test_writeConfig_writes_file_under_pieHome() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-config-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = try PieControlLauncher.writeConfig(modelConfig: .dummy, in: tmp)
    XCTAssertEqual(url.lastPathComponent, "config.toml")
    let written = try String(contentsOf: url)
    XCTAssertTrue(written.contains("type = \"dummy\""))
  }

  func test_launchSpecConstruction_rejects_portable_when_binary_lacks_portable_driver() throws {
    let binary = try writeCapabilityProbe(portable: false, metal: false)
    XCTAssertThrowsError(try makeSpec(binary: binary,
                                      modelConfig: .portable(modelSlug: "model.gguf",
                                                             modelsRoot: tempModelsRoot()))) { error in
      guard case PieControlLauncher.LaunchError.driverUnsupported(
        requested: let requested, binary: _, details: _
      ) = error else {
        return XCTFail("expected driverUnsupported, got \(error)")
      }
      XCTAssertEqual(requested, "portable")
    }
  }

  func test_launchSpecConstruction_rejects_metal_when_binary_lacks_metal_backend() throws {
    let binary = try writeCapabilityProbe(portable: true, metal: false)
    XCTAssertThrowsError(try makeSpec(binary: binary,
                                      modelConfig: .metal(modelID: "Qwen/Qwen3-0.6B"))) { error in
      guard case PieControlLauncher.LaunchError.driverUnsupported(
        requested: let requested, binary: _, details: _
      ) = error else {
        return XCTFail("expected driverUnsupported, got \(error)")
      }
      XCTAssertEqual(requested, "metal")
    }
  }

  func test_launchSpecConstruction_accepts_metal_when_binary_reports_metal_backend() throws {
    let binary = try writeCapabilityProbe(portable: true, metal: true)
    let spec = try makeSpec(binary: binary,
                            modelConfig: .metal(modelID: "Qwen/Qwen3-0.6B"))
    XCTAssertEqual(spec.pieBinary, binary)
  }

  func test_launchSpecConstruction_uses_subprocessEnvironment_for_capabilityProbe() throws {
    let binary = try writeEnvironmentSensitiveCapabilityProbe(
      key: "CAPABILITY_TEST_FLAG",
      expectedValue: "from-launch-spec"
    )

    XCTAssertNoThrow(try makeSpec(
      binary: binary,
      subprocessEnvironment: ["CAPABILITY_TEST_FLAG": "from-launch-spec"],
      modelConfig: .portable(modelSlug: "model.gguf", modelsRoot: tempModelsRoot())
    ))
  }

  func test_launchSpecConstruction_returnsBoundedFailureWhenProbeChildKeepsStdoutOpen() throws {
    let childPIDFile = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-capability-child-\(UUID().uuidString.prefix(8)).pid")
    let binary = try writeStdoutLeakingCapabilityProbe(childPIDFile: childPIDFile)
    defer { killChildRecorded(in: childPIDFile) }

    let finished = expectation(description: "capability probe returns")
    final class ResultBox: @unchecked Sendable {
      private let lock = NSLock()
      private var value: Result<PieControlLauncher.LaunchSpec, Error>?
      func store(_ newValue: Result<PieControlLauncher.LaunchSpec, Error>) {
        lock.lock()
        value = newValue
        lock.unlock()
      }
      func load() -> Result<PieControlLauncher.LaunchSpec, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
      }
    }
    let resultBox = ResultBox()

    DispatchQueue.global().async {
      resultBox.store(Result {
        try self.makeSpec(
          binary: binary,
          modelConfig: .portable(modelSlug: "model.gguf", modelsRoot: self.tempModelsRoot())
        )
      })
      finished.fulfill()
    }

    let waitResult = XCTWaiter.wait(for: [finished], timeout: 1.5)
    guard waitResult == .completed else {
      killChildRecorded(in: childPIDFile)
      XCTFail("capability probe blocked on inherited stdout pipe instead of returning a bounded driverUnsupported error")
      return
    }

    guard case .failure(let error) = resultBox.load() else {
      return XCTFail("expected bounded driverUnsupported failure when probe pipe stays open")
    }
    guard case PieControlLauncher.LaunchError.driverUnsupported(
      requested: _, binary: _, details: let details
    ) = error else {
      return XCTFail("expected driverUnsupported, got \(error)")
    }
    XCTAssertTrue(details.contains("timed out"),
                  "expected timeout detail for inherited stdout pipe, got \(details)")
  }

  // MARK: - helpers

  private func makeSpec(binary: URL,
                        subprocessEnvironment: [String: String] = [:],
                        modelConfig: PieControlLauncher.ModelConfig) throws -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-launchspec-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    return try PieControlLauncher.LaunchSpec(
      pieBinary: binary,
      wasmURL: tmp.appendingPathComponent("chat-apc.wasm"),
      manifestURL: tmp.appendingPathComponent("Pie.toml"),
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      modelConfig: modelConfig
    )
  }

  private func writeCapabilityProbe(portable: Bool, metal: Bool) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-capabilities-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binary = dir.appendingPathComponent("pie", isDirectory: false)
    let payload = """
    {"drivers":{"portable":\(portable),"cuda_native":false,"dummy":true},"devices":{"metal":\(metal)}}
    """
    let script = """
    #!/bin/sh
    if [ "$1" = "capabilities" ] && [ "$2" = "--json" ]; then
      printf '%s\\n' '\(payload)'
      exit 0
    fi
    exit 64
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: binary.path
    )
    return binary
  }

  private func writeEnvironmentSensitiveCapabilityProbe(key: String,
                                                        expectedValue: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-capabilities-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binary = dir.appendingPathComponent("pie", isDirectory: false)
    let script = """
    #!/bin/sh
    if [ "$1" = "capabilities" ] && [ "$2" = "--json" ]; then
      if [ "${\(key)}" = "\(expectedValue)" ]; then
        printf '%s\\n' '{"drivers":{"portable":true,"cuda_native":false,"dummy":true},"devices":{"metal":false}}'
      else
        printf '%s\\n' '{"drivers":{"portable":false,"cuda_native":false,"dummy":true},"devices":{"metal":false}}'
      fi
      exit 0
    fi
    exit 64
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: binary.path
    )
    return binary
  }

  private func writeStdoutLeakingCapabilityProbe(childPIDFile: URL) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-capabilities-\(UUID().uuidString.prefix(8))",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binary = dir.appendingPathComponent("pie", isDirectory: false)
    let script = """
    #!/bin/sh
    if [ "$1" = "capabilities" ] && [ "$2" = "--json" ]; then
      ( sleep 30 ) &
      echo $! > '\(childPIDFile.path)'
      printf '%s\\n' '{"drivers":{"portable":true,"cuda_native":false,"dummy":true},"devices":{"metal":false}}'
      exit 0
    fi
    exit 64
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: binary.path
    )
    return binary
  }

  private func killChildRecorded(in childPIDFile: URL) {
    guard let raw = try? String(contentsOf: childPIDFile, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return
    }
    _ = Darwin.kill(pid, SIGKILL)
  }

  private func tempModelsRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
  }
}
