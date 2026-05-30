import Foundation

/// Read-only resolver for HuggingFace's standard local cache layout:
///
///   `<HF_HOME>/hub/models--<owner>--<name>/refs/main`
///   `<HF_HOME>/hub/models--<owner>--<name>/snapshots/<rev>/...`
///
/// This does not download and does not write. It only answers whether
/// a model already staged by `pie model download`, `huggingface-cli`,
/// or another HF client is available for the production launch path.
public struct HFCacheResolver {
  public enum Resolution: Equatable {
    case hit(URL)
    case miss
    case invalid(CacheProblem)
  }

  public struct CacheProblem: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String

    public var description: String { "\(path): \(reason)" }
  }

  public let hfHome: URL
  public let fileManager: FileManager

  public init(hfHome: URL, fileManager: FileManager = .default) {
    self.hfHome = hfHome
    self.fileManager = fileManager
  }

  /// Resolve a cached HF repo. When `file` is nil, returns the
  /// `refs/main` snapshot directory. When `file` is present, returns
  /// that file inside the snapshot only if it exists.
  public func resolve(repo: String, file: String? = nil) -> Resolution {
    guard let repoDir = repoCacheDir(repo: repo) else {
      return .miss
    }
    switch readMainRevision(repoDir: repoDir) {
    case .success(let revision):
      let snapshot = repoDir
        .appendingPathComponent("snapshots", isDirectory: true)
        .appendingPathComponent(revision, isDirectory: true)
      guard existingDirectory(snapshot) else {
        return .invalid(CacheProblem(
          path: snapshot.path,
          reason: "refs/main points at a snapshot directory that does not exist"
        ))
      }

      if let file, !file.isEmpty {
        switch appendSafeRelativePath(file, to: snapshot) {
        case .success(let target):
          return existingFile(target)
            ? .hit(target)
            : .invalid(CacheProblem(
              path: target.path,
              reason: "required cached model file is missing"
            ))
        case .failure(let problem):
          return .invalid(problem)
        }
      }

      if let problem = validateSnapshotDirectory(snapshot) {
        return .invalid(problem)
      }
      return .hit(snapshot)
    case .failure(let problem):
      return .invalid(problem)
    case .none:
      return .miss
    }
  }

  private func repoCacheDir(repo: String) -> URL? {
    let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
      return nil
    }
    return hfHome
      .appendingPathComponent("hub", isDirectory: true)
      .appendingPathComponent("models--\(repo.replacingOccurrences(of: "/", with: "--"))",
                              isDirectory: true)
  }

  private func readMainRevision(repoDir: URL) -> Result<String, CacheProblem>? {
    let ref = repoDir
      .appendingPathComponent("refs", isDirectory: true)
      .appendingPathComponent("main", isDirectory: false)
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: ref.path, isDirectory: &isDir) else {
      return nil
    }
    if isDir.boolValue {
      return .failure(CacheProblem(
        path: ref.path,
        reason: "refs/main is a directory, expected a UTF-8 revision file"
      ))
    }

    let raw: String
    do {
      raw = try String(contentsOf: ref, encoding: .utf8)
    } catch {
      return .failure(CacheProblem(
        path: ref.path,
        reason: "cannot read refs/main: \(error.localizedDescription)"
      ))
    }

    let revision = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !revision.isEmpty,
          !revision.contains("/"),
          !revision.contains("\\") else {
      return .failure(CacheProblem(
        path: ref.path,
        reason: "invalid revision \(revision.debugDescription)"
      ))
    }
    return .success(revision)
  }

  private func appendSafeRelativePath(_ relativePath: String,
                                      to root: URL) -> Result<URL, CacheProblem> {
    let segments = relativePath
      .split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard !segments.isEmpty,
          segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
      return .failure(CacheProblem(
        path: root.path,
        reason: "unsafe cached model relative path \(relativePath.debugDescription)"
      ))
    }
    return .success(segments.reduce(root) { url, segment in
      url.appendingPathComponent(segment, isDirectory: false)
    })
  }

  private func existingFile(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
      && !isDir.boolValue
  }

  private func existingDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
      && isDir.boolValue
  }

  private func validateSnapshotDirectory(_ snapshot: URL) -> CacheProblem? {
    let entries: [String]
    do {
      entries = try fileManager.contentsOfDirectory(atPath: snapshot.path)
    } catch {
      return CacheProblem(
        path: snapshot.path,
        reason: "cannot inspect snapshot directory: \(error.localizedDescription)"
      )
    }

    switch validateRequiredFile(named: "config.json", in: snapshot, entries: entries) {
    case .valid:
      break
    case .absent:
      return CacheProblem(
        path: snapshot.path,
        reason: "incomplete HF snapshot; missing config.json"
      )
    case .invalid(let problem):
      return problem
    }

    let tokenizerCandidates = ["tokenizer.json", "tokenizer.model"]
    var firstTokenizerProblem: CacheProblem?
    var sawTokenizerCandidate = false
    var hasValidTokenizer = false
    for entry in tokenizerCandidates {
      switch validateRequiredFile(named: entry, in: snapshot, entries: entries) {
      case .valid:
        sawTokenizerCandidate = true
        hasValidTokenizer = true
        break
      case .absent:
        continue
      case .invalid(let problem):
        sawTokenizerCandidate = true
        if firstTokenizerProblem == nil {
          firstTokenizerProblem = problem
        }
      }
      if hasValidTokenizer {
        break
      }
    }
    if !hasValidTokenizer, let problem = firstTokenizerProblem {
      return problem
    }
    if !sawTokenizerCandidate {
      return CacheProblem(
        path: snapshot.path,
        reason: "incomplete HF snapshot; missing tokenizer.json"
      )
    }

    let weightCandidates = entries.filter { entry in
      let lower = entry.lowercased()
      return lower.hasSuffix(".safetensors")
        || lower.hasSuffix(".gguf")
        || lower.hasSuffix(".bin")
    }
    var firstWeightProblem: CacheProblem?
    for entry in weightCandidates {
      switch validateRequiredFile(named: entry, in: snapshot, entries: entries) {
      case .valid:
        return nil
      case .absent:
        continue
      case .invalid(let problem):
        if firstWeightProblem == nil {
          firstWeightProblem = problem
        }
      }
    }
    if let firstWeightProblem {
      return firstWeightProblem
    }
    return CacheProblem(
      path: snapshot.path,
      reason: "incomplete HF snapshot; missing model weights"
    )
  }

  private enum RequiredArtifactValidation {
    case absent
    case valid
    case invalid(CacheProblem)
  }

  private func validateRequiredFile(named name: String,
                                    in snapshot: URL,
                                    entries: [String]) -> RequiredArtifactValidation {
    guard entries.contains(name) else { return .absent }
    let url = snapshot.appendingPathComponent(name, isDirectory: false)
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
      return .invalid(CacheProblem(
        path: url.path,
        reason: "HF snapshot artifact is missing or a dangling symlink"
      ))
    }
    guard !isDir.boolValue else {
      return .invalid(CacheProblem(
        path: url.path,
        reason: "HF snapshot artifact is a directory, expected a file"
      ))
    }
    return .valid
  }
}
