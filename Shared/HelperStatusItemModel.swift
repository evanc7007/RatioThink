import Foundation

/// Pure-data projection of `EngineStatus` onto the helper menu-bar
/// status item. Lives in RatioThinkCore (no AppKit) so RatioThinkCoreTests can pin
/// the state→UI mapping without instantiating an `NSStatusBar` —
/// matches the `HelperDegradedSurface` testability pattern.
///
/// The view (HelperMain) renders the model into AppKit:
///   · `dot` → SF Symbol name + tint color
///   · `engineLabel` → disabled menu item title (the
///     "current model/profile/port" slot from Phase 2.3)
///   · `pauseResume.{title,enabled,action}` → toggle menu item
///
/// Degraded mode is NOT modeled here. `setupStatusItemIfNeeded` keeps
/// its existing `degradedReason != nil → setupDegradedStatusItem`
/// short-circuit so a helper that cannot reach its state directory
/// never publishes a green dot through the supervisor pipeline.
public struct HelperStatusItemModel: Equatable, Sendable {

  /// Semantic dot state. View layer maps to SF Symbol + tint.
  public enum Dot: String, Equatable, Sendable {
    /// Gray outline circle. Supervisor is `.stopped`.
    case stopped
    /// Amber filled circle. Supervisor is `.starting` or `.stopping`
    /// — transitional, not yet steady-state.
    case loading
    /// Green filled circle. Supervisor is `.running`.
    case running
    /// Red filled circle (or triangle, view's choice). Supervisor is
    /// `.failed`.
    case error
  }

  /// Pause/Resume toggle. The supervisor has one canonical
  /// transition pair — `.start(spec)` and `.stop()` — so the menu
  /// item morphs label + action based on which one is meaningful in
  /// the current state.
  public struct PauseResume: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
      /// Calls `supervisor.stop()`.
      case pause
      /// Calls `supervisor.start(spec)`. Disabled until 
      /// wires `ProfileStore` into `HelperExportedAPI` — the helper
      /// has no LaunchSpec resolver yet, so a "Resume" with no
      /// profile would silently no-op.
      case resume
      /// Transitional state (e.g. `.stopping`) — nothing to do.
      case none
    }
    public var title: String
    public var enabled: Bool
    public var action: Action
  }

  public var dot: Dot
  /// Single disabled label that absorbs "Engine: stopped" plus the
  /// Phase 2.3 "current model/profile/port" slot. Folded into one
  /// item so the S4 GUI test's `Engine: stopped` assertion keeps
  /// holding; running state appends profile + port.
  public var engineLabel: String
  public var pauseResume: PauseResume

  public init(dot: Dot, engineLabel: String, pauseResume: PauseResume) {
    self.dot = dot
    self.engineLabel = engineLabel
    self.pauseResume = pauseResume
  }

  /// Build the model from a live `EngineStatus`. Pure function — no
  /// AppKit, no logging side effects.
  public static func make(from status: EngineStatus) -> HelperStatusItemModel {
    switch status {
    case .stopped:
      return HelperStatusItemModel(
        dot: .stopped,
        engineLabel: "Engine: stopped",
        // ProfileStore + LaunchSpec resolver are now wired,
        // so Resume is actionable: HelperResumeAction.run resolves the
        // active profile and starts the engine. It is internally
        // nil-safe (returns .resolverMissing / .noActiveProfile and logs
        // rather than crashing) on a degraded boot, so enabling here
        // cannot fire into a nil resolver. Leaving it disabled stranded
        // the engine "stopped" with no way to start it, so every model
        // load deferred forever on engineNotReady ( follow-up).
        pauseResume: PauseResume(title: "Resume Engine",
                                 enabled: true,
                                 action: .resume)
      )
    case .starting:
      return HelperStatusItemModel(
        dot: .loading,
        engineLabel: "Engine: starting…",
        pauseResume: PauseResume(title: "Pause Engine",
                                 enabled: true,
                                 action: .pause)
      )
    case .running(let port, let profileID):
      return HelperStatusItemModel(
        dot: .running,
        engineLabel: "Engine: running — \(profileID) @ port \(port)",
        pauseResume: PauseResume(title: "Pause Engine",
                                 enabled: true,
                                 action: .pause)
      )
    case .stopping:
      return HelperStatusItemModel(
        dot: .loading,
        engineLabel: "Engine: stopping…",
        pauseResume: PauseResume(title: "Pause Engine",
                                 enabled: false,
                                 action: .none)
      )
    case .failed(let code, let message):
      // Truncate the message at a UI-sane width — full diagnostic is
      // in `helper.log` / `engine.log`. The wire format already caps
      // payload at `EngineStatus.failedMessageCap` (1 KiB), so this
      // is a second, narrower cap for menu-item rendering.
      let trimmed = HelperStatusItemModel.truncate(message, to: 120)
      return HelperStatusItemModel(
        dot: .error,
        engineLabel: "Engine: failed (\(code.rawValue)) — \(trimmed)",
        // Resume is enabled for recoverable failures so the user can fix
        // the underlying cause (e.g. download a `modelMissing` model)
        // and retry, instead of being stranded with the engine failed.
        // `memoryRisk` / `killRejected` stay disabled — a blind retry of
        // the same action re-fails or is unsafe (see
        // `EngineErrorCode.invitesResumeRetry` + test_memoryRiskFailure).
        pauseResume: PauseResume(title: "Resume Engine",
                                 enabled: code.invitesResumeRetry,
                                 action: .resume)
      )
    }
  }

  /// Bounded-width truncation for menu-item labels. Walks character
  /// boundaries so a multi-byte glyph never gets sliced in half.
  static func truncate(_ s: String, to maxChars: Int) -> String {
    guard s.count > maxChars else { return s }
    let prefix = s.prefix(maxChars)
    return prefix + "…"
  }
}
