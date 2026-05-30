import Foundation

/// Closure-injection seam between `HelperStatusItemModel` and the
/// AppKit `NSStatusItem` HelperMain owns. Lives in RatioThinkCore so
/// RatioThinkCoreTests can drive a sequence of model snapshots into the
/// binding and verify the exact setter calls without instantiating
/// `NSStatusBar`. Matches `HelperDegradedSurface`'s pattern.
///
/// The binding is intentionally dumb: every model field maps to one
/// closure call, no AppKit branching, no state retained here. The
/// view (HelperMain) owns the `NSImage` + `NSColor` decisions; the
/// binding just hands it the pure values it needs.
///
/// Ordering contract (locked by `HelperStatusItemBindingTests`):
///   1. setDot
///   2. setEngineLabel
///   3. setPauseResumeTitle
///   4. setPauseResumeAction
///   5. setPauseResumeEnabled
///
/// `setPauseResumeAction` MUST fire BEFORE `setPauseResumeEnabled`
/// (review v1 F5). Otherwise a `(.resume, enabled=false) →
/// (.pause, enabled=true)` transition walks through
/// `(.resume, enabled=true)` for one main-thread tick: a click
/// landing in that single-tick window would invoke `.resume` on a
/// running engine. By setting the action first, the menu item is
/// never `enabled=true` carrying a stale action.
///
/// A change in order breaks a reader assertion. Reorder ONLY with a
/// matching test update — out-of-order setters can produce a frame
/// where (title="Pause Engine", enabled=false, action=.resume) is
/// briefly visible to AppKit's accessibility tree.
public struct HelperStatusItemBinding: Sendable {
  public var setDot: @Sendable (HelperStatusItemModel.Dot) -> Void
  public var setEngineLabel: @Sendable (String) -> Void
  public var setPauseResumeTitle: @Sendable (String) -> Void
  public var setPauseResumeEnabled: @Sendable (Bool) -> Void
  public var setPauseResumeAction: @Sendable (HelperStatusItemModel.PauseResume.Action) -> Void

  public init(
    setDot: @escaping @Sendable (HelperStatusItemModel.Dot) -> Void,
    setEngineLabel: @escaping @Sendable (String) -> Void,
    setPauseResumeTitle: @escaping @Sendable (String) -> Void,
    setPauseResumeEnabled: @escaping @Sendable (Bool) -> Void,
    setPauseResumeAction: @escaping @Sendable (HelperStatusItemModel.PauseResume.Action) -> Void
  ) {
    self.setDot = setDot
    self.setEngineLabel = setEngineLabel
    self.setPauseResumeTitle = setPauseResumeTitle
    self.setPauseResumeEnabled = setPauseResumeEnabled
    self.setPauseResumeAction = setPauseResumeAction
  }

  /// Apply one model snapshot. Setters fire in the documented order.
  /// `setPauseResumeAction` precedes `setPauseResumeEnabled` so the
  /// menu item is never enabled while carrying a stale action
  /// (review v1 F5).
  public func apply(_ model: HelperStatusItemModel) {
    setDot(model.dot)
    setEngineLabel(model.engineLabel)
    setPauseResumeTitle(model.pauseResume.title)
    setPauseResumeAction(model.pauseResume.action)
    setPauseResumeEnabled(model.pauseResume.enabled)
  }
}
