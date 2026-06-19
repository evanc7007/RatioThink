import XCTest
@testable import RatioThinkCore

/// Unit tests for `ModelDownloadController`. The producer is faked
/// via `AsyncStream<DownloadProgress>`; we drive `_testOnly_apply` /
/// `_testOnly_consume` so the test does not need to stand up a real
/// `ModelDownloader`.
@MainActor
final class ModelDownloadControllerTests: XCTestCase {

  // MARK: -  F1: verification is carried onto the completed entry

  // The Models-tab row branches its `.completed` badge on
  // `entry.progress.verification` (green "Done" only for `.verified`;
  // orange "Unverified" otherwise). These pin the controller-side
  // contract that the verification status survives onto the terminal
  // entry so the view can read it.

  func test_completed_notAdvertised_is_carried_onto_entry_for_unverified_badge() {
    let controller = ModelDownloadController()
    let handle = DownloadHandle(repo: "owner/repo", file: "model.gguf")
    let progress = DownloadProgress(
      handleID: handle.id,
      phase: .completed,
      bytesReceived: 200,
      bytesExpected: 200,
      etaSeconds: nil,
      verification: .notAdvertised
    )
    controller._testOnly_apply(progress, handle: handle)
    let entry = controller.active[handle.id]
    XCTAssertEqual(entry?.progress.phase, .completed)
    XCTAssertEqual(entry?.progress.verification, .notAdvertised,
                   "a skipped sha256 check must reach the row so it renders Unverified, not green Done")
  }

  func test_completed_verified_is_carried_onto_entry_for_done_badge() {
    let controller = ModelDownloadController()
    let handle = DownloadHandle(repo: "owner/repo", file: "model.gguf")
    let progress = DownloadProgress(
      handleID: handle.id,
      phase: .completed,
      bytesReceived: 200,
      bytesExpected: 200,
      etaSeconds: nil,
      verification: .verified
    )
    controller._testOnly_apply(progress, handle: handle)
    XCTAssertEqual(controller.active[handle.id]?.progress.verification, .verified)
  }

  // MARK: - F24: failureReason flows through

  func test_failed_phase_promotes_producer_reason_to_entry_error_message() {
    let controller = ModelDownloadController()
    let handle = DownloadHandle(repo: "owner/repo", file: "model.gguf")
    let progress = DownloadProgress(
      handleID: handle.id,
      phase: .failed,
      bytesReceived: 100,
      bytesExpected: 200,
      etaSeconds: nil,
      verification: .notApplicable,
      failureReason: ".sha256Mismatch(expected: abc, actual: def)"
    )
    controller._testOnly_apply(progress, handle: handle)

    let entry = controller.active[handle.id]
    XCTAssertEqual(entry?.errorMessage,
                   ".sha256Mismatch(expected: abc, actual: def)",
                   "controller must surface the producer's `failureReason` verbatim, not a generic 'download failed'")
  }

  func test_failed_phase_without_reason_falls_back_to_explicit_placeholder() {
    let controller = ModelDownloadController()
    let handle = DownloadHandle(repo: "x/y", file: "m.gguf")
    let progress = DownloadProgress(
      handleID: handle.id,
      phase: .failed,
      bytesReceived: 0,
      bytesExpected: nil,
      etaSeconds: nil,
      verification: .notApplicable,
      failureReason: nil
    )
    controller._testOnly_apply(progress, handle: handle)
    XCTAssertNotNil(controller.active[handle.id]?.errorMessage,
                    "fallback message must still be populated so the row never renders without a reason")
  }

  // MARK: - F25: stream-end without terminal synthesises .failed

  func test_consume_synthesizes_failed_when_stream_closes_without_terminal_phase() async {
    let controller = ModelDownloadController(terminalRowLingerSeconds: 60)
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    let (stream, continuation) = AsyncStream<DownloadProgress>.makeStream()
    // Emit a non-terminal progress then close the stream — mimics an
    // XPC disconnect / `downloader.invalidate()`.
    continuation.yield(DownloadProgress(
      handleID: handle.id,
      phase: .downloading,
      bytesReceived: 10,
      bytesExpected: 100,
      etaSeconds: nil
    ))
    continuation.finish()

    await controller._testOnly_consume(stream: stream, handle: handle)

    let entry = controller.active[handle.id]
    XCTAssertNotNil(entry, "the row should still exist immediately after consume returns (linger > 0)")
    XCTAssertEqual(entry?.progress.phase, .failed,
                   "consume must synthesize a terminal .failed on stream-end so the row is not stranded as `.downloading`")
    XCTAssertEqual(entry?.progress.failureReason,
                   "stream closed before producer emitted a terminal phase")
    XCTAssertEqual(entry?.errorMessage,
                   "stream closed before producer emitted a terminal phase",
                   "synthesised reason must be promoted to the UI-facing errorMessage")
  }

  // MARK: - F31 / F33: cancel race short-circuit + cancel-error path

  func test_cancel_error_promoted_to_entry_and_last_error() async {
    let stub = StubDownloader()
    stub.nextCancelError = .writeFailed(message: "disk full", cause: nil)
    // Linger 0s so eviction fires near-immediately for the F37 assert.
    let controller = ModelDownloadController(downloader: stub,
                                              terminalRowLingerSeconds: 0)
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    // Seed an entry via apply() — bypasses start() so we don't have
    // to wire a producer-side AsyncStream for this cancel-only test.
    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .downloading,
                       bytesReceived: 10,
                       bytesExpected: 100,
                       etaSeconds: nil),
      handle: handle)

    controller.cancel(id: handle.id)

    XCTAssertEqual(stub.cancelInvocations, 1, "downloader.cancel must be called exactly once")
    XCTAssertNotNil(controller.active[handle.id]?.errorMessage,
                    "review v3 F23: a real cancel failure must populate entry.errorMessage so the Cancel button is not visually silent")
    XCTAssertTrue(controller.active[handle.id]?.errorMessage?.contains("cancel failed") ?? false,
                  "the entry's errorMessage must carry the 'cancel failed' prefix")
    XCTAssertNotNil(controller.lastError,
                    "review v3 F23: a real cancel failure must populate lastError so the Downloads section red caption renders")

    // F37: row must transition to a terminal phase so the Cancel
    // button stops rendering and `isTerminal` flips. Pre-fix the
    // row was stuck on `.downloading` with `errorMessage` set —
    // user could re-click Cancel into the same failure indefinitely.
    XCTAssertEqual(controller.active[handle.id]?.progress.phase, .failed,
                   "review v5 F37: a real cancel failure must synthesize a terminal .failed so the row is no longer Cancel-eligible")
    XCTAssertEqual(controller.active[handle.id]?.isTerminal, true,
                   "isTerminal must be true after a real cancel failure")

    // #722: terminal failures no longer auto-evict; the row must remain
    // visible so the user can retry or dismiss it.
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertNotNil(controller.active[handle.id],
                    "failed rows must remain visible for Retry/Dismiss instead of auto-evicting")
  }

  func test_cancel_unknownHandle_short_circuits_no_error_state_written() {
    let stub = StubDownloader()
    stub.nextCancelError = .unknownHandle
    let controller = ModelDownloadController(downloader: stub)
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .downloading,
                       bytesReceived: 10,
                       bytesExpected: 100,
                       etaSeconds: nil),
      handle: handle)

    controller.cancel(id: handle.id)

    XCTAssertNil(controller.active[handle.id]?.errorMessage,
                 "review v4 F31: .unknownHandle is a producer-already-terminated race, not a real failure — must NOT mark the row as failed")
    XCTAssertNil(controller.lastError,
                 "review v4 F31: race short-circuit must NOT populate lastError")
  }

  func test_cancel_cancelled_race_short_circuits_no_error_state_written() {
    let stub = StubDownloader()
    stub.nextCancelError = .cancelled
    let controller = ModelDownloadController(downloader: stub)
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .downloading,
                       bytesReceived: 10,
                       bytesExpected: 100,
                       etaSeconds: nil),
      handle: handle)

    controller.cancel(id: handle.id)

    XCTAssertNil(controller.active[handle.id]?.errorMessage,
                 "review v4 F31: .cancelled from the producer means it already terminated — short-circuit, no caption")
    XCTAssertNil(controller.lastError)
  }

  // MARK: - #722 failed rows persist and can be retried/dismissed

  func test_failed_phase_is_not_auto_evicted_so_retry_remains_reachable() async {
    let controller = ModelDownloadController(terminalRowLingerSeconds: 0)
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")

    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .failed,
                       bytesReceived: 5,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       failureReason: "timeout"),
      handle: handle)

    try? await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(controller.active[handle.id]?.progress.phase, .failed,
                   "failed rows must persist instead of disappearing before the user can click Retry")
    XCTAssertEqual(controller.active[handle.id]?.errorMessage, "timeout")
  }

  func test_completed_and_cancelled_rows_still_auto_evict_after_linger() async {
    let controller = ModelDownloadController(terminalRowLingerSeconds: 0)
    let completed = DownloadHandle(repo: "owner/repo", file: "done.gguf")
    let cancelled = DownloadHandle(repo: "owner/repo", file: "cancel.gguf")

    controller._testOnly_apply(
      DownloadProgress(handleID: completed.id,
                       phase: .completed,
                       bytesReceived: 100,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       verification: .verified),
      handle: completed)
    controller._testOnly_apply(
      DownloadProgress(handleID: cancelled.id,
                       phase: .cancelled,
                       bytesReceived: 10,
                       bytesExpected: 100,
                       etaSeconds: nil),
      handle: cancelled)

    let deadline = Date().addingTimeInterval(2.0)
    while (!controller.active.isEmpty) && Date() < deadline {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertNil(controller.active[completed.id], "completed rows should still clear after the terminal linger")
    XCTAssertNil(controller.active[cancelled.id], "cancelled rows should still clear after the terminal linger")
  }

  func test_retry_failed_row_reenqueues_same_repo_file_and_removes_failed_row() {
    let stub = StubDownloader()
    let controller = ModelDownloadController(downloader: stub, terminalRowLingerSeconds: 60)
    let failed = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: failed.id,
                       phase: .failed,
                       bytesReceived: 5,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       failureReason: "timeout"),
      handle: failed)

    let retryID = controller.retry(id: failed.id)

    XCTAssertNotNil(retryID, "Retry should start the same target again")
    XCTAssertEqual(stub.startedTargets, ["owner/repo/m.gguf"])
    XCTAssertNil(controller.active[failed.id], "the stale failed row should be cleared after a retry starts")
    XCTAssertEqual(controller.active[retryID!]?.repo, "owner/repo")
    XCTAssertEqual(controller.active[retryID!]?.file, "m.gguf")
    XCTAssertEqual(controller.active[retryID!]?.progress.phase, .starting)
  }

  func test_retry_failed_row_adopts_existing_inflight_target_instead_of_duplicate_start() {
    let stub = StubDownloader()
    let controller = ModelDownloadController(downloader: stub, terminalRowLingerSeconds: 60)
    let failed = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    let inflight = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: failed.id,
                       phase: .failed,
                       bytesReceived: 5,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       failureReason: "timeout"),
      handle: failed)
    controller._testOnly_apply(
      DownloadProgress(handleID: inflight.id,
                       phase: .downloading,
                       bytesReceived: 10,
                       bytesExpected: 100,
                       etaSeconds: nil),
      handle: inflight)

    let retryID = controller.retry(id: failed.id)

    XCTAssertEqual(retryID, inflight.id)
    XCTAssertTrue(stub.startedTargets.isEmpty, "Retry should adopt the already-running target instead of triggering the downloader dedupe path")
    XCTAssertNil(controller.active[failed.id], "adopting an in-flight row should clear the stale failed row")
    XCTAssertEqual(controller.active[inflight.id]?.progress.phase, .downloading)
  }

  func test_dismiss_failed_row_clears_it_without_touching_inflight_rows() {
    let controller = ModelDownloadController(terminalRowLingerSeconds: 60)
    let failed = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    let inflight = DownloadHandle(repo: "owner/repo", file: "other.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: failed.id,
                       phase: .failed,
                       bytesReceived: 5,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       failureReason: "timeout"),
      handle: failed)
    controller._testOnly_apply(
      DownloadProgress(handleID: inflight.id,
                       phase: .downloading,
                       bytesReceived: 10,
                       bytesExpected: 100,
                       etaSeconds: nil),
      handle: inflight)

    controller.dismiss(id: failed.id)

    XCTAssertNil(controller.active[failed.id])
    XCTAssertNotNil(controller.active[inflight.id])
  }

  // MARK: - F32: stale errorMessage cleared on recovery / completion

  func test_completed_phase_clears_stale_error_message() {
    let controller = ModelDownloadController()
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    // Prime the entry with a .failed (sets errorMessage).
    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .failed,
                       bytesReceived: 0,
                       bytesExpected: nil,
                       etaSeconds: nil,
                       failureReason: "network blip"),
      handle: handle)
    XCTAssertNotNil(controller.active[handle.id]?.errorMessage)

    // Now feed a .completed — the stale caption must clear.
    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .completed,
                       bytesReceived: 100,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       verification: .verified),
      handle: handle)
    XCTAssertNil(controller.active[handle.id]?.errorMessage,
                 "review v4 F32: .completed must clear a stale .failed caption so the row never reads as 'failed + done'")
  }

  func test_non_terminal_phase_after_failed_clears_error_message() {
    let controller = ModelDownloadController()
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .failed,
                       bytesReceived: 0,
                       bytesExpected: nil,
                       etaSeconds: nil,
                       failureReason: "transient"),
      handle: handle)
    XCTAssertNotNil(controller.active[handle.id]?.errorMessage)

    // Recovery: producer resumes with .downloading. F32 says clear.
    controller._testOnly_apply(
      DownloadProgress(handleID: handle.id,
                       phase: .downloading,
                       bytesReceived: 5,
                       bytesExpected: 100,
                       etaSeconds: nil),
      handle: handle)
    XCTAssertNil(controller.active[handle.id]?.errorMessage,
                 "review v4 F32: a recovery (.downloading after .failed) must clear the stale caption")
  }

  func test_consume_does_not_synthesize_when_stream_already_terminal() async {
    let controller = ModelDownloadController(terminalRowLingerSeconds: 60)
    let handle = DownloadHandle(repo: "owner/repo", file: "m.gguf")
    let (stream, continuation) = AsyncStream<DownloadProgress>.makeStream()
    continuation.yield(DownloadProgress(
      handleID: handle.id,
      phase: .completed,
      bytesReceived: 100,
      bytesExpected: 100,
      etaSeconds: nil,
      verification: .verified
    ))
    continuation.finish()

    let tickBefore = controller.completionTick
    await controller._testOnly_consume(stream: stream, handle: handle)

    XCTAssertEqual(controller.active[handle.id]?.progress.phase, .completed,
                   "an already-completed phase must NOT be overwritten by the stream-end synthesis path")
    XCTAssertEqual(controller.completionTick, tickBefore &+ 1,
                   "completed phase must still tick the refresh signal exactly once")
  }
}

// MARK: - Test fixture

/// Minimal `ModelDownloading` stub so `ModelDownloadController` can be
/// driven without a real `URLSession`. Only the methods exercised by
/// the cancel-focused tests above are implemented in interesting ways;
/// `start` and `progress` return inert defaults so the protocol is
/// satisfied without surprises.
private final class StubDownloader: ModelDownloading, @unchecked Sendable {
  var nextCancelError: DownloadError?
  var cancelInvocations = 0
  var startedTargets: [String] = []

  func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError> {
    startedTargets.append("\(repo)/\(file)")
    return .success(DownloadHandle(repo: repo, file: file))
  }

  func cancel(handle: DownloadHandle) -> DownloadError? {
    cancelInvocations += 1
    return nextCancelError
  }

  func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress> {
    AsyncStream { continuation in continuation.finish() }
  }
}
