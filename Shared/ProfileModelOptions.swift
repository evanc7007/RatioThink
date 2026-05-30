import Foundation

/// Pure option-list builder for the *Settings → Profiles* model picker
///. The picker offers installed GGUF models but must always
/// include the profile's current model so the displayed value is never
/// silently dropped when that model isn't installed (yet / anymore).
public enum ProfileModelOptions {
  /// Installed filenames unioned with `current` (when non-empty),
  /// deduplicated and sorted ascending.
  public static func merge(installed: [String], current: String) -> [String] {
    var set = Set(installed)
    if !current.isEmpty { set.insert(current) }
    return set.sorted()
  }
}
