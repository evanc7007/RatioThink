import Foundation
import os

/// Side-effect-free shape of the runtime-degraded transition the
/// helper performs after a successful post-resume XPC swap (review v2
/// F32, v1 F8). Extracted from `HelperAppDelegate.surfaceRuntimeDegraded`
/// so the state-mutation half can be unit-tested independently of
/// AppKit — the prior inlined version had no test signal at all,
/// which the F32 finding called out.
///
/// `apply(reason:)` performs the steps in a fixed order:
///   1. Synthesize a `PieDirsError` from the raw reason string.
///   2. Invoke `setReason` (always — even under test mode) so the
///      sticky `degradedReason` ivar reflects the degraded state.
///   3. If `isTestMode` returns true, return — production helpers
///      under PIE_TEST_MODE=1 must not touch NSStatusBar / NSAlert.
///   4. Otherwise, swap the status item and present the alert via
///      the injected closures.
///
/// Idempotence is the caller's responsibility (the helper guards
/// `degradedReason != nil` before calling `apply`).
public struct HelperDegradedSurface: Sendable {
  public var setReason: @Sendable (PieDirsError) -> Void
  public var clearHealthyStatusItem: @Sendable () -> Void
  public var presentDegradedStatusItem: @Sendable () -> Void
  public var presentAlert: @Sendable (PieDirsError) -> Void
  public var isTestMode: @Sendable () -> Bool

  public init(setReason: @escaping @Sendable (PieDirsError) -> Void,
              clearHealthyStatusItem: @escaping @Sendable () -> Void,
              presentDegradedStatusItem: @escaping @Sendable () -> Void,
              presentAlert: @escaping @Sendable (PieDirsError) -> Void,
              isTestMode: @escaping @Sendable () -> Bool) {
    self.setReason = setReason
    self.clearHealthyStatusItem = clearHealthyStatusItem
    self.presentDegradedStatusItem = presentDegradedStatusItem
    self.presentAlert = presentAlert
    self.isTestMode = isTestMode
  }

  /// Map a free-form reason string into the synthetic
  /// `PieDirsError.unknown` shape the rest of the helper expects.
  /// Pure function so tests can assert the mapping without an
  /// instance.
  public static func synthesizeReason(_ message: String) -> PieDirsError {
    .unknown(underlying: message)
  }

  /// Apply the transition. `setReason` ALWAYS fires before the
  /// test-mode short-circuit (review v2 F32) — a future refactor
  /// that moves the assignment inside the AppKit branch is exactly
  /// the regression `HelperDegradedSurfaceTests` locks down.
  public func apply(reason: String) {
    let synthetic = Self.synthesizeReason(reason)
    setReason(synthetic)
    if isTestMode() {
      Log.helper.error("HelperDegradedSurface.apply suppressed under PIE_TEST_MODE=1 reason=\(reason, privacy: .public)")
      return
    }
    clearHealthyStatusItem()
    presentDegradedStatusItem()
    presentAlert(synthetic)
  }
}
