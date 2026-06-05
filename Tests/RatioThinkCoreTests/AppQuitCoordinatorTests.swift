import XCTest
@testable import RatioThinkCore

/// #448: the App-side full-product quit coordinator. Pins the teardown
/// contract — stop polling, ask the helper to quit, always signal `done` so
/// the App can terminate — without a real helper or AppKit.
@MainActor
final class AppQuitCoordinatorTests: XCTestCase {

  /// Records `quitHelper` invocations and can be told to throw, so the
  /// coordinator's best-effort sequencing is observable.
  private final class FakeQuitClient: AppXPCClient, @unchecked Sendable {
    private(set) var quitCount = 0
    var quitError: Error?
    func engineStatus() async throws -> EngineStatus { .stopped }
    func stopEngine() async throws {}
    func startEngine(profileID: String) async throws {}
    func quitHelper() async throws {
      quitCount += 1
      if let quitError { throw quitError }
    }
  }

  func test_testLaunch_skipsHelperQuit_butStillSignalsDone() async {
    let client = FakeQuitClient()
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: true)
    let done = expectation(description: "done")
    coord.beginTeardown { done.fulfill() }
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(client.quitCount, 0, "a test/automation launch must NOT quit the real helper")
    XCTAssertTrue(coord.isQuitting)
  }

  func test_realLaunch_callsQuitHelper_thenSignalsDone() async {
    let client = FakeQuitClient()
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: false)
    let done = expectation(description: "done")
    coord.beginTeardown { done.fulfill() }
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(client.quitCount, 1, "a real quit must ask the helper to stop the engine + exit")
  }

  func test_quitHelperFailure_isBestEffort_stillSignalsDone() async {
    let client = FakeQuitClient()
    client.quitError = AppXPCClientError.replyTimeout(selector: "quitHelper", timeout: 6)
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: false)
    let done = expectation(description: "done despite helper error")
    coord.beginTeardown { done.fulfill() }
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(client.quitCount, 1)
  }

  func test_secondTeardown_isIdempotent_doesNotReQuitHelper() async {
    let client = FakeQuitClient()
    let coord = AppQuitCoordinator(helperClient: client, isTestLaunch: false)
    let first = expectation(description: "first done")
    coord.beginTeardown { first.fulfill() }
    await fulfillment(of: [first], timeout: 2)
    let second = expectation(description: "second done")
    coord.beginTeardown { second.fulfill() }
    await fulfillment(of: [second], timeout: 2)
    XCTAssertEqual(client.quitCount, 1, "a repeated applicationShouldTerminate must not re-quit the helper")
  }
}
