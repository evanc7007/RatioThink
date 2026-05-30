import XCTest
import Foundation
@testable import RatioThinkCore

/// Helper for spawning the `pie-resolve-probe` SPM executable target
/// under a constructed env. Used by PieDirsTests + HelperConfigTests
/// to exercise the production env-fallback code paths without
/// mutating the test process's env (which would race across bundles).
/// Replaces the v3 inline hand-written probe scripts that bypassed
/// the real RatioThinkCore APIs (review v4 F9).
enum ResolveProbe {
  struct Result {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  enum ProbeError: Error, CustomStringConvertible {
    case binaryNotFound(searched: String)
    case missingUnderCI(searched: String)
    case unsupportedXcodeBuildEntryPoint(bundlePath: String)

    var description: String {
      switch self {
      case let .binaryNotFound(searched):
        return "pie-resolve-probe binary not found near \(searched); run `swift build --product pie-resolve-probe` first"
      case let .missingUnderCI(searched):
        return "pie-resolve-probe binary not found near \(searched) AND $CI is set — refusing to skip probe coverage in CI (review v5 F2). `make build-tests` must build the probe before running this bundle."
      case let .unsupportedXcodeBuildEntryPoint(bundlePath):
        return "xcodebuild test entry point is not supported for ResolveProbe-driven tests (bundle at \(bundlePath) is under DerivedData/.../Build/Products/, not SPM .build/). Use `swift test` / `make test-unit` instead. To support xcodebuild test, bind the SPM probe into DerivedData via a pre-action or copy phase. Review v7 F6."
      }
    }
  }

  /// Locate `pie-resolve-probe` in the SPM `.build` tree. SwiftPM
  /// builds the binary alongside test bundles during `swift test`,
  /// so the same `.build/<triple>/debug/` dir holds both.
  ///
  /// LIMITATION (review v6 F5): under `xcodebuild test`, the test
  /// bundle lives in `DerivedData/.../Build/Products/Debug/` — NOT
  /// `.build/`. The upward walk will not find the SPM-built probe
  /// from there. ResolveProbe-driven tests therefore only work
  /// under the `swift test` / `Scripts/run-swift-test.sh` entry
  /// point (the path `make test-unit` + CI use). If a future
  /// `xcodebuild test` invocation needs this coverage, bind the SPM
  /// probe into DerivedData via an xcodebuild pre-action or copy
  /// phase. Documented in PieDirsTests + HelperConfigTests fixtures.
  ///
  /// Behavior under failure (review v5 F2):
  ///   · Locally (no `$CI`): throws `XCTSkip` so a developer who
  ///     forgot to run `swift build` doesn't see a wall of red.
  ///   · Under CI (`$CI` is set, GitHub Actions convention): throws
  ///     a hard `ProbeError.missingUnderCI` so the env-fallback
  ///     coverage cannot vanish silently.
  static func find() throws -> URL {
    let bundleURL = Bundle(for: ProbeTagClass.self).bundleURL

    //  F6 + review v1 F3: detect the SPM layout via a
    // POSITIVE check for an SPM-shaped `.build/` ancestor rather
    // than a negative `/Build/Products/` substring check. The bare
    // `lastPathComponent == ".build"` form false-positives on any
    // workspace directory literally named `.build` (mise/direnv
    // caches, renamed DerivedData roots) — falling through to the
    // 6-level binary search misattributes the failure to "probe
    // not built" when the real cause is incorrect layout detection.
    //
    // SPM places the test bundle at
    //   <pkg>/.build/<triple>/<config>/<Bundle>.xctest/Contents/...
    // and `<pkg>/Package.swift` is always a sibling of `.build`.
    // Require BOTH:
    //   (a) a `.build` ancestor whose name is exactly `.build`, AND
    //   (b) `<.build's parent>/Package.swift` exists.
    // (b) is what eliminates the false-positive class above.
    var ancestor = bundleURL.deletingLastPathComponent()
    var spmBuildRoot: URL?
    for _ in 0..<8 {
      if ancestor.lastPathComponent == ".build" {
        let pkgManifest = ancestor.deletingLastPathComponent()
          .appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: pkgManifest.path) {
          spmBuildRoot = ancestor
          break
        }
        // `.build` without a sibling `Package.swift` — unrelated
        // directory of the same name. Keep walking; SPM's real
        // `.build` may live further up.
      }
      let parent = ancestor.deletingLastPathComponent()
      if parent.path == ancestor.path { break }
      ancestor = parent
    }
    // F7 + review v1 F7: emit the stderr breadcrumb on EVERY failure
    // path, not just the SPM-locally-missing one. The audience that
    // previously silent-skipped under `xcodebuild test` is exactly
    // who needs the breadcrumb most — without this they get an
    // XCTest-routed error with no terminal-level signal. Defer the
    // actual write until we know we're about to fail so the success
    // path stays silent.
    func emitStderrBreadcrumb(reason: String) {
      let line = "warning: pie-resolve-probe not located (\(reason)); bundle=\(bundleURL.path); run `swift build --product pie-resolve-probe` (or `make build-tests`) to enable env-fallback coverage\n"
      FileHandle.standardError.write(Data(line.utf8))
    }

    guard spmBuildRoot != nil else {
      emitStderrBreadcrumb(reason: "non-SPM bundle layout, no `.build/` ancestor with sibling Package.swift")
      throw ProbeError.unsupportedXcodeBuildEntryPoint(bundlePath: bundleURL.path)
    }

    var dir = bundleURL.deletingLastPathComponent()
    for _ in 0..<6 {
      let candidate = dir.appendingPathComponent("pie-resolve-probe")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
      dir = dir.deletingLastPathComponent()
    }
    if ProcessInfo.processInfo.environment["CI"] != nil {
      emitStderrBreadcrumb(reason: "binary not found near bundle AND $CI is set")
      throw ProbeError.missingUnderCI(searched: bundleURL.path)
    }
    emitStderrBreadcrumb(reason: "binary not found near bundle (local dev path)")
    throw XCTSkip("pie-resolve-probe binary not found near \(bundleURL.path); run `swift build --product pie-resolve-probe` first")
  }

  /// Spawn the probe with `env` overlaid on a SANITIZED parent env.
  /// Sanitization policy is shared with `IsolatedTestCase` via
  /// `SpawnEnvSanitizer` — diverging the two lists previously let
  /// keys like `XCTestBundlePath` / `OS_ACTIVITY_MODE` / `SDKROOT`
  /// leak into the probe on the test-bundle entry point but not the
  /// engine-spawn entry point, surfacing as asymmetric flake (review
  /// v6 F2). PATH/HOME survive — neither prefix nor exact-strip
  /// matches them.
  static func run(probe: URL, env: [String: String], mode: String, args: [String] = []) throws -> Result {
    let sanitizedParent = SpawnEnvSanitizer.sanitize(ProcessInfo.processInfo.environment)
    let finalEnv = sanitizedParent.merging(env) { _, override in override }

    let proc = Process()
    proc.executableURL = probe
    proc.arguments = [mode] + args
    proc.environment = finalEnv

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError  = errPipe
    try proc.run()
    proc.waitUntilExit()

    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return Result(exitCode: proc.terminationStatus, stdout: out, stderr: err)
  }
}

/// Internal marker class so `Bundle(for:)` can resolve the test
/// bundle URL — needed to locate the SPM `.build` debug dir.
private final class ProbeTagClass {}
