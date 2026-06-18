import XCTest
@testable import RatioThink

@MainActor
final class MissingModelDownloadCTATests: XCTestCase {
  func test_failedRowRetryRemovesStaleFailedEntryAndTracksRetryHandle() {
    let downloader = CTADownloadStub()
    let controller = ModelDownloadController(
      downloader: downloader,
      terminalRowLingerSeconds: 60)
    let failed = DownloadHandle(repo: "owner/repo", file: "model.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: failed.id,
                       phase: .failed,
                       bytesReceived: 5,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       failureReason: "timeout"),
      handle: failed)

    let result = MissingModelDownloadCTA.retryFailedDownload(
      entryID: failed.id,
      downloads: controller)

    XCTAssertNotNil(
      result.handleID,
      "CTA Retry should track the retry/adopted handle")
    XCTAssertNil(result.enqueueError)
    XCTAssertNil(
      controller.active[failed.id],
      "CTA Retry must route through retry(id:) so the stale failed row is removed")
    XCTAssertEqual(downloader.startedTargets, ["owner/repo/model.gguf"])
    XCTAssertEqual(controller.active[result.handleID!]?.repo, "owner/repo")
    XCTAssertEqual(controller.active[result.handleID!]?.file, "model.gguf")
    XCTAssertEqual(controller.active[result.handleID!]?.progress.phase, .starting)
  }

  func test_failedRowRetryFailurePreservesFailedEntryAndSurfacesLastError() {
    let downloader = CTADownloadStub()
    downloader.startResult = .failure(.writeFailed(message: "disk full", cause: nil))
    let controller = ModelDownloadController(
      downloader: downloader,
      terminalRowLingerSeconds: 60)
    let failed = DownloadHandle(repo: "owner/repo", file: "model.gguf")
    controller._testOnly_apply(
      DownloadProgress(handleID: failed.id,
                       phase: .failed,
                       bytesReceived: 5,
                       bytesExpected: 100,
                       etaSeconds: nil,
                       failureReason: "timeout"),
      handle: failed)

    let result = MissingModelDownloadCTA.retryFailedDownload(
      entryID: failed.id,
      downloads: controller)

    XCTAssertNil(result.handleID)
    XCTAssertEqual(result.enqueueError, controller.lastError ?? "Could not start download")
    XCTAssertNotNil(result.enqueueError)
    XCTAssertEqual(
      controller.active[failed.id]?.progress.phase, .failed,
      "retry(id:) should preserve the stale failed row when the new start returns nil")
  }
}

private final class CTADownloadStub: ModelDownloading, @unchecked Sendable {
  var startResult: Result<DownloadHandle, DownloadError>?
  var startedTargets: [String] = []

  func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError> {
    startedTargets.append("\(repo)/\(file)")
    if let startResult { return startResult }
    return .success(DownloadHandle(repo: repo, file: file))
  }

  func cancel(handle: DownloadHandle) -> DownloadError? { nil }

  func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress> {
    AsyncStream { continuation in continuation.finish() }
  }
}
