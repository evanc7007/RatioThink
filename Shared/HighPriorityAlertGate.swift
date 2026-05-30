import Foundation

/// Pure decision function for the helper's high-priority alert
/// queue (review v3 F25 + review v4 F31). Extracted into RatioThinkCore so
/// the queue/defer/test-mode branch logic is unit-testable in
/// RatioThinkCoreTests without instantiating `NSPanel` / `NSAlert`.
///
/// HelperMain owns the AppKit side; this type owns the rules.
public enum HighPriorityAlertGate {
  public enum Decision: Equatable, Sendable {
    /// No sheet in flight and not in test mode — caller presents
    /// the alert immediately.
    case presented
    /// A sheet is in flight; caller stores the payload in the
    /// single-slot deferred-alert ivar. The drain in
    /// `beginSheetModal`'s completion handler will re-enter the
    /// gate after clearing `sheetHostPanel`.
    case enqueued
    /// `PIE_TEST_MODE=1` — caller logs and drops. Production
    /// helpers never hit this branch because the test-mode short-
    /// circuit fires before any of setupStatusItem /
    /// setupDegradedStatusItem / presentAlert paths run.
    case testModeSuppressed
  }

  /// Single source of truth for "given the current sheet + test-mode
  /// state, what should the caller do." Order matters: test mode
  /// wins over sheet-in-flight, because a test-mode helper has no
  /// runloop to drain the queue.
  public static func decide(sheetInFlight: Bool, isTestMode: Bool) -> Decision {
    if isTestMode { return .testModeSuppressed }
    if sheetInFlight { return .enqueued }
    return .presented
  }
}
