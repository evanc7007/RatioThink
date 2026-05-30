import Foundation

/// Bounded retry of the `/v1/models` fetch the chat surface uses to learn
/// which model the engine actually serves.
///
/// **Why this exists (, F2):** the resident-model sync used to be a
/// one-shot `.task(id: engineStatusStore.status)`. A SINGLE transient
/// `/v1/models` failure right after the engine reached `.running` was
/// swallowed and the code "waited for the next status flip" — but equal
/// `.running` polls do not republish a new status, so the retry might
/// never come. `residentModelID` stayed unset and the composer fell back
/// to placeholders — exactly the silent model-load failure this work
/// targets. So: retry on a bounded schedule WHILE the engine stays
/// running, and bail immediately if it leaves `.running`.
///
/// Pure + closure-injected so it is unit-testable without a live engine
/// or real delays.
public enum EngineModelReconciler {
  public enum Result: Equatable, Sendable {
    /// Engine served these ids (non-empty). The first is the resident id.
    case models([String])
    /// Engine is running but advertises no models — terminal, not a
    /// transient error; no point retrying.
    case empty
    /// Engine left `.running` before a successful fetch — caller should
    /// clear any stale served list.
    case notRunning
    /// Every attempt failed while the engine stayed running. Caller
    /// should log this (do NOT silently drop) and leave prior state.
    case failedAfterRetries(attempts: Int)
  }

  /// Default backoff schedule: 5 attempts over ~5.5s. First attempt is
  /// immediate; the rest back off.
  public static let defaultDelaysMs: [UInt64] = [0, 300, 700, 1500, 3000]

  public static func reconcile(
    isRunning: @MainActor () -> Bool,
    fetchModelIDs: @MainActor () async throws -> [String],
    delaysMs: [UInt64] = defaultDelaysMs,
    sleep: @Sendable (UInt64) async -> Void = { ms in
      try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }
  ) async -> Result {
    guard await isRunning() else { return .notRunning }
    for (attempt, delay) in delaysMs.enumerated() {
      if delay > 0 { await sleep(delay) }
      // Re-check between attempts: a dying engine must abort the retry.
      guard await isRunning() else { return .notRunning }
      do {
        let ids = try await fetchModelIDs()
          .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ids.isEmpty ? .empty : .models(ids)
      } catch {
        if attempt == delaysMs.count - 1 {
          return .failedAfterRetries(attempts: delaysMs.count)
        }
        // else: transient — back off and retry while still running.
      }
    }
    return .failedAfterRetries(attempts: delaysMs.count)
  }
}

/// What the chat toolbar's model menu should offer, derived from the
/// reconcile result.
///
/// **Why an enum, not `[String]?` (F2):** `nil`-means-fallback conflated
/// two very different situations — "haven't fetched yet" (legit to show
/// the injected/preview list) and "the engine told us it serves no /
/// these models" (must NOT fall back to static placeholders the engine
/// will reject). `.unknown` is reserved for the initial/previews path;
/// once any reconcile has run, the list is `.known(...)` — possibly
/// empty — so a verified empty/not-running/unreachable engine never
/// re-surfaces placeholder choices.
public enum ToolbarModelList: Equatable, Sendable {
  /// No fetch has completed yet — show the caller's injected fallback
  /// (previews/tests/first paint).
  case unknown
  /// The engine's real served ids (possibly empty = serves nothing).
  case known([String])

  /// Effective list for the toolbar: fallback only while `.unknown`.
  public func resolved(fallback: [String]) -> [String] {
    switch self {
    case .unknown:        return fallback
    case .known(let ids): return ids
    }
  }

  /// Fold a reconcile result into the next toolbar state. Placeholders
  /// (`.unknown`/fallback) are only ever shown before the first fetch:
  /// every post-fetch outcome resolves to `.known`, and a transient
  /// `.failedAfterRetries` keeps a prior known list rather than
  /// regressing to placeholders.
  public static func from(_ result: EngineModelReconciler.Result,
                          previous: ToolbarModelList) -> ToolbarModelList {
    switch result {
    case .models(let ids):      return .known(ids)
    case .empty, .notRunning:   return .known([])
    case .failedAfterRetries:
      if case .known = previous { return previous }
      return .known([])
    }
  }
}
