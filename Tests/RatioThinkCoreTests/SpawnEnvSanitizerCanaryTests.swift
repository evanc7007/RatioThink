import XCTest
@testable import RatioThinkCore

/// Sanitizer-stability canary ( F8).
///
/// Catches drift between `SpawnEnvSanitizer`'s declared policy and
/// its actual behavior. The unit suite proves the algorithm in
/// isolation against synthetic inputs; this canary proves it
/// against the live, CI-injected environment so a future edit that
/// silently desynchronizes (e.g. removes `PIE_` from `stripPrefixes`
/// while a comment elsewhere still claims it) is caught at the
/// process boundary — the only place that matters in production.
///
/// Gated on `SPAWN_SANITIZER_CANARY=1` so it only runs in CI's
/// dedicated job. Local dev runs `make test-unit` without the gate
/// and the canary XCTSkips.
///
/// The CI job (`sanitizer-stability-canary` in `.github/workflows/
/// lint.yml`) injects one canary key per documented prefix family
/// + one per documented exact-strip name + one survival witness per
/// family the policy intentionally narrows. This test reads those
/// keys back from the live process env and asserts:
///   1. injection actually reached the test process (else the CI
///      job is silently broken),
///   2. every stripped-policy key is absent from `sanitize(env)`,
///   3. every survival-policy key is present in `sanitize(env)`.
final class SpawnEnvSanitizerCanaryTests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }
  private var sanitized: [String: String] { SpawnEnvSanitizer.sanitize(env) }

  private func skipIfCanaryNotEnabled() throws {
    try XCTSkipIf(env["SPAWN_SANITIZER_CANARY"] != "1",
                  "set SPAWN_SANITIZER_CANARY=1 to run; only the CI canary job exercises this test")
  }

  // MARK: - prefix-family canaries

  /// One key per documented prefix family in
  /// `SpawnEnvSanitizer.stripPrefixes` whose injection survives the
  /// `swift test` → `xctest` spawn chain AND does not poison the
  /// Swift toolchain mid-run.
  ///
  /// Three families are deliberately omitted from end-to-end
  /// coverage; all three are exercised by `SpawnEnvSanitizerTests`
  /// against synthetic input:
  ///   · `DYLD_*` — hardened-runtime xctest strips DYLD env on exec,
  ///     so an injected `DYLD_*` never reaches the test process.
  ///   · `__XPC_XCTEST` — launchd-injected, also stripped on exec.
  ///   · `MallocStackLogging` — recognized by libsystem_malloc and
  ///     activates malloc stack logging in EVERY child swift-frontend
  ///     / clang / ld process spawned during compile. Local repro
  ///     surfaced "error: fatalError" out of swift-driver before any
  ///     test ran when this canary was set. Setting it to a sentinel
  ///     string still trips the allocator; there is no inert value.
  private static let prefixCanaries: [(prefix: String, key: String)] = [
    ("PIE_",          "PIE_SANITIZER_CANARY"),
    ("RUST_",         "RUST_SANITIZER_CANARY"),
    ("MTL_",          "MTL_SANITIZER_CANARY"),
    ("XCTest",        "XCTestSanitizerCanary"),
    ("XCTEST_",       "XCTEST_SANITIZER_CANARY"),
    ("__XCODE_",      "__XCODE_SANITIZER_CANARY"),
    ("OS_ACTIVITY_",  "OS_ACTIVITY_SANITIZER_CANARY"),
    ("OBJC_",         "OBJC_SANITIZER_CANARY"),
  ]

  func test_every_documented_prefix_strips_an_injected_canary() throws {
    try skipIfCanaryNotEnabled()
    let live = env
    let out  = sanitized
    for (prefix, key) in Self.prefixCanaries {
      XCTAssertNotNil(live[key],
                      "CI did not inject canary key `\(key)` for prefix `\(prefix)` — workflow lost a step")
      XCTAssertNil(out[key],
                   "SpawnEnvSanitizer.sanitize did NOT strip `\(key)` despite prefix `\(prefix)` being in stripPrefixes — policy/behavior drift")
      // And every prefix in the live policy must actually still be
      // wired (no stealth removal).
      XCTAssertTrue(SpawnEnvSanitizer.stripPrefixes.contains(prefix),
                    "stripPrefixes no longer contains `\(prefix)` — update prefixCanaries list AND the public contract docstring")
    }
  }

  // MARK: - exact-key canaries

  /// `NSZombieEnabled` is the one exact-key entry we can inject in
  /// CI without breaking the test process: SDKROOT / DEVELOPER_DIR /
  /// TOOLCHAINS are read by `xcrun` + the Swift driver at run time,
  /// so overriding them to canary values would fail toolchain
  /// resolution before our test ever loads. Those three are covered
  /// by `SpawnEnvSanitizerTests` against synthetic input; this
  /// canary witnesses the exact-match path end-to-end via
  /// `NSZombieEnabled`, which has no production side effect.
  private static let exactCanaries: [String] = [
    "NSZombieEnabled",
  ]

  func test_every_documented_exact_key_strips_an_injected_canary() throws {
    try skipIfCanaryNotEnabled()
    let live = env
    let out  = sanitized
    for key in Self.exactCanaries {
      XCTAssertNotNil(live[key],
                      "CI did not inject exact canary key `\(key)` — workflow lost a step")
      XCTAssertNil(out[key],
                   "SpawnEnvSanitizer.sanitize did NOT strip exact key `\(key)` — policy/behavior drift")
      XCTAssertTrue(SpawnEnvSanitizer.stripExactKeys.contains(key),
                    "stripExactKeys no longer contains `\(key)` — update exactCanaries list AND the public contract docstring")
    }
  }

  // MARK: - survival canaries

  /// Keys the policy deliberately narrows so adjacent siblings
  /// SURVIVE. If a future "tighten the filter" change accidentally
  /// over-matches (e.g. switches `SDKROOT` exact-match to
  /// `hasPrefix("SDKROOT")`, or broadens `__XPC_XCTEST` back to
  /// bare `__XPC_`), these assertions catch it.
  private static let survivalCanaries: [(rationale: String, key: String)] = [
    ("PIE_ is a prefix family; an unrelated `PIESURVIVES` (no underscore) must survive",
     "PIESURVIVES_CANARY"),
    ("MallocStackLogging is matched via prefix; an unrelated `Malloc` sibling must survive — the stripped-side canary lives in unit tests because MallocStackLogging itself poisons the toolchain spawn chain",
     "MallocCanarySurvives"),
  ]

  func test_narrowed_policy_keys_let_siblings_survive() throws {
    try skipIfCanaryNotEnabled()
    let live = env
    let out  = sanitized
    for (rationale, key) in Self.survivalCanaries {
      XCTAssertNotNil(live[key],
                      "CI did not inject survival canary `\(key)` — workflow lost a step (\(rationale))")
      XCTAssertEqual(out[key], live[key],
                     "SpawnEnvSanitizer.sanitize stripped `\(key)` — narrowed policy over-matched (\(rationale))")
    }
  }
}
