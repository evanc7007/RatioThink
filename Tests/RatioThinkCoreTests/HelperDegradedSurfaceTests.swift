import XCTest
import os
@testable import RatioThinkCore

/// Pin the F32 invariant: `setReason` MUST fire BEFORE the test-mode
/// short-circuit. A future refactor that moves the assignment inside
/// the AppKit branch would silently regress F8 without this signal.
final class HelperDegradedSurfaceTests: XCTestCase {

  func test_synthesizeReason_wrapsInUnknown() {
    let err = HelperDegradedSurface.synthesizeReason("post-resume ping failed")
    guard case let .unknown(underlying) = err else {
      return XCTFail("expected .unknown, got \(err)")
    }
    XCTAssertTrue(underlying.contains("post-resume ping failed"))
  }

  func test_apply_underTestMode_setsReasonAndSkipsAppKit() {
    let reasonLock = OSAllocatedUnfairLock<PieDirsError?>(initialState: nil)
    let clearedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    let degradedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    let alertedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    let surface = HelperDegradedSurface(
      setReason: { err in reasonLock.withLock { $0 = err } },
      clearHealthyStatusItem: { clearedLock.withLock { $0 = true } },
      presentDegradedStatusItem: { degradedLock.withLock { $0 = true } },
      presentAlert: { _ in alertedLock.withLock { $0 = true } },
      isTestMode: { true }
    )
    surface.apply(reason: "mach service ping timed out")
    let captured = reasonLock.withLock { $0 }
    guard case let .unknown(underlying)? = captured else {
      return XCTFail("expected .unknown reason set, got \(String(describing: captured))")
    }
    XCTAssertTrue(underlying.contains("mach service ping timed out"))
    XCTAssertFalse(clearedLock.withLock { $0 }, "AppKit side effects must not run under test mode")
    XCTAssertFalse(degradedLock.withLock { $0 }, "AppKit side effects must not run under test mode")
    XCTAssertFalse(alertedLock.withLock { $0 }, "AppKit side effects must not run under test mode")
  }

  func test_apply_outsideTestMode_runsAllSideEffectsInOrder() {
    let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    let surface = HelperDegradedSurface(
      setReason: { _ in events.withLock { $0.append("setReason") } },
      clearHealthyStatusItem: { events.withLock { $0.append("clearHealthy") } },
      presentDegradedStatusItem: { events.withLock { $0.append("presentDegraded") } },
      presentAlert: { _ in events.withLock { $0.append("presentAlert") } },
      isTestMode: { false }
    )
    surface.apply(reason: "boom")
    XCTAssertEqual(events.withLock { $0 },
                   ["setReason", "clearHealthy", "presentDegraded", "presentAlert"])
  }
}
