import XCTest
@testable import RatioThinkCore

/// F2: the resident-model sync must survive a transient /v1/models
/// failure while the engine stays `.running`, instead of one-shotting and
/// stranding the composer on placeholders (the silent model-load failure
/// this PR targets).
final class EngineModelReconcilerTests: XCTestCase {

  /// Mutable, serially-accessed by the awaited reconcile — safe.
  private final class Box: @unchecked Sendable {
    var fetchCalls = 0
    var sleeps: [UInt64] = []
  }

  private struct Boom: Error {}

  func test_failsOnceThenSucceeds_whileRunning_returnsModels() async {
    let box = Box()
    let result = await EngineModelReconciler.reconcile(
      isRunning: { true },                 // status stays the same .running
      fetchModelIDs: {
        box.fetchCalls += 1
        if box.fetchCalls == 1 { throw Boom() }   // first poll fails
        return ["Qwen/Qwen3-0.6B"]                 // second succeeds
      },
      delaysMs: [0, 10, 20],
      sleep: { box.sleeps.append($0) }             // instant, recorded
    )
    XCTAssertEqual(result, .models(["Qwen/Qwen3-0.6B"]))
    XCTAssertEqual(box.fetchCalls, 2, "must retry after the transient failure")
  }

  func test_allAttemptsFail_whileRunning_reportsFailedAfterRetries() async {
    let box = Box()
    let result = await EngineModelReconciler.reconcile(
      isRunning: { true },
      fetchModelIDs: { box.fetchCalls += 1; throw Boom() },
      delaysMs: [0, 1, 2],
      sleep: { _ in }
    )
    XCTAssertEqual(result, .failedAfterRetries(attempts: 3))
    XCTAssertEqual(box.fetchCalls, 3, "must exhaust all attempts before giving up")
  }

  func test_leavesRunningMidRetry_abortsWithNotRunning() async {
    let box = Box()
    let result = await EngineModelReconciler.reconcile(
      isRunning: { box.fetchCalls < 1 },   // running for attempt 1, then not
      fetchModelIDs: { box.fetchCalls += 1; throw Boom() },
      delaysMs: [0, 5, 5],
      sleep: { _ in }
    )
    XCTAssertEqual(result, .notRunning, "a dying engine must abort the retry, not keep polling")
  }

  func test_notRunningUpFront_returnsNotRunning_withoutFetching() async {
    let box = Box()
    let result = await EngineModelReconciler.reconcile(
      isRunning: { false },
      fetchModelIDs: { box.fetchCalls += 1; return ["x"] },
      delaysMs: [0],
      sleep: { _ in }
    )
    XCTAssertEqual(result, .notRunning)
    XCTAssertEqual(box.fetchCalls, 0, "must not fetch when the engine isn't running")
  }

  func test_runningButNoModels_returnsEmpty_noRetry() async {
    let box = Box()
    let result = await EngineModelReconciler.reconcile(
      isRunning: { true },
      fetchModelIDs: { box.fetchCalls += 1; return ["", "  "] },  // filtered to empty
      delaysMs: [0, 5, 5],
      sleep: { _ in }
    )
    XCTAssertEqual(result, .empty, "no advertised models is terminal, not a retryable error")
    XCTAssertEqual(box.fetchCalls, 1, "empty list must not trigger retries")
  }

  // MARK: - F2: toolbar list state (no placeholders for known states)

  private let fallback = ["placeholder-A", "placeholder-B"]

  func test_toolbar_unknown_usesFallback_onlyBeforeFirstFetch() {
    XCTAssertEqual(ToolbarModelList.unknown.resolved(fallback: fallback), fallback)
  }

  func test_toolbar_empty_offersNoPlaceholders() {
    let next = ToolbarModelList.from(.empty, previous: .unknown)
    XCTAssertEqual(next, .known([]))
    XCTAssertEqual(next.resolved(fallback: fallback), [],
                   "a running engine that serves no models must NOT fall back to placeholders")
  }

  func test_toolbar_notRunning_offersNoPlaceholders() {
    let next = ToolbarModelList.from(.notRunning, previous: .known(["x"]))
    XCTAssertEqual(next, .known([]))
    XCTAssertEqual(next.resolved(fallback: fallback), [],
                   "a not-running engine must NOT re-surface placeholders")
  }

  func test_toolbar_models_setsKnownList() {
    let next = ToolbarModelList.from(.models(["Qwen/Qwen3-0.6B"]), previous: .unknown)
    XCTAssertEqual(next.resolved(fallback: fallback), ["Qwen/Qwen3-0.6B"])
  }

  func test_toolbar_failedAfterRetries_keepsPriorKnown_elseEmpty() {
    // keep a prior known list rather than regressing to placeholders
    XCTAssertEqual(ToolbarModelList.from(.failedAfterRetries(attempts: 3),
                                         previous: .known(["A"])), .known(["A"]))
    // no prior knowledge → empty, still not placeholders
    let noPrior = ToolbarModelList.from(.failedAfterRetries(attempts: 3), previous: .unknown)
    XCTAssertEqual(noPrior, .known([]))
    XCTAssertEqual(noPrior.resolved(fallback: fallback), [])
  }

  func test_firstAttemptSucceeds_noSleep() async {
    let box = Box()
    let result = await EngineModelReconciler.reconcile(
      isRunning: { true },
      fetchModelIDs: { ["A", "B"] },
      delaysMs: [0, 999],
      sleep: { box.sleeps.append($0) }
    )
    XCTAssertEqual(result, .models(["A", "B"]))
    XCTAssertTrue(box.sleeps.isEmpty, "a first-attempt success must not back off")
  }
}
