import XCTest
import os
@testable import RatioThinkCore

/// Locks the queue / defer / test-mode branch logic of the helper's
/// high-priority alert gate (review v4 F31). The AppKit side
/// (NSPanel / NSAlert) is HelperMain's job; this suite proves the
/// rules HelperMain dispatches on are correct.
final class HighPriorityAlertGateTests: XCTestCase {

  // MARK: (a) no sheet in flight → .presented

  func test_decide_noSheet_notTestMode_presentsImmediately() {
    XCTAssertEqual(
      HighPriorityAlertGate.decide(sheetInFlight: false, isTestMode: false),
      .presented
    )
  }

  // MARK: (b) sheet in flight → .enqueued

  func test_decide_sheetInFlight_notTestMode_enqueues() {
    XCTAssertEqual(
      HighPriorityAlertGate.decide(sheetInFlight: true, isTestMode: false),
      .enqueued
    )
  }

  // MARK: (c) test mode → .testModeSuppressed (regardless of sheet)

  func test_decide_testMode_suppresses_regardlessOfSheet() {
    XCTAssertEqual(
      HighPriorityAlertGate.decide(sheetInFlight: false, isTestMode: true),
      .testModeSuppressed
    )
    XCTAssertEqual(
      HighPriorityAlertGate.decide(sheetInFlight: true, isTestMode: true),
      .testModeSuppressed
    )
  }

  // MARK: (d) drain simulation — deferred payload presents exactly once

  /// Stand-in for HelperMain's `deferredHighPriorityAlert` slot +
  /// `sheetHostPanel != nil` flag. Drives the same state machine
  /// the production code does so the drain ordering is exercised.
  private final class FakeAlertSurface {
    private(set) var presented: [String] = []
    private(set) var sheetInFlight: Bool = false
    private var deferred: (title: String, text: String)?

    /// Mirrors `presentHighPriorityAlert`. On `.presented`, opens
    /// a sheet; on `.enqueued`, stores in the deferred slot.
    func submit(title: String, text: String) {
      switch HighPriorityAlertGate.decide(sheetInFlight: sheetInFlight, isTestMode: false) {
      case .presented:
        sheetInFlight = true
        presented.append(title)
      case .enqueued:
        deferred = (title, text)
      case .testModeSuppressed:
        XCTFail("test-mode unexpectedly returned")
      }
    }

    /// Mirrors the `beginSheetModal` completion handler's drain.
    func completeInFlightSheet() {
      sheetInFlight = false
      if let pending = deferred {
        deferred = nil
        // Re-enter via the same entry point — equivalent to
        // HelperMain's review v4 F29 fix that routes the drain
        // through presentHighPriorityAlert (not presentAlert).
        submit(title: pending.title, text: pending.text)
      }
    }
  }

  func test_drain_presentsDeferredExactlyOnce_afterCompletion() {
    let surface = FakeAlertSurface()
    surface.submit(title: "first", text: "f")
    XCTAssertEqual(surface.presented, ["first"])
    XCTAssertTrue(surface.sheetInFlight)

    // Second arrives while first sheet is up → enqueued.
    surface.submit(title: "second", text: "s")
    XCTAssertEqual(surface.presented, ["first"], "second must not present while first is up")

    // First sheet completes → drain enqueued second.
    surface.completeInFlightSheet()
    XCTAssertEqual(surface.presented, ["first", "second"])
    XCTAssertTrue(surface.sheetInFlight, "drained second is now in flight")

    // Second sheet completes → no further drains; queue empty.
    surface.completeInFlightSheet()
    XCTAssertEqual(surface.presented, ["first", "second"], "no spurious extra presents")
    XCTAssertFalse(surface.sheetInFlight)
  }

  /// Eviction case from review v4 F30: two enqueued alerts collapse
  /// to the latest-wins payload. The fake mirrors the production
  /// semantics — single-slot, last submission wins.
  func test_drain_evictsToLatest_whenTwoEnqueuedWhileSheetInFlight() {
    let surface = FakeAlertSurface()
    surface.submit(title: "blocker", text: "b")
    XCTAssertTrue(surface.sheetInFlight)

    surface.submit(title: "stale", text: "x")
    surface.submit(title: "fresh", text: "y")  // evicts "stale"

    surface.completeInFlightSheet()
    XCTAssertEqual(surface.presented, ["blocker", "fresh"],
                   "latest-wins eviction must surface only the most recent enqueued alert")
  }
}
