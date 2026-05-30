import XCTest
@testable import RatioThinkCore

/// Unit tests for `SpawnEnvSanitizer` — the single source of truth
/// shared by `IsolatedTestCase.subprocessEnvironment` and
/// `ResolveProbe.run(...)`. Tests call `sanitize(_:)` directly rather
/// than re-implementing the filter logic against the public lists
/// (review v7 F3) — otherwise an internal refactor (ordering,
/// normalization, overlay precedence) would silently drift the
/// callers' behavior away from the tests.
final class SpawnEnvSanitizerTests: XCTestCase {

  // MARK: - prefix-match

  func test_strips_pie_prefix_family() {
    let result = SpawnEnvSanitizer.sanitize([
      "PIE_LOG_LEVEL":     "trash",
      "PIE_DEBUG_BACKEND": "1",
      "HOME":              "/should/survive",
    ])
    XCTAssertNil(result["PIE_LOG_LEVEL"])
    XCTAssertNil(result["PIE_DEBUG_BACKEND"])
    XCTAssertEqual(result["HOME"], "/should/survive")
  }

  func test_strips_rust_mtl_dyld_prefix_families() {
    let result = SpawnEnvSanitizer.sanitize([
      "RUST_BACKTRACE":        "full",
      "RUST_LOG":              "trace",
      "MTL_DEBUG_LAYER":       "1",
      "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
      "DYLD_FALLBACK_LIBRARY_PATH": "/old",
    ])
    XCTAssertTrue(result.isEmpty, "expected all stripped; got \(result)")
  }

  func test_strips_xctest_and_xcode_harness_prefixes() {
    let result = SpawnEnvSanitizer.sanitize([
      "XCTestBundlePath":              "/x/Y.xctest",
      "XCTestSessionIdentifier":       "deadbeef",
      "XCTEST_PARALLEL_WORKER_NUMBER": "0",
      "__XPC_XCTEST_BUNDLE":           "/x",
      "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/d",
      "OS_ACTIVITY_MODE":              "disable",
    ])
    XCTAssertTrue(result.isEmpty, "expected all stripped; got \(result)")
  }

  func test_strips_objc_and_malloc_prefixes() {
    let result = SpawnEnvSanitizer.sanitize([
      "OBJC_DEBUG_FRAGILE_SUPERCLASSES": "1",
      "OBJC_PRINT_LOAD_METHODS":         "1",
      "MallocStackLogging":              "1",
      "MallocStackLoggingNoCompact":     "1",
    ])
    XCTAssertTrue(result.isEmpty, "expected all stripped; got \(result)")
  }

  // MARK: - exact-key match

  func test_strips_exact_toolchain_keys() {
    let result = SpawnEnvSanitizer.sanitize([
      "SDKROOT":       "/old/sdk",
      "DEVELOPER_DIR": "/old/xcode",
      "TOOLCHAINS":    "swift-5.9",
      "NSZombieEnabled": "YES",
    ])
    XCTAssertTrue(result.isEmpty, "expected all stripped; got \(result)")
  }

  /// F5/F2 regression: exact-key match must NOT strip future
  /// `SDKROOT_OVERRIDE`-style siblings via hasPrefix.
  func test_exact_keys_do_not_false_match_siblings() {
    let result = SpawnEnvSanitizer.sanitize([
      "SDKROOT_OVERRIDE":     "/should/survive",
      "DEVELOPER_DIR_PATH":   "/should/survive",
      "TOOLCHAINS_SECONDARY": "/should/survive",
      "NSZombieEnabledX":     "should-survive",
    ])
    XCTAssertEqual(result["SDKROOT_OVERRIDE"], "/should/survive")
    XCTAssertEqual(result["DEVELOPER_DIR_PATH"], "/should/survive")
    XCTAssertEqual(result["TOOLCHAINS_SECONDARY"], "/should/survive")
    XCTAssertEqual(result["NSZombieEnabledX"], "should-survive")
  }

  /// F5 regression: __XPC_ narrowed to __XPC_XCTEST — launchd-injected
  /// process bootstrap state (other __XPC_*) must survive.
  func test_xpc_prefix_is_narrowed_to_xctest() {
    let result = SpawnEnvSanitizer.sanitize([
      "__XPC_DYLD_LIBRARY_PATH": "/x",
      "__XPC_SERVICE_NAME":      "com.apple.launchd",
      "__XPC_XCTEST_BUNDLE":     "/should/strip",
    ])
    XCTAssertEqual(result["__XPC_DYLD_LIBRARY_PATH"], "/x")
    XCTAssertEqual(result["__XPC_SERVICE_NAME"], "com.apple.launchd")
    XCTAssertNil(result["__XPC_XCTEST_BUNDLE"])
  }

  // MARK: - survivors

  func test_path_home_user_survive() {
    let result = SpawnEnvSanitizer.sanitize([
      "PATH":  "/usr/bin",
      "HOME":  "/Users/me",
      "USER":  "me",
      "SHELL": "/bin/zsh",
    ])
    XCTAssertEqual(result["PATH"], "/usr/bin")
    XCTAssertEqual(result["HOME"], "/Users/me")
    XCTAssertEqual(result["USER"], "me")
    XCTAssertEqual(result["SHELL"], "/bin/zsh")
  }

  // MARK: - edge cases

  func test_empty_env_returns_empty() {
    XCTAssertTrue(SpawnEnvSanitizer.sanitize([:]).isEmpty)
  }

  func test_key_matching_both_prefix_and_exact_is_stripped_once() {
    // Hypothetical key that satisfies both filter modes — must still
    // resolve to "stripped" without double-counting / surprises.
    // (No real key collides today; documents intended semantics.)
    let result = SpawnEnvSanitizer.sanitize([
      "PIE_HOME": "/should/strip-via-prefix",
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func test_value_payload_is_irrelevant_to_filtering() {
    let result = SpawnEnvSanitizer.sanitize([
      "PIE_LOG_LEVEL": "",  // empty value, key still leaky
      "PIE_DEBUG":     "1",
      "HOME":          "",   // empty value, but survivor key
    ])
    XCTAssertNil(result["PIE_LOG_LEVEL"])
    XCTAssertNil(result["PIE_DEBUG"])
    XCTAssertEqual(result["HOME"], "")
  }

  // MARK: - published list invariants

  /// Lock in the published policy. If either list changes,
  /// downstream consumers (IsolatedTestCase alias forwarders,
  /// ResolveProbe doc) must be reviewed.
  func test_prefix_list_is_stable() {
    XCTAssertEqual(SpawnEnvSanitizer.stripPrefixes, [
      "PIE_", "RUST_", "MTL_", "DYLD_",
      "XCTest", "XCTEST_", "__XPC_XCTEST", "__XCODE_", "OS_ACTIVITY_",
      "OBJC_", "MallocStackLogging",
    ])
  }

  func test_exact_key_set_is_stable() {
    XCTAssertEqual(SpawnEnvSanitizer.stripExactKeys, [
      "SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS", "NSZombieEnabled",
    ])
  }
}
