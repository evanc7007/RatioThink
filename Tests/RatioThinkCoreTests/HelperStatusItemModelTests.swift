import XCTest
@testable import RatioThinkCore

/// Pins the EngineStatus → menu-bar UI mapping. RatioThinkCoreTests can run
/// this without AppKit, so a regression in the dot color / label /
/// Pause-vs-Resume affordance surfaces here instead of waiting on the
/// S4 seated-GUI run.
final class HelperStatusItemModelTests: XCTestCase {

  func test_stopped_isGray_withEnabledResume() {
    let m = HelperStatusItemModel.make(from: .stopped)
    XCTAssertEqual(m.dot, .stopped)
    XCTAssertEqual(m.engineLabel, "Engine: stopped")
    XCTAssertEqual(m.pauseResume.title, "Resume Engine")
    XCTAssertTrue(m.pauseResume.enabled,
                  "Resume must be actionable when stopped — ProfileStore + resolver are wired; a disabled Resume strands the engine and defers every model load ( follow-up)")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_starting_isLoading_withEnabledPause() {
    let m = HelperStatusItemModel.make(from: .starting)
    XCTAssertEqual(m.dot, .loading)
    XCTAssertEqual(m.engineLabel, "Engine: starting…")
    XCTAssertEqual(m.pauseResume.title, "Pause Engine")
    XCTAssertTrue(m.pauseResume.enabled)
    XCTAssertEqual(m.pauseResume.action, .pause)
  }

  func test_running_carriesProfileAndPort_andEnablesPause() {
    let m = HelperStatusItemModel.make(from: .running(port: 54321, profileID: "chat"))
    XCTAssertEqual(m.dot, .running)
    XCTAssertEqual(m.engineLabel, "Engine: running — chat @ port 54321")
    XCTAssertEqual(m.pauseResume.title, "Pause Engine")
    XCTAssertTrue(m.pauseResume.enabled)
    XCTAssertEqual(m.pauseResume.action, .pause)
  }

  func test_stopping_isLoading_andPauseDisabled() {
    let m = HelperStatusItemModel.make(from: .stopping)
    XCTAssertEqual(m.dot, .loading)
    XCTAssertEqual(m.engineLabel, "Engine: stopping…")
    XCTAssertEqual(m.pauseResume.title, "Pause Engine")
    XCTAssertFalse(m.pauseResume.enabled,
                   "Cannot pause something that's already stopping")
    XCTAssertEqual(m.pauseResume.action, .none)
  }

  func test_failed_isError_withCodeAndMessage_andRetryableResumeEnabled() {
    let m = HelperStatusItemModel.make(
      from: .failed(code: .spawnFailed, message: "binary missing")
    )
    XCTAssertEqual(m.dot, .error)
    XCTAssertTrue(m.engineLabel.contains("spawnFailed"))
    XCTAssertTrue(m.engineLabel.contains("binary missing"))
    XCTAssertEqual(m.pauseResume.title, "Resume Engine")
    XCTAssertTrue(m.pauseResume.enabled,
                  "recoverable failures must keep a working Resume so the user can retry after fixing the cause")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_modelMissingFailure_keepsResumeEnabledForRetry() {
    // The  follow-up: a missing model (fresh install / stale profile)
    // surfaces as a `.failed(.modelMissing)` status instead of a silent
    // `.stopped`, and the menu Resume stays actionable so the user can
    // download the model and retry without relaunching the helper.
    let m = HelperStatusItemModel.make(
      from: .failed(code: .modelMissing, message: "no model at <path>; not in HF cache")
    )
    XCTAssertEqual(m.dot, .error)
    XCTAssertTrue(m.engineLabel.contains("modelMissing"))
    XCTAssertTrue(m.pauseResume.enabled,
                  "modelMissing is user-recoverable (download the model) — Resume must not be disabled")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_memoryRiskFailure_surfacesActionableMenuCopy() {
    let m = HelperStatusItemModel.make(
      from: .failed(
        code: .memoryRisk,
        message: "memory risk: model was not launched; choose a smaller model"
      )
    )
    XCTAssertEqual(m.dot, .error)
    XCTAssertTrue(m.engineLabel.contains("memoryRisk"),
                  "GUI menu label must carry the structured memory-risk code; got \(m.engineLabel)")
    XCTAssertTrue(m.engineLabel.contains("choose a smaller model"),
                  "GUI menu label must include recovery copy; got \(m.engineLabel)")
    XCTAssertEqual(m.pauseResume.title, "Resume Engine")
    XCTAssertFalse(m.pauseResume.enabled,
                   "memory-risk failures should not invite an immediate retry of the same unsafe model")
    XCTAssertEqual(m.pauseResume.action, .resume)
  }

  func test_failed_truncatesLongMessage_inLabel() {
    let long = String(repeating: "x", count: 500)
    let m = HelperStatusItemModel.make(
      from: .failed(code: .handshakeTimeout, message: long)
    )
    XCTAssertTrue(m.engineLabel.hasSuffix("…"),
                  "expected ellipsis suffix on truncated label")
    XCTAssertLessThan(m.engineLabel.count, 200,
                      "menu-item labels must be bounded; got \(m.engineLabel.count) chars")
  }

  func test_killRejected_isErrorDot_withResumeDisabled() {
    let m = HelperStatusItemModel.make(
      from: .failed(code: .killRejected, message: "zombie pid=1234")
    )
    XCTAssertEqual(m.dot, .error,
                   "killRejected must surface as red dot — supervisor refuses re-start")
    XCTAssertFalse(m.pauseResume.enabled)
  }
}
