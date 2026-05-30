import Foundation

/// Deterministic v1 guardrail for obviously unsafe model loads.
///
/// The guardrail intentionally uses resolved artifact size, not live
/// machine telemetry. That keeps the behavior deterministic in tests
/// and avoids promising that RatioThink.app can perfectly predict every host's
/// memory pressure. Unknown-size cases fail closed for v1 because
/// launching an unmeasurable local artifact is no safer than launching
/// an oversized one.
public enum ModelMemoryGuardrail {
  public struct Policy: Equatable, Sendable {
    /// V1 ceiling for a resolved model artifact. The default seeded
    /// model and the curated small models remain comfortably below
    /// this, while a deterministic sparse-file fixture above it is
    /// rejected before `pie serve` is spawned.
    public var maxResolvedModelBytes: Int64

    public init(maxResolvedModelBytes: Int64 = 8 * 1024 * 1024 * 1024) {
      self.maxResolvedModelBytes = maxResolvedModelBytes
    }
  }

  public static let defaultPolicy = Policy()

  private struct SizeSummary {
    var totalBytes: Int64
    var largestPath: String
    var largestBytes: Int64
  }

  /// Validate a local file or resolved HF snapshot directory before it
  /// reaches `PieControlLauncher.LaunchSpec`. On failure, returns an
  /// actionable `EngineError(.memoryRisk, ...)` that can be surfaced
  /// directly by XPC/status UI layers.
  public static func validate(
    resolvedModelURL: URL,
    modelID: String,
    policy: Policy = defaultPolicy,
    fileManager: FileManager = .default
  ) -> Result<Void, EngineError> {
    let summary: SizeSummary
    do {
      summary = try summarize(resolvedModelURL: resolvedModelURL,
                              fileManager: fileManager)
    } catch {
      return .failure(memoryRiskError(
        modelID: modelID,
        path: resolvedModelURL.path,
        detail: "cannot determine model size safely (\(error.localizedDescription))"
      ))
    }

    guard summary.totalBytes <= policy.maxResolvedModelBytes else {
      let detail = "resolved size \(InstalledModels.formattedSize(summary.totalBytes))"
        + " exceeds v1 safety limit \(InstalledModels.formattedSize(policy.maxResolvedModelBytes));"
        + " largest artifact \(summary.largestPath) is \(InstalledModels.formattedSize(summary.largestBytes))"
      return .failure(memoryRiskError(
        modelID: modelID,
        path: resolvedModelURL.path,
        detail: detail
      ))
    }
    return .success(())
  }

  private static func summarize(resolvedModelURL: URL,
                                fileManager: FileManager) throws -> SizeSummary {
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: resolvedModelURL.path, isDirectory: &isDir) else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "resolved model path does not exist"]
      )
    }

    if isDir.boolValue {
      return try summarizeDirectory(resolvedModelURL, fileManager: fileManager)
    }

    let size = try regularFileSize(resolvedModelURL, fileManager: fileManager)
    return SizeSummary(totalBytes: size,
                       largestPath: resolvedModelURL.path,
                       largestBytes: size)
  }

  private static func summarizeDirectory(_ directory: URL,
                                         fileManager: FileManager) throws -> SizeSummary {
    var traversalError: Error?
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
      options: [],
      errorHandler: { url, error in
        traversalError = NSError(
          domain: "ModelMemoryGuardrail",
          code: 8,
          userInfo: [NSLocalizedDescriptionKey: "\(url.path) cannot be inspected during traversal: \(error.localizedDescription)"]
        )
        return false
      }
    ) else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "cannot enumerate resolved model directory"]
      )
    }

    var total: Int64 = 0
    var largestPath = directory.path
    var largest: Int64 = 0
    var sawFile = false

    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true { continue }
      let size = try regularFileSize(url, fileManager: fileManager)
      sawFile = true
      let (nextTotal, overflow) = total.addingReportingOverflow(size)
      guard !overflow else {
        throw NSError(
          domain: "ModelMemoryGuardrail",
          code: 6,
          userInfo: [NSLocalizedDescriptionKey: "resolved model directory size overflowed Int64"]
        )
      }
      total = nextTotal
      if size > largest {
        largest = size
        largestPath = url.path
      }
    }

    if let traversalError {
      throw traversalError
    }

    guard sawFile else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "resolved model directory contains no files"]
      )
    }
    return SizeSummary(totalBytes: total, largestPath: largestPath, largestBytes: largest)
  }

  private static func regularFileSize(_ url: URL,
                                      fileManager: FileManager) throws -> Int64 {
    // HF snapshots commonly expose model artifacts as symlinks into
    // `blobs/`. Resolve before reading attributes so we count the blob
    // bytes, not the symlink's short path string.
    let resolved = url.resolvingSymlinksInPath()
    let attrs: [FileAttributeKey: Any]
    do {
      attrs = try fileManager.attributesOfItem(atPath: resolved.path)
    } catch {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "\(url.path) cannot be inspected: \(error.localizedDescription)"]
      )
    }
    if let type = attrs[.type] as? FileAttributeType,
       type != .typeRegular {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "\(resolved.path) is \(type.rawValue), expected a regular file"]
      )
    }
    guard let rawSize = attrs[.size] as? NSNumber else {
      throw NSError(
        domain: "ModelMemoryGuardrail",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "\(resolved.path) size metadata is unavailable"]
      )
    }
    return rawSize.int64Value
  }

  private static func memoryRiskError(modelID: String,
                                      path: String,
                                      detail: String) -> EngineError {
    EngineError(
      code: .memoryRisk,
      message: "memory risk: choose a smaller model or remove this model and retry; model \(modelID.debugDescription) at \(path) was not launched; \(detail)."
    )
  }
}
