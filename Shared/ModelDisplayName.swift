import Foundation

/// Friendly display labels for model identifiers ( review v2 F1).
///
/// A model's stored identity is the resolvable `<repo>/<file>` slug
/// (e.g. `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf`) — the form
/// `ModelDownloader` writes and `LaunchSpecResolver.joinModelPath`
/// resolves. UI must render a friendly name instead of that raw slug:
/// the leaf (last path component). Bare names pass through unchanged.
public enum ModelDisplayName {
  public static func leaf(_ id: String) -> String {
    id.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? id
  }
}
