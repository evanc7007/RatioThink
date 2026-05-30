import XCTest
import Foundation
import RatioThinkCore
import Scenarios

/// XCTest bindings for headless scenarios. Each test case runs one scenario
/// against `CLIRunner`. Engine-touching scenarios (S3) are gated on the
/// pie binary + chat-apc wasm being present; they `XCTSkip` otherwise.

// S1 is a pure-Swift roundtrip (no FS, no subprocess) — XCTestCase is
// enough; isolation overhead would be noise.
final class S1_ProfileRoundtripCLITests: XCTestCase {
  func test_runs() async throws {
    try await S1_ProfileRoundtrip.run(CLIRunner())
  }
}

// S2 + S3 touch real RatioThink FS state (and S3 spawns the pie binary), so they
// run under IsolatedTestCase to get a per-test PIE_HOME + ephemeral
// shmem/port/mach-service env. See .
final class S2_PieDirsCreationCLITests: IsolatedTestCase {
  func test_runs() async throws {
    try await S2_PieDirsCreation.run(CLIRunner())
  }
}

// S6 is a pure-Swift Codable round-trip (no FS, no subprocess, no real
// NSXPCConnection in v1) — XCTestCase is enough. When Phase 2 stands up
// the helper listener we can either swap this for IsolatedTestCase + a
// process-spawning runner or add a separate `S6_RealXPC` binding next
// to it; the scenario definition itself doesn't change.
final class S6_XPCRoundtripCLITests: XCTestCase {
  func test_runs() async throws {
    try await S6_XPCRoundtrip.run(CLIRunner())
  }
}

final class S3_EngineSubprocessCLITests: IsolatedTestCase {
  /// Hardcoded for now — see  follow-up F11 for env-driven
  /// model selection (`PIE_TEST_MODEL`).
  private static let s3ModelID = "Qwen/Qwen3-0.6B"

  /// Env gate (review v1 F10). Default off so `make test-scenario`
  /// stays fast + deterministic. CI enables on hosts with the HF
  /// snapshot pre-warmed and a Metal-capable GPU.
  private static let realInferenceEnvVar = "PIE_TEST_S3_REAL"

  func test_runs() async throws {
    // Preconditions are probed BEFORE launch; each one surfaces via
    // XCTSkip (review v1 F5). Anything that goes wrong AFTER pie serve
    // is up surfaces as a hard test failure inside the scenario.
    try requireRealInferenceEnabled()
    let pieURL = try discoverPieBinary()
    let resources = try discoverBundledInferletResources()
    try requireHFSnapshotPresent(modelID: Self.s3ModelID)

    // Cold load of Qwen3-0.6B is ~15–60s; `withTimeout` inside the
    // scenario caps the load step itself at 90s. 300s here is the
    // outer-test allowance (XCTest only enforces it when the scheme
    // opts in; documents the upper bound regardless).
    self.executionTimeAllowance = 300

    let launcherSpec = try PieControlLauncher.LaunchSpec(
      pieBinary: pieURL,
      wasmURL: resources.wasm,
      manifestURL: resources.manifest,
      subprocessEnvironment: subprocessEnvironment,
      pieHome: tempPieHome,
      shmemName: shmemName,
      handshakeTimeout: 30,
      pidSink: { [weak self] pid in self?.trackSubprocess(pid) },
      modelConfig: .metal(modelID: Self.s3ModelID)
    )

    do {
      try await S3_EngineSubprocess.run(CLIRunner(), spec: launcherSpec)
    } catch let ScenarioError.precondition(reason) {
      // Late-discovered precondition (a probe inside the scenario
      // realised the host can't run this). Map to XCTSkip — review
      // v1 F5 reserves XCTSkip for preconditions only.
      throw XCTSkip("S3 skipped: \(reason)")
    }
  }

  func test_discoverPieBinary_missingPIEBINOverride_skips() throws {
    let missing = tempPieHome.appendingPathComponent("missing-pie")
    let previous = ProcessInfo.processInfo.environment["PIE_BIN"]
    setenv("PIE_BIN", missing.path, 1)
    defer {
      if let previous {
        setenv("PIE_BIN", previous, 1)
      } else {
        unsetenv("PIE_BIN")
      }
    }

    do {
      _ = try discoverPieBinary()
      XCTFail("expected missing PIE_BIN override to XCTSkip before launcher/spawn plumbing")
    } catch let skip as XCTSkip {
      XCTAssertNotNil(skip, "missing PIE_BIN override must be a skip, not a launcher/spawn failure")
    }
  }

  // MARK: - preconditions (XCTSkip on miss)

  /// Review v1 F10. Real Metal inference is gated behind
  /// `PIE_TEST_S3_REAL=1` so the default `make test-scenario` does
  /// NOT pay the 5–90s engine-launch cost on every developer's
  /// machine. CI flips the flag on the Metal job.
  private func requireRealInferenceEnabled() throws {
    let raw = ProcessInfo.processInfo.environment[Self.realInferenceEnvVar] ?? ""
    let on = ["1", "true", "yes", "on"].contains(raw.lowercased())
    try XCTSkipUnless(on,
                      "S3 real Metal inference gated behind \(Self.realInferenceEnvVar)=1 (review v1 F10); current value \(raw.debugDescription)")
  }

  private func discoverPieBinary() throws -> URL {
    let pieURL: URL
    if let env = ProcessInfo.processInfo.environment["PIE_BIN"] {
      pieURL = URL(fileURLWithPath: env)
    } else {
      pieURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Vendor/pie/target/release/pie")
    }
    try XCTSkipUnless(FileManager.default.fileExists(atPath: pieURL.path),
                      "pie binary missing at \(pieURL.path); run `cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release` or set PIE_BIN")
    return pieURL
  }

  private func discoverBundledInferletResources() throws -> (wasm: URL, manifest: URL) {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let wasm = cwd.appendingPathComponent("Inferlets/chat-apc/prebuilt/chat-apc.wasm")
    let manifest = cwd.appendingPathComponent("Inferlets/chat-apc/Pie.toml")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: wasm.path),
                      "chat-apc prebuilt wasm missing at \(wasm.path); run the source-tree build before this test")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: manifest.path),
                      "chat-apc manifest missing at \(manifest.path)")
    return (wasm, manifest)
  }

  /// Review v1 F5. Probe the HF cache layout directly so an absent
  /// model snapshot maps to XCTSkip BEFORE the engine spawns. The
  /// alternative (let `/v1/models/load` 404 and skip on `engineMissing`)
  /// would mask real chat-apc / driver regressions as "no models".
  ///
  /// HF cache layout: `~/.cache/huggingface/hub/models--<owner>--<repo>/snapshots/<hash>/`.
  /// Existence of the `models--…` directory is sufficient — partial
  /// snapshots are out of scope here; pie surfaces those as load-time
  /// errors which the scenario's load step asserts on.
  private func requireHFSnapshotPresent(modelID: String) throws {
    let hubRoot: URL
    if let envRoot = ProcessInfo.processInfo.environment["HF_HOME"] {
      hubRoot = URL(fileURLWithPath: envRoot).appendingPathComponent("hub", isDirectory: true)
    } else {
      let home = FileManager.default.homeDirectoryForCurrentUser
      hubRoot = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }
    let snapshotDir = hubRoot.appendingPathComponent(
      "models--" + modelID.replacingOccurrences(of: "/", with: "--"),
      isDirectory: true
    )
    try XCTSkipUnless(FileManager.default.fileExists(atPath: snapshotDir.path),
                      "HF snapshot for \(modelID) missing at \(snapshotDir.path); pre-warm with `pie model download \(modelID)` or set HF_HOME")
  }
}
