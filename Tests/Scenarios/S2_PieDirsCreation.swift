import Foundation

/// S2 — PieDirs lazy directory creation.
///
/// Calling each `PieDirs.<kind>` accessor creates the directory under
/// the configured RatioThink root — `$PIE_HOME` if set, otherwise
/// `~/Library/Application Support/RatioThink/`. The `models/` directory carries
/// the `isExcludedFromBackup` resource value so Time Machine skips multi-GB
/// GGUF files by default (R4 mitigation in design doc).
public enum S2_PieDirsCreation {
  public static let title = "PieDirs lazy creation + .nobackup on models/"

  public static func run<R: ScenarioRunner>(_ r: R) async throws {
    try await r.step("applicationSupport resolves to a writable directory (PIE_HOME-aware)") {
      let url = try await r.pieDirsApplicationSupport()
      try r.require(try await r.fileExists(at: url),
                    "applicationSupport not created: \(url.path)")
    }

    for kind in PieDirsKind.allCases {
      try await r.step("subpath '\(kind.rawValue)' exists after access") {
        let url = try await r.pieDirsSubpath(kind)
        try r.require(url.path.hasSuffix("/\(kind.rawValue)"), "wrong suffix: \(url.path)")
        try r.require(try await r.fileExists(at: url), "directory not created: \(url.path)")
      }
    }

    try await r.step("models/ is excluded from Time Machine backup") {
      let url = try await r.pieDirsSubpath(.models)
      let excluded = try await r.resourceIsExcludedFromBackup(at: url)
      try r.require(excluded, "models/ missing isExcludedFromBackup attribute")
    }
  }
}
