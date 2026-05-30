import Foundation

final class EnvironmentFakeModelDownloader: ModelDownloading, @unchecked Sendable {
  private let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  func start(repo: String, file: String) -> Result<DownloadHandle, DownloadError> {
    .success(DownloadHandle(repo: repo, file: file))
  }

  func cancel(handle: DownloadHandle) -> DownloadError? {
    nil
  }

  func progress(for handle: DownloadHandle) -> AsyncStream<DownloadProgress> {
    AsyncStream { continuation in
      Task {
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .starting,
          bytesReceived: 0,
          bytesExpected: 100_000_000,
          etaSeconds: 60
        ))
        try? await Task.sleep(nanoseconds: 150_000_000)
        continuation.yield(DownloadProgress(
          handleID: handle.id,
          phase: .downloading,
          bytesReceived: 25_000_000,
          bytesExpected: 100_000_000,
          etaSeconds: 60
        ))
        if let failure = environment["PIE_TEST_FAKE_DOWNLOAD_FAILURE"],
           !failure.isEmpty {
          try? await Task.sleep(nanoseconds: 150_000_000)
          continuation.yield(DownloadProgress(
            handleID: handle.id,
            phase: .failed,
            bytesReceived: 25_000_000,
            bytesExpected: 100_000_000,
            etaSeconds: nil,
            verification: .notApplicable,
            failureReason: failure
          ))
          continuation.finish()
        }
      }
    }
  }
}
