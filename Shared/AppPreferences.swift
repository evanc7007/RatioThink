import Foundation
import Combine
import os

/// User preferences that persist across app launches but are NOT part
/// of the engine config (`<PIE_HOME>/config.toml` is owned by the
/// engine launcher — see `PieControlLauncher`). Lives in
/// `UserDefaults` so macOS handles atomic writes, multi-process
/// coalescing, and `defaults read` debugging for free.
///
/// `final` + `@MainActor` so SwiftUI views can observe `@Published`
/// mutations without main-actor warnings. Tests inject a scratch
/// `UserDefaults(suiteName:)` via init to keep the process defaults
/// clean.
///
///  removed the per-model "don't ask again" swap skip-set: every
/// model load now always shows the confirm, so there is no silent-load
/// path to remember. The only surviving entry is the first-launch
/// completion flag.
@MainActor
public final class AppPreferences: ObservableObject {
  /// Storage key flipped after the first-launch wizard completes.
  public static let firstLaunchWizardCompletedKey = "firstLaunchWizardCompleted"

  private let defaults: UserDefaults

  @Published public private(set) var firstLaunchWizardCompleted: Bool

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.firstLaunchWizardCompleted = defaults.bool(forKey: Self.firstLaunchWizardCompletedKey)
  }

  /// Mark the first-launch wizard complete.  reduced the
  /// wizard to required helper/menu-bar setup + orientation; model
  /// choice moved to Settings → Models, so completion is a single flag
  /// and never claims a default model.
  public func completeFirstLaunch() {
    firstLaunchWizardCompleted = true
    defaults.set(true, forKey: Self.firstLaunchWizardCompletedKey)
    // Force the one-shot completion flag to disk now. The user can quit
    // immediately after finishing the wizard; without an explicit flush
    // the suite write can be lost on an abrupt termination and the
    // wizard would wrongly reappear on the next launch.
    defaults.synchronize()
  }

  /// Test/developer reset hook used by GUI scenarios and future
  /// Settings affordances. Clears the completion flag so the next app
  /// launch behaves like a fresh install.
  public func resetFirstLaunchWizard() {
    firstLaunchWizardCompleted = false
    defaults.removeObject(forKey: Self.firstLaunchWizardCompletedKey)
  }
}
