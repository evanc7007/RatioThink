import XCTest

/// Sanity-fail injection ( v8 F2 / ).
///
/// Triggers a deterministic `XCTFail` ONLY when
/// `PIE_SANITY_FAIL_INJECTION=1` is set in the env. Used by the CI
/// `gmake-sanity-fail-injection` job to verify the Makefile's
/// `set +e +o pipefail` recipe guard actually neutralizes gmake
/// 4.x's `set -e -o pipefail` default, so the `log: <path>` line is
/// printed BEFORE the recipe aborts and the captured pipeline exit
/// status propagates as the recipe exit code. Without the guard,
/// gmake 4.x would abort the recipe at the failing `swift test`
/// pipeline and lose both the log-path line and the propagated exit
/// code (silently turning a red test into "make exited 0").
///
/// XCTSkips otherwise so `make test-unit` stays green on dev
/// machines that don't opt in.
final class SanityFailInjectionTests: XCTestCase {
  /// Stable sentinel token printed alongside the XCTFail. The CI
  /// gmake canary `grep`s for this exact byte sequence to confirm
  /// the injected failure (not some unrelated compile/toolchain/
  /// flake) is what produced the nonzero recipe exit. Keep in sync
  /// with the assertion in `.github/workflows/lint.yml`
  /// `gmake-sanity-fail-injection`. Review v1 F1.
  static let sentinel = "PIE_SANITY_FAIL_INJECTION_FIRED_v1"

  func test_intentional_failure_when_env_gate_set() throws {
    // Accept "1" or "true" (case-insensitive), trimmed. YAML quoting
    // drift or a future `true` value must not silently disable the
    // canary (review v1 F6).
    let raw = ProcessInfo.processInfo.environment["PIE_SANITY_FAIL_INJECTION"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    try XCTSkipIf(raw != "1" && raw != "true",
                  "gated on PIE_SANITY_FAIL_INJECTION=1 (or 'true'); only the CI gmake-canary job exercises this ( v8 F2 / )")
    XCTFail("\(Self.sentinel) — intentional failure to validate Makefile error propagation under gmake 4.x ( v8 F2 / )")
  }
}
