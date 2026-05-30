import Foundation
import os

/// Bundle returned by `HuggingFaceSearchClient.search` so the caller
/// can tell "0 of 0" apart from "10 of N, the other (N - 10) dropped
/// due to HF schema drift" (review v3 F22). Previously `search()`
/// returned `[HFSearchResult]` directly and partial drift was a
/// silent truncation.
public struct HFSearchResponse: Equatable, Sendable {
  public let results: [HFSearchResult]
  /// How many entries the wire payload contained but did NOT survive
  /// schema validation (missing `id`, etc). Zero on a clean response.
  public let droppedCount: Int

  public init(results: [HFSearchResult], droppedCount: Int) {
    self.results = results
    self.droppedCount = droppedCount
  }

  /// Convenience: total entries in the raw HF payload (kept + dropped).
  public var rawCount: Int { results.count + droppedCount }
}

/// One row in *Settings → Models → Add Model → HF search*. Stripped-
/// down projection of the `https://huggingface.co/api/models` response
/// — we surface only the fields the UI binds, not the whole HF schema.
public struct HFSearchResult: Equatable, Identifiable, Sendable {
  /// `<owner>/<repo>` — also the natural row ID since HF guarantees
  /// it is unique.
  public var id: String { repo }

  public let repo: String
  public let downloads: Int
  public let likes: Int
  public let updatedAt: Date?

  public init(repo: String, downloads: Int, likes: Int, updatedAt: Date?) {
    self.repo = repo
    self.downloads = downloads
    self.likes = likes
    self.updatedAt = updatedAt
  }
}

/// One GGUF file inside a repo, returned by `listFiles(in:)`. The Add
/// sheet expands the chosen row and shows these so the user picks the
/// exact quantization before triggering `ModelDownloader.start`.
public struct HFRepoFile: Equatable, Identifiable, Sendable {
  public var id: String { path }

  public let path: String
  public let sizeBytes: Int64?

  public init(path: String, sizeBytes: Int64?) {
    self.path = path
    self.sizeBytes = sizeBytes
  }
}

public enum HFSearchError: Error, CustomStringConvertible, Equatable {
  case invalidQuery(String)
  case transport(String)
  case httpStatus(Int)
  case decodeFailed(String)
  /// HF returned a non-empty payload but every entry failed structural
  /// validation (e.g. `id` was renamed to `modelId`). Distinct from
  /// `decodeFailed` so the caller can render "0 results out of N
  /// (schema drift)" instead of a generic decode error, and from a
  /// real empty result. Surfaced when `decodeSearch` is called via
  /// `decodeSearchWithDropCount` and finds `kept == 0 && raw > 0`
  /// (review v2 F5).
  case schemaDriftAllDropped(rawCount: Int)

  public var description: String {
    switch self {
    case .invalidQuery(let q): return "HFSearch: query '\(q)' could not be percent-encoded"
    case .transport(let m):    return "HFSearch: transport error: \(m)"
    case .httpStatus(let c):   return "HFSearch: HTTP \(c)"
    case .decodeFailed(let m): return "HFSearch: response decode failed: \(m)"
    case .schemaDriftAllDropped(let n):
      return "HFSearch: HF returned \(n) entries but none matched the expected schema (`id` field missing). HF may have renamed fields."
    }
  }
}

/// Hugging Face search/listing client. Lives in `Shared/` so the
/// RatioThinkCore SPM target can unit-test the URL builder + decoder
/// without an Xcode-target dependency. Network calls go through an
/// injected `URLSession` so tests can stub responses.
public final class HuggingFaceSearchClient: @unchecked Sendable {
  /// HF caps `limit` at 100 per request; we ship a small page since
  /// the Add Model surface only needs the top hits.
  public static let defaultLimit = 20
  /// `filter=gguf` restricts to GGUF-bearing repos so the search
  /// surface in *Settings → Models* never returns a result the
  /// downloader can't handle.
  public static let ggufFilter = "gguf"

  private let session: URLSession
  private let host: String
  private static let log = Logger(subsystem: "com.ratiothink.app", category: "hf-search")

  public init(session: URLSession = .shared, host: String = "huggingface.co") {
    self.session = session
    self.host = host
  }

  /// Build the search URL without performing the request. Exposed so
  /// RatioThinkCoreTests can pin the URL shape against drift (review-style:
  /// "test the seam, not the network").
  public func searchURL(query: String, limit: Int = defaultLimit) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/api/models"
    components.queryItems = [
      URLQueryItem(name: "search", value: query),
      URLQueryItem(name: "filter", value: Self.ggufFilter),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "sort", value: "downloads"),
      URLQueryItem(name: "direction", value: "-1"),
    ]
    return components.url
  }

  /// File-listing URL for a single repo. HF returns the tree under
  /// `api/models/<repo>/tree/main`; we surface the same paginated
  /// shape so the UI can lazy-load more on demand later.
  public func filesURL(repo: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    // The tree endpoint accepts the repo as a path segment; HF treats
    // the slash inside `<owner>/<repo>` as a literal not a separator.
    components.path = "/api/models/\(repo)/tree/main"
    components.queryItems = [
      URLQueryItem(name: "recursive", value: "false"),
    ]
    return components.url
  }

  /// Returns the full `HFSearchResponse` so the caller can surface
  /// the `droppedCount` even on a partial-drift response (review v3
  /// F22). The all-drift case still throws `.schemaDriftAllDropped`
  /// so callers can treat it as a hard error rather than rendering
  /// "no results" misleadingly.
  public func search(query: String, limit: Int = defaultLimit) async throws -> HFSearchResponse {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return HFSearchResponse(results: [], droppedCount: 0) }
    guard let url = searchURL(query: trimmed, limit: limit) else {
      throw HFSearchError.invalidQuery(query)
    }
    let data = try await fetch(url)
    let (results, dropped) = try Self.decodeSearchWithDropCount(data)
    if dropped > 0 {
      let raw = results.count + dropped
      Self.log.fault("HF search decoded \(raw, privacy: .public) entries but kept only \(results.count, privacy: .public); \(dropped, privacy: .public) dropped (missing `id` — possible HF schema drift)")
      if results.isEmpty {
        throw HFSearchError.schemaDriftAllDropped(rawCount: raw)
      }
    }
    return HFSearchResponse(results: results, droppedCount: dropped)
  }

  public func listFiles(in repo: String) async throws -> [HFRepoFile] {
    guard let url = filesURL(repo: repo) else {
      throw HFSearchError.invalidQuery(repo)
    }
    let data = try await fetch(url)
    return try Self.decodeTree(data)
  }

  // MARK: - private

  private func fetch(_ url: URL) async throws -> Data {
    let request = URLRequest(url: url)
    let pair: (Data, URLResponse)
    do {
      pair = try await session.data(for: request)
    } catch {
      throw HFSearchError.transport(String(describing: error))
    }
    if let http = pair.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw HFSearchError.httpStatus(http.statusCode)
    }
    return pair.0
  }

  /// HF returns a top-level JSON array. Each entry has at minimum
  /// `id` (`<owner>/<repo>`), `downloads`, `likes`, `lastModified`.
  /// Numeric fields are tolerantly coerced from `Int` or `Double` so
  /// HF returning `1234.0` (or a JSON-number-as-string) does not
  /// silently collapse to 0 (review v2 F5).
  ///
  /// Kept for binary/source compatibility with callers that don't
  /// need the drop count — wraps `decodeSearchWithDropCount` and
  /// returns only the kept results.
  static func decodeSearch(_ data: Data) throws -> [HFSearchResult] {
    try decodeSearchWithDropCount(data).results
  }

  /// Same wire shape as `decodeSearch` but also returns the count of
  /// entries that were silently dropped because they failed schema
  /// validation (missing `id`). Surfaced so the live `search()` path
  /// can log + escalate to `.schemaDriftAllDropped` when EVERY entry
  /// failed validation (review v2 F5).
  static func decodeSearchWithDropCount(
    _ data: Data
  ) throws -> (results: [HFSearchResult], dropped: Int) {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw HFSearchError.decodeFailed(String(describing: error))
    }
    guard let array = raw as? [[String: Any]] else {
      throw HFSearchError.decodeFailed("expected top-level array of objects")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var results: [HFSearchResult] = []
    var dropped = 0
    results.reserveCapacity(array.count)
    for entry in array {
      guard let repo = entry["id"] as? String else {
        dropped += 1
        continue
      }
      var updated: Date?
      if let last = entry["lastModified"] as? String {
        updated = formatter.date(from: last)
      }
      results.append(HFSearchResult(
        repo: repo,
        downloads: tolerantInt(entry["downloads"]),
        likes: tolerantInt(entry["likes"]),
        updatedAt: updated))
    }
    return (results, dropped)
  }

  /// JSON-number-or-numeric-string → `Int`. HF nightly builds have
  /// occasionally returned `downloads` as a string; tolerating that
  /// is cheaper than missing a real signal in the search UI.
  private static func tolerantInt(_ raw: Any?) -> Int {
    if let i = raw as? Int { return i }
    if let d = raw as? Double { return Int(d) }
    if let s = raw as? String, let i = Int(s) { return i }
    return 0
  }

  /// HF tree endpoint returns an array of `{ type, path, size, oid }`.
  /// We filter to `type == "file"` and `path` ending in `.gguf` so the
  /// UI lists only loadable artifacts.
  static func decodeTree(_ data: Data) throws -> [HFRepoFile] {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw HFSearchError.decodeFailed(String(describing: error))
    }
    guard let array = raw as? [[String: Any]] else {
      throw HFSearchError.decodeFailed("expected top-level array of objects")
    }
    return array.compactMap { entry -> HFRepoFile? in
      guard (entry["type"] as? String) == "file" else { return nil }
      guard let path = entry["path"] as? String,
            path.lowercased().hasSuffix(".gguf") else { return nil }
      let size = entry["size"] as? Int64 ?? (entry["size"] as? Int).map(Int64.init)
      return HFRepoFile(path: path, sizeBytes: size)
    }
  }
}
