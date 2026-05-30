import XCTest
@testable import RatioThinkCore

/// Unit tests for the caller-identity gate. The full
/// `validate(connection:)` path needs a live `NSXPCConnection` so the
/// production identity-rejection branch is covered by
/// `XPCListenerIntegrationTests.testProductionIdentityRejectsTestPeer`
/// (review v1 F14). These tests cover the pieces of the gate that
/// don't require an XPC peer.
final class CallerIdentityTests: XCTestCase {

  // MARK: - IdentityError surface

  /// Every IdentityError case carries a distinct `description`. Field
  /// triage uses these strings; if two collapse to the same text the
  /// gate's diagnostic value drops to the prior `nil` regression
  /// (review v1 F9).
  func test_identityError_descriptions_are_distinct() {
    let cases: [CallerIdentity.IdentityError] = [
      .auditTokenMissing,
      .auditTokenWrongType(observedClass: "NSDictionary"),
      .auditTokenWrongSize(observed: 16, expected: 32),
      .securityFrameworkFailure(api: "SecCodeCopyGuestWithAttributes", osStatus: -67049),
      .teamIDAbsent,
      .teamIDMismatch(ours: "AAA111", theirs: "BBB222"),
      .selfIdentityUnreadable,
    ]
    let descriptions = cases.map { $0.description }
    XCTAssertEqual(Set(descriptions).count, descriptions.count,
                   "every IdentityError case must produce a distinct description")
    for d in descriptions {
      XCTAssertFalse(d.isEmpty)
    }
  }

  /// `teamIDMismatch` carries both Team IDs through to the
  /// description (review v2 F3) so operators see which signer
  /// connected. The prior code collapsed mismatches into
  /// `.teamIDAbsent`, losing this signal entirely.
  func test_teamIDMismatch_description_carries_both_ids() {
    let err = CallerIdentity.IdentityError.teamIDMismatch(
      ours: "AAA111BBB2", theirs: "ZZZ999YYY8"
    )
    XCTAssertTrue(err.description.contains("AAA111BBB2") &&
                  err.description.contains("ZZZ999YYY8"),
                  "mismatch description must carry both IDs, got: \(err.description)")
    // Distinct from teamIDAbsent — the v2 F3 bug.
    XCTAssertNotEqual(err, .teamIDAbsent)
  }

  /// `securityFrameworkFailure` carries the OSStatus value through to
  /// the description so the operator can decode it (e.g.
  /// `-67049 = errSecCSReqFailed`).
  func test_securityFrameworkFailure_description_carries_osstatus() {
    let err = CallerIdentity.IdentityError.securityFrameworkFailure(
      api: "SecCodeCopyGuestWithAttributes", osStatus: -67049
    )
    XCTAssertTrue(err.description.contains("-67049"),
                  "OSStatus must appear in description, got: \(err.description)")
  }

  /// `auditTokenWrongSize` carries both observed and expected so a
  /// future regression report identifies the delta (review v1 F10).
  func test_auditTokenWrongSize_description_carries_both_sizes() {
    let err = CallerIdentity.IdentityError.auditTokenWrongSize(observed: 16, expected: 32)
    XCTAssertTrue(err.description.contains("16") && err.description.contains("32"),
                  "wrong-size description must surface both numbers, got: \(err.description)")
  }

  // MARK: - bypass priority (review v1 F1)

  /// Test-mode bypass beats DEBUG bypass when both are present.
  /// Protects against the priority order silently inverting (a
  /// refactor that returned the DEBUG branch first would let prod
  /// tests run under a different bypass path than intended).
  func test_bypassReason_testMode_takes_priority_over_debug() {
    HelperConfig.$overrides.withValue(.init(xpcServiceName: "com.ratiothink.helper.test.unit",
                                            testMode: true)) {
      XCTAssertEqual(CallerIdentity.bypassReason(), "PIE_TEST_MODE=1")
    }
  }

  /// DEBUG alone — without the explicit
  /// `PIE_ALLOW_UNSIGNED_CALLERS=1` escape hatch — must NOT bypass
  /// (review v1 F1). The prior code returned a bypass string for
  /// every DEBUG build, which exposed every selector to any local
  /// peer.
  func test_bypassReason_debug_alone_does_not_bypass() {
    // `PIE_ALLOW_UNSIGNED_CALLERS` is not set in the test process env,
    // so the DEBUG branch (which the test bundle compiles under)
    // should fall through to nil.
    XCTAssertNil(ProcessInfo.processInfo.environment["PIE_ALLOW_UNSIGNED_CALLERS"],
                 "test env must not have PIE_ALLOW_UNSIGNED_CALLERS set for this assertion to be meaningful")
    // We can't drop into a non-testMode scope without mutating
    // process env (which would race other tests in the bundle); the
    // outer @TaskLocal is whatever XCTest left in place. Read the
    // value with isTestMode forced false via override:
    HelperConfig.$overrides.withValue(.init(xpcServiceName: nil,
                                            testMode: false)) {
      // Under DEBUG + no env escape: nil.
      // Under release: also nil. Either way: nil.
      XCTAssertNil(CallerIdentity.bypassReason())
    }
  }

  // MARK: - selfTeamIDResult (review v1 F11)

  /// `selfTeamIDResult` either returns a Team ID or surfaces the
  /// underlying Security failure — never silently caches nil. Ad-hoc
  /// signed dev binaries (the SwiftPM test bundle host) reliably hit
  /// the `.teamIDAbsent` branch.
  func test_selfTeamIDResult_returns_typed_failure_for_adhoc_binary() {
    // Reset the cache so a prior test that successfully populated it
    // doesn't shadow the ad-hoc-signed path under inspection.
    CallerIdentity.SelfIdentityCache._resetForTesting()
    let result = CallerIdentity.selfTeamIDResult()
    switch result {
    case .success(let team):
      XCTAssertFalse(team.isEmpty, "Team ID must be non-empty when read succeeds")
    case .failure(let err):
      // Ad-hoc signed = no Team Identifier in signing info.
      // Bundle path unreadable = securityFrameworkFailure.
      // Both are typed and surface in description; assert we got one
      // of those (not a generic nil).
      XCTAssertTrue(err == .teamIDAbsent ||
                    err.description.contains("SecStaticCodeCreateWithPath") ||
                    err.description.contains("SecCodeCopySigningInformation"),
                    "unexpected failure mode for ad-hoc binary: \(err)")
    }
  }

  /// Successful reads cache; failed reads do not (review v1 F11). A
  /// transient framework outage at first read must not poison every
  /// subsequent connection.
  func test_selfTeamIDResult_caches_only_on_success() {
    CallerIdentity.SelfIdentityCache._resetForTesting()
    let first = CallerIdentity.selfTeamIDResult()
    let cached = CallerIdentity.SelfIdentityCache.cachedTeamID
    switch first {
    case .success(let team):
      XCTAssertEqual(cached, team, "successful read must populate the cache")
    case .failure:
      XCTAssertNil(cached, "failed read must NOT populate the cache (otherwise transient outage poisons future reads)")
    }
  }

  // MARK: - verifyStartupInvariants under bypass (review v2 F1)

  /// Ad-hoc-signed DEBUG dev builds have no Team Identifier, so
  /// `selfTeamIDResult()` returns `.failure(.teamIDAbsent)`. Under the
  /// DEBUG+`PIE_ALLOW_UNSIGNED_CALLERS=1` bypass, the boot self-test
  /// must tolerate this — the prior code preconditionFailed and
  /// bricked every local DEBUG boot.
  ///
  /// The test process is already ad-hoc-signed and DEBUG-built, so
  /// we just need to flip `PIE_ALLOW_UNSIGNED_CALLERS=1` for the
  /// duration of the call. `HelperConfig.$overrides` puts us in
  /// non-test-mode so the test-mode short-circuit at the top of
  /// `verifyStartupInvariants` doesn't preempt the under-test path.
  func test_verifyStartupInvariants_tolerates_teamIDAbsent_under_bypass() throws {
    let key = "PIE_ALLOW_UNSIGNED_CALLERS"
    let prior = ProcessInfo.processInfo.environment[key]
    setenv(key, "1", 1)
    defer {
      if let prior {
        setenv(key, prior, 1)
      } else {
        unsetenv(key)
      }
    }

    // Capture state under non-test-mode + env bypass; assertions
    // below precede the verify call. Skip if the test process is
    // actually signed (CI against a notarized binary) — F1 scenario
    // requires the ad-hoc case.
    CallerIdentity.SelfIdentityCache._resetForTesting()
    var observedFailureMode: CallerIdentity.IdentityError? = nil
    var observedTeam: String? = nil
    HelperConfig.$overrides.withValue(.init(xpcServiceName: nil,
                                            testMode: false)) {
      XCTAssertEqual(CallerIdentity.bypassReason(), "DEBUG + PIE_ALLOW_UNSIGNED_CALLERS=1",
                     "test prerequisite: DEBUG+env bypass must fire here")
      switch CallerIdentity.selfTeamIDResult() {
      case .failure(let err):
        observedFailureMode = err
      case .success(let team):
        observedTeam = team
      }
    }
    if let team = observedTeam {
      throw XCTSkip("test process unexpectedly has Team ID \(team); F1 scenario not reproducible here")
    }
    guard case .teamIDAbsent = observedFailureMode else {
      throw XCTSkip("test process surfaces failure \(String(describing: observedFailureMode)); F1 scenario expects .teamIDAbsent")
    }

    // Load-bearing call: must NOT trap. Pre-fix this preconditionFailed.
    HelperConfig.$overrides.withValue(.init(xpcServiceName: nil,
                                            testMode: false)) {
      HelperXPCListener.verifyStartupInvariants()
    }
  }

  // MARK: - cross-process placeholder (review v1 F14)

  /// Cross-process subprocess RPC test. Skipped until Phase 8 wires
  /// SMAppService.loginItem registration so the test helper can
  /// publish a launchd-resolvable mach service. Tracked here so the
  /// slot exists and a future contributor doesn't forget the
  /// coverage gap.
  func test_crossProcessConnect_throughInstalledHelper() throws {
    let helperInstalled = FileManager.default.fileExists(
      atPath: "/Library/LaunchAgents/com.ratiothink.helper.plist"
    ) || ProcessInfo.processInfo.environment["PIE_HAS_INSTALLED_HELPER"] == "1"
    try XCTSkipUnless(
      helperInstalled,
      "Cross-process XPC test requires an SMAppService-installed helper (Phase 8). See review v1 F14."
    )
    // Phase 8 wires the real test body: spawn the installed helper,
    // open NSXPCConnection(machServiceName:), call engineStatus, assert
    // reply matches the helper's reported state.
  }
}
