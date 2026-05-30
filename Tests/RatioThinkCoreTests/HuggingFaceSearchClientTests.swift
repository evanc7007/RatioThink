import XCTest
@testable import RatioThinkCore

/// Unit tests for `HuggingFaceSearchClient`. Covers the URL builders
/// and the response decoders so a HF schema drift is caught at the
/// RatioThinkCore boundary, not three layers up in SwiftUI. No real network
/// — the decoder is run against canned JSON.
final class HuggingFaceSearchClientTests: XCTestCase {

  // MARK: - URL builders

  func test_search_url_pins_filter_sort_and_limit() throws {
    let client = HuggingFaceSearchClient()
    let url = try XCTUnwrap(client.searchURL(query: "llama 3"))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "huggingface.co")
    XCTAssertEqual(components.path, "/api/models")

    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
    XCTAssertEqual(items["search"], "llama 3")
    XCTAssertEqual(items["filter"], HuggingFaceSearchClient.ggufFilter)
    XCTAssertEqual(items["limit"],  String(HuggingFaceSearchClient.defaultLimit))
    XCTAssertEqual(items["sort"],   "downloads")
    XCTAssertEqual(items["direction"], "-1")
  }

  func test_files_url_includes_repo_path_segment() throws {
    let client = HuggingFaceSearchClient()
    let url = try XCTUnwrap(client.filesURL(repo: "Qwen/Qwen2.5-1.5B-Instruct-GGUF"))
    XCTAssertEqual(url.path, "/api/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/tree/main")
    let q = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
      .first { $0.name == "recursive" }
    XCTAssertEqual(q?.value, "false")
  }

  // MARK: - Decoders

  func test_decodeSearch_parses_id_downloads_likes_lastModified() throws {
    let json = """
    [
      {"id":"owner/foo-gguf","downloads":123,"likes":4,"lastModified":"2025-01-02T03:04:05.000Z"},
      {"id":"owner/bar-gguf","downloads":0}
    ]
    """.data(using: .utf8)!

    let rows = try HuggingFaceSearchClient.decodeSearch(json)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].repo, "owner/foo-gguf")
    XCTAssertEqual(rows[0].downloads, 123)
    XCTAssertEqual(rows[0].likes, 4)
    XCTAssertNotNil(rows[0].updatedAt, "ISO8601 fractional-seconds date should parse")
    XCTAssertEqual(rows[1].downloads, 0, "missing downloads field should default to 0")
    XCTAssertNil(rows[1].updatedAt)
  }

  func test_decodeSearch_skips_entries_without_id() throws {
    let json = #"""
    [
      {"id":"good/repo","downloads":1},
      {"downloads":2}
    ]
    """#.data(using: .utf8)!
    let rows = try HuggingFaceSearchClient.decodeSearch(json)
    XCTAssertEqual(rows.map(\.repo), ["good/repo"])
  }

  func test_decodeTree_filters_to_gguf_files_only() throws {
    let json = """
    [
      {"type":"file","path":"README.md","size":123},
      {"type":"file","path":"q4_k_m.gguf","size":1048576},
      {"type":"directory","path":"sub","size":0},
      {"type":"file","path":"Q8_0.GGUF","size":2097152}
    ]
    """.data(using: .utf8)!

    let files = try HuggingFaceSearchClient.decodeTree(json)
    XCTAssertEqual(files.map(\.path), ["q4_k_m.gguf", "Q8_0.GGUF"],
                   "non-gguf entries and directories should be filtered out (case-insensitive match on extension)")
    XCTAssertEqual(files.first?.sizeBytes, 1_048_576)
  }

  func test_decodeSearch_rejects_non_array_top_level() {
    let json = #"{"id":"oops"}"#.data(using: .utf8)!
    XCTAssertThrowsError(try HuggingFaceSearchClient.decodeSearch(json)) { err in
      guard case HFSearchError.decodeFailed = err else {
        XCTFail("expected .decodeFailed, got \(err)")
        return
      }
    }
  }

  // MARK: - Schema-drift surfacing (review v2 F5)

  func test_decodeSearchWithDropCount_returns_drop_count_for_schema_drift() throws {
    let json = #"""
    [
      {"id":"a/b","downloads":1},
      {"modelId":"c/d","downloads":2}
    ]
    """#.data(using: .utf8)!
    let (results, dropped) = try HuggingFaceSearchClient.decodeSearchWithDropCount(json)
    XCTAssertEqual(results.map(\.repo), ["a/b"])
    XCTAssertEqual(dropped, 1,
                   "entries missing `id` must be counted so callers can surface schema drift")
  }

  func test_decodeSearchWithDropCount_kept_zero_when_all_drop() throws {
    let json = #"""
    [
      {"modelId":"a/b","downloads":1},
      {"modelId":"c/d","downloads":2}
    ]
    """#.data(using: .utf8)!
    let (results, dropped) = try HuggingFaceSearchClient.decodeSearchWithDropCount(json)
    XCTAssertEqual(results, [])
    XCTAssertEqual(dropped, 2)
  }

  // Brief test recommendation (F22): "Add a fixture with mixed
  // valid/invalid entries; assert the caller can read the dropped
  // count." Hits decodeSearchWithDropCount with a realistic partial-
  // drift payload (4 of 10 entries lose `id`).
  func test_partial_schema_drift_caller_reads_dropped_count() throws {
    var raw = "["
    for i in 0..<6 {
      raw += #"{"id":"owner/repo-\#(i)","downloads":\#(i),"likes":0},"#
    }
    for i in 0..<4 {
      raw += #"{"modelId":"owner/dropped-\#(i)","downloads":\#(i)}"#
      if i < 3 { raw += "," }
    }
    raw += "]"
    let data = raw.data(using: .utf8)!

    let (results, dropped) = try HuggingFaceSearchClient.decodeSearchWithDropCount(data)

    XCTAssertEqual(results.count, 6,
                   "exactly the entries with `id` survive — 4 of the 10 must drop because their wire shape used the drift'd `modelId` key")
    XCTAssertEqual(dropped, 4,
                   "the caller MUST be able to read the dropped count to render a 'kept 6 of 10' banner (review v3 F22 — the v2 version logged only at .fault, hiding partial drift from the UI)")

    // The HFSearchResponse wrapper (the live `search()` path)
    // mirrors the same fields so the UI bind reads them off the
    // same struct.
    let response = HFSearchResponse(results: results, droppedCount: dropped)
    XCTAssertEqual(response.rawCount, 10)
    XCTAssertEqual(response.droppedCount, 4)
    XCTAssertEqual(response.results.map(\.repo).sorted(),
                   (0..<6).map { "owner/repo-\($0)" }.sorted(),
                   "kept results must be exactly the entries whose schema survived")
  }

  func test_search_response_carries_raw_count_and_dropped_count() {
    let response = HFSearchResponse(
      results: [
        HFSearchResult(repo: "a/b", downloads: 1, likes: 0, updatedAt: nil),
        HFSearchResult(repo: "c/d", downloads: 2, likes: 0, updatedAt: nil),
      ],
      droppedCount: 3
    )
    XCTAssertEqual(response.rawCount, 5,
                   "rawCount must reflect kept + dropped so a partial-drift banner shows the right `N of M`")
    XCTAssertEqual(response.droppedCount, 3)
  }

  func test_decodeSearch_tolerates_numeric_strings_and_doubles() throws {
    let json = #"""
    [
      {"id":"x/y","downloads":"1234","likes":42.0}
    ]
    """#.data(using: .utf8)!
    let rows = try HuggingFaceSearchClient.decodeSearch(json)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].downloads, 1234,
                   "string-encoded counts must coerce instead of silently dropping to 0")
    XCTAssertEqual(rows[0].likes, 42)
  }
}
