import Foundation

/// Policy for filtering the parent process env before spawning a
/// subprocess that should run in a known-clean isolation namespace.
/// Single source of truth for both:
///   · `IsolatedTestCase.subprocessEnvironment` — env for the spawned
///     pie engine under integration tests.
///   · `ResolveProbe.run(...)` — env for the in-test `pie-resolve-probe`
///     binary that exercises production env-fallback code paths.
///
/// Diverging the two consumer-side lists previously created an
/// asymmetric-leak surprise: a stray `XCTestBundlePath` /
/// `OS_ACTIVITY_MODE` / `SDKROOT` from the developer's shell or the
/// xctest parent reached one entry point but not the other (review
/// v6 F2). Both consumers now call into this module.
///
/// Two filter modes:
///   · Prefix-match for API families where every key under the prefix
///     is known leaky (`PIE_*`, `DYLD_*`).
///   · Exact-key match for vars whose name is fixed and would
///     otherwise risk false-positive sibling matches (e.g.
///     `SDKROOT_OVERRIDE` if we used `hasPrefix("SDKROOT")`).
public enum SpawnEnvSanitizer {
  /// Prefix-match strip list. Only API families where every key under
  /// the prefix is known leaky belong here.
  public static let stripPrefixes: [String] = [
    // pie + adjacent tracing.
    "PIE_",            // anything pie reads at boot (LOG_LEVEL, DEBUG_*, …)
    "RUST_",           // RUST_LOG, RUST_BACKTRACE leak into pie's tracing
    "MTL_",            // Metal validation/debug flags alter perf wildly
    // dynamic loader + ABI poisoning.
    "DYLD_",           // dynamic linker injection — security + repro
    // XCTest / Xcode harness state. Narrowed from bare `__XPC_`
    // (overly aggressive — launchd-injected `__XPC_DYLD_LIBRARY_PATH`
    // etc are needed by pie's own XPC bootstrap).
    "XCTest",          // XCTestBundlePath, XCTestSessionIdentifier, …
    "XCTEST_",         // XCTEST_PARALLEL_WORKER_NUMBER, etc
    "__XPC_XCTEST",    // only XCTest-injected variants
    "__XCODE_",        // Xcode-injected runtime markers
    "OS_ACTIVITY_",    // alters os_log routing in the child
    // Objective-C / Foundation debug toggles — drastic perf change.
    "OBJC_",           // OBJC_DEBUG_*, OBJC_PRINT_*
    "MallocStackLogging", // matches MallocStackLogging + MallocStackLoggingNoCompact
  ]

  /// Exact-key strip list. Used for keys whose name is fixed (no
  /// underscore-prefixed family) — keeps the filter strict instead of
  /// accidentally matching future `SDKROOT_OVERRIDE`-style siblings
  /// via `hasPrefix`.
  public static let stripExactKeys: Set<String> = [
    "SDKROOT",
    "DEVELOPER_DIR",
    "TOOLCHAINS",
    "NSZombieEnabled",
  ]

  /// Filter `parent` by removing every key that matches a strip
  /// prefix or an exact-strip name. Pure function; no env mutation.
  public static func sanitize(_ parent: [String: String]) -> [String: String] {
    parent.filter { key, _ in
      let byPrefix = stripPrefixes.contains(where: { key.hasPrefix($0) })
      let byExact  = stripExactKeys.contains(key)
      return !(byPrefix || byExact)
    }
  }
}
